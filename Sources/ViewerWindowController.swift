import AppKit
import WebKit

/// A viewer window. Holds one or more files as tabs; with a single file it shows
/// just the centered title, from two on the title bar turns into a tab bar.
final class ViewerWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation,
    NSSearchFieldDelegate {
    private static let frameName = "NxmdViewer"
    private static let zoomKey = "pageZoom"
    private static let zoomLevels: [Double] = [0.75, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2]

    /// Open windows. A window does not retain its controller, so they live here.
    private static var all: [ViewerWindowController] = []
    /// The window used most recently; newly opened files become tabs in it.
    private static weak var current: ViewerWindowController?

    private let contentHost = NSView()
    private let topBar = TopBar()
    private let tabBar = TabBar()
    private let dock = Dock()
    private var dockBottom: NSLayoutConstraint!
    private var dockVisible = true

    private var tabs: [DocumentTab] = []
    private var activeIndex = -1
    private var zoom: Double
    private var showsTabBar = false

    private var active: DocumentTab? {
        tabs.indices.contains(activeIndex) ? tabs[activeIndex] : nil
    }

    /// The window a newly opened document joins, even when it is minimized or the app is hidden.
    static func forNewDocument() -> ViewerWindowController {
        if let current { return current }
        let front = NSApp.orderedWindows.lazy
            .compactMap { $0.windowController as? ViewerWindowController }
            .first
        return front ?? all.last ?? ViewerWindowController()
    }

    /// The file shown in the main window, for NSDocumentController.currentDocument.
    static var mainDocument: MarkdownDocument? {
        (NSApp.mainWindow?.windowController as? ViewerWindowController)?.active?.document
    }

    init() {
        let window = ViewerWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 940),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = NSToolbar() // taller title bar, traffic lights centered in it
        window.toolbarStyle = .unifiedCompact
        window.backgroundColor = Theme.background
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 440, height: 320)
        window.isRestorable = false
        window.tabbingMode = .disallowed

        let saved = UserDefaults.standard.double(forKey: Self.zoomKey)
        zoom = saved > 0 ? saved : 1

        super.init(window: window)

        window.delegate = self
        window.onTabShortcut = { [weak self] in self?.handle($0) ?? false }
        for button in [dock.outline, dock.search, dock.zoom, dock.source, dock.edit] { button.target = self }
        dock.searchField.delegate = self
        if let editor = ExternalEditor.app {
            dock.edit.toolTip = "Open in \(editor.name) (⇧⌘E)"
        }
        tabBar.onSelect = { [weak self] in self?.select($0) }
        tabBar.onClose = { [weak self] in self?.closeTab(at: $0, byMouse: true) }
        tabBar.onMove = { [weak self] in self?.tabMoved(from: $0, to: $1) }
        tabBar.alphaValue = 0
        tabBar.isHidden = true
        updateZoomLabel()
        buildLayout(in: window)
        placeWindow(window)

        Self.all.append(self)
        Self.current = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildLayout(in window: NSWindow) {
        let container = ContainerView()
        container.onMouseMove = { [weak self] point in
            if point.y < 110 { self?.setDockVisible(true) }
        }
        for view in [contentHost, topBar, tabBar, dock] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        window.contentView = container

        let titleBarBottom = (window.contentLayoutGuide as? NSLayoutGuide)?.topAnchor ?? container.topAnchor
        let headerBottom = topBar.bottomAnchor.constraint(equalTo: titleBarBottom)
        headerBottom.priority = .defaultHigh
        dockBottom = dock.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -18)
        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            topBar.topAnchor.constraint(equalTo: container.topAnchor),
            headerBottom,
            // Full screen hides the title bar; keep room for the tabs anyway.
            topBar.heightAnchor.constraint(greaterThanOrEqualToConstant: 38),

            tabBar.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),
            tabBar.topAnchor.constraint(equalTo: topBar.topAnchor),
            tabBar.bottomAnchor.constraint(equalTo: topBar.bottomAnchor),

            contentHost.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            contentHost.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            contentHost.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            dock.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            dockBottom,
        ])
    }

    private func placeWindow(_ window: NSWindow) {
        let others = NSApp.windows.filter {
            $0 !== window && $0.isVisible && $0.windowController is ViewerWindowController
        }
        if let last = others.last {
            window.setFrame(last.frame, display: false)
            window.setFrameTopLeftPoint(NSPoint(x: last.frame.minX + 26, y: last.frame.maxY - 26))
        } else if !window.setFrameUsingName(Self.frameName) {
            window.center()
        }
        _ = window.setFrameAutosaveName(Self.frameName)
    }

    func windowDidBecomeMain(_ notification: Notification) {
        Self.current = self
    }

    func windowWillClose(_ notification: Notification) {
        let closing = tabs
        tabs.removeAll()
        activeIndex = -1
        for tab in closing {
            tab.teardown()
            tab.document.close()
        }
        Self.all.removeAll { $0 === self }
        if Self.current === self { Self.current = nil }
    }

    func windowWillEnterFullScreen(_ notification: Notification) { tabBar.leadingInset = 12 }
    func windowWillExitFullScreen(_ notification: Notification) { tabBar.leadingInset = 80 }

    // MARK: - Tabs

    func addTab(for document: MarkdownDocument) {
        let tab = DocumentTab(document: document, zoom: zoom)
        tab.host = self
        document.tab = tab

        let index = tabs.count
        tabs.append(tab)
        tab.webView.frame = contentHost.bounds
        tab.webView.autoresizingMask = [.width, .height]
        tab.webView.isHidden = true
        contentHost.addSubview(tab.webView)
        tabBar.insertTab(title: tab.title, tooltip: Self.tooltip(for: document),
                         at: index, animated: showsTabBar)
        tab.render()
        select(index)
        updateTabBarVisibility()
    }

    /// Brings the document's tab and its window to the front.
    func show(_ tab: DocumentTab) {
        if let index = tabs.firstIndex(where: { $0 === tab }) { select(index) }
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        showWindow(nil)
    }

    func select(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        let tab = tabs[index]
        let old = active === tab ? nil : active
        // Where the keyboard focus is, before hiding anything moves it.
        let responder = window?.firstResponder
        let focusInField = (responder as? NSText)?.delegate === dock.searchField
        let focusInPage = old.map { (responder as? NSView)?.isDescendant(of: $0.webView) ?? false } ?? false
        if let old {
            old.findText = dock.searchField.stringValue
            old.isSearching = dock.isSearching
        }

        activeIndex = index
        tab.webView.isHidden = false
        old?.webView.isHidden = true

        dock.searchField.stringValue = tab.findText
        dock.searchField.textColor = .labelColor
        if focusInField, !tab.isSearching { window?.makeFirstResponder(tab.webView) }
        dock.setSearching(tab.isSearching, animated: false)
        let lostFocus = window?.firstResponder == nil || window?.firstResponder === window
        if focusInPage || lostFocus { window?.makeFirstResponder(tab.webView) }

        tabBar.select(index)
        showProgress(of: tab)
        updateChrome(for: tab)
        setDockVisible(true)
    }

    @objc func closeTab(_ sender: Any?) {
        closeTab(at: activeIndex, byMouse: false)
    }

    private func closeTab(at index: Int, byMouse: Bool) {
        guard tabs.indices.contains(index) else { return }
        guard tabs.count > 1 else {
            window?.performClose(nil)
            return
        }
        let wasActive = index == activeIndex
        let tab = tabs.remove(at: index)
        tab.webView.removeFromSuperview()
        tab.teardown()
        tab.document.close()
        tabBar.removeTab(at: index, byMouse: byMouse)

        if wasActive {
            // The tab to the right takes its place; the last one hands over to the left.
            activeIndex = -1
            select(min(index, tabs.count - 1))
        } else if index < activeIndex {
            activeIndex -= 1
        }
        updateTabBarVisibility()
    }

    private func tabMoved(from: Int, to: Int) {
        let selected = active
        tabs.insert(tabs.remove(at: from), at: to)
        activeIndex = tabs.firstIndex { $0 === selected } ?? activeIndex
    }

    @objc func showNextTab(_ sender: Any?) {
        guard tabs.count > 1 else { return }
        select((activeIndex + 1) % tabs.count)
    }

    @objc func showPreviousTab(_ sender: Any?) {
        guard tabs.count > 1 else { return }
        select((activeIndex - 1 + tabs.count) % tabs.count)
    }

    /// Returns false when the shortcut does not apply, so the key works as usual.
    private func handle(_ shortcut: TabShortcut) -> Bool {
        guard tabs.count > 1 else { return false }
        switch shortcut {
        case .next: showNextTab(nil)
        case .previous: showPreviousTab(nil)
        case .index(let index):
            guard tabs.indices.contains(index) else { return false }
            select(index)
        case .last: select(tabs.count - 1)
        }
        return true
    }

    private func updateTabBarVisibility() {
        let show = tabs.count > 1
        guard show != showsTabBar else { return }
        showsTabBar = show
        if show { tabBar.isHidden = false }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Theme.reduceMotion ? 0 : 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            tabBar.animator().alphaValue = show ? 1 : 0
            topBar.animator().alphaValue = show ? 0 : 1
        }, completionHandler: { [weak self] in
            guard let self, !self.showsTabBar else { return }
            self.tabBar.isHidden = true
        })
    }

    private static func tooltip(for document: MarkdownDocument) -> String? {
        document.fileURL.map { ($0.path as NSString).abbreviatingWithTildeInPath }
    }

    // MARK: - Tab callbacks

    func tabDidRender(_ tab: DocumentTab) {
        if let index = tabs.firstIndex(where: { $0 === tab }) {
            tabBar.setTitle(tab.title, tooltip: Self.tooltip(for: tab.document), at: index)
        }
        if tab === active { updateChrome(for: tab) }
    }

    private func updateChrome(for tab: DocumentTab) {
        topBar.title = tab.title
        window?.title = tab.title
        dock.outline.isEnabled = !tab.headings.isEmpty
        dock.source.isActive = tab.showingSource
    }

    // MARK: - Scroll: progress line and toolbar auto-hide

    func tabDidScroll(_ tab: DocumentTab) {
        guard tab === active else { return }
        showProgress(of: tab)
        guard !dock.isSearching else { return }
        let nearTop = tab.scrollY < 40
        let nearBottom = tab.scrollY > tab.scrollMax - 8
        if nearTop || nearBottom || tab.scrollRun < -24 {
            setDockVisible(true)
        } else if tab.scrollRun > 24 {
            setDockVisible(false)
        }
    }

    private func showProgress(of tab: DocumentTab) {
        topBar.setProgress(tab.progress)
        tabBar.setProgress(tab.progress)
    }

    private func setDockVisible(_ visible: Bool) {
        guard visible != dockVisible else { return }
        dockVisible = visible
        if visible { dock.isHidden = false }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            dock.animator().alphaValue = visible ? 1 : 0
            if !Theme.reduceMotion {
                dockBottom.animator().constant = visible ? -18 : -8
            }
        }, completionHandler: { [weak self] in
            guard let self, !self.dockVisible else { return }
            self.dock.isHidden = true
        })
    }

    // MARK: - Toolbar actions

    @objc func showOutline(_ sender: Any?) {
        guard let headings = active?.headings, !headings.isEmpty else { return }
        setDockVisible(true)
        let menu = NSMenu()
        let minLevel = headings.map(\.level).min() ?? 1
        for heading in headings where heading.level <= minLevel + 2 {
            let item = NSMenuItem(title: heading.text, action: #selector(jumpToHeading(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = heading.id
            item.indentationLevel = heading.level - minLevel
            menu.addItem(item)
        }
        popUp(menu, above: dock.outline)
    }

    @objc private func jumpToHeading(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        active?.jump(toHeading: id)
    }

    @objc func showZoomMenu(_ sender: Any?) {
        let menu = NSMenu()
        for level in Self.zoomLevels {
            let item = NSMenuItem(title: "\(Int((level * 100).rounded()))%", action: #selector(pickZoom(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = level
            item.state = abs(level - zoom) < 0.01 ? .on : .off
            menu.addItem(item)
        }
        popUp(menu, above: dock.zoom)
    }

    @objc private func pickZoom(_ item: NSMenuItem) {
        if let level = item.representedObject as? Double { setZoom(level) }
    }

    @objc func toggleSource(_ sender: Any?) {
        active?.toggleSource()
    }

    @objc func openInEditor(_ sender: Any?) {
        if let url = active?.document.fileURL { ExternalEditor.open(url) }
    }

    @objc func printDocument(_ sender: Any?) {
        active?.document.printDocument(sender)
    }

    private func popUp(_ menu: NSMenu, above button: NSView) {
        let height = menu.size.height
        let y = button.isFlipped ? -(height + 8) : button.bounds.height + height + 8
        menu.popUp(positioning: nil, at: NSPoint(x: -4, y: y), in: button)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleSource(_:)):
            item.title = active?.showingSource == true ? "Show Rendered" : "Show Source"
            return active != nil
        case #selector(showOutline(_:)):
            return active?.headings.isEmpty == false
        case #selector(openInEditor(_:)):
            if let editor = ExternalEditor.app { item.title = "Open in \(editor.name)" }
            return active?.document.fileURL != nil
        case #selector(showNextTab(_:)), #selector(showPreviousTab(_:)):
            return tabs.count > 1
        case #selector(closeTab(_:)), #selector(printDocument(_:)):
            return active != nil
        default:
            return true
        }
    }

    // MARK: - Find

    @objc func showFindBar(_ sender: Any?) {
        setDockVisible(true)
        dock.setSearching(true)
        window?.makeFirstResponder(dock.searchField)
        dock.searchField.currentEditor()?.selectAll(nil)
    }

    @objc func findNext(_ sender: Any?) {
        dock.isSearching ? find(backwards: false) : showFindBar(sender)
    }

    @objc func findPrevious(_ sender: Any?) {
        dock.isSearching ? find(backwards: true) : showFindBar(sender)
    }

    private func closeFind() {
        dock.setSearching(false)
        if let tab = active {
            tab.isSearching = false
            window?.makeFirstResponder(tab.webView)
        }
    }

    private func find(backwards: Bool) {
        let field = dock.searchField
        guard let tab = active else { return }
        tab.findText = field.stringValue
        guard !field.stringValue.isEmpty else {
            field.textColor = .labelColor
            return
        }
        tab.find(backwards: backwards) { [weak field] found in
            field?.textColor = found ? .labelColor : .systemRed
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        find(backwards: false)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            closeFind()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            find(backwards: NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false)
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if dock.searchField.stringValue.isEmpty { dock.setSearching(false) }
    }

    // MARK: - Zoom

    @objc func zoomIn(_ sender: Any?) { setZoom(zoom * 1.1) }
    @objc func zoomOut(_ sender: Any?) { setZoom(zoom / 1.1) }
    @objc func resetZoom(_ sender: Any?) { setZoom(1) }

    /// Text size is one preference for the whole app.
    private func setZoom(_ value: Double) {
        let zoom = min(max(value, 0.5), 3)
        UserDefaults.standard.set(zoom, forKey: Self.zoomKey)
        Self.all.forEach { $0.apply(zoom: zoom) }
    }

    private func apply(zoom: Double) {
        self.zoom = zoom
        tabs.forEach { $0.webView.pageZoom = zoom }
        updateZoomLabel()
    }

    private func updateZoomLabel() {
        dock.zoom.setTitle("\(Int((zoom * 100).rounded()))%")
    }
}

// MARK: - Window

enum TabShortcut {
    case next, previous, index(Int), last

    private static let tabKey: UInt16 = 48
    private static let rightBracketKey: UInt16 = 30
    private static let leftBracketKey: UInt16 = 33

    init?(_ event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch (event.keyCode, modifiers) {
        case (Self.tabKey, [.control]): self = .next
        case (Self.tabKey, [.control, .shift]): self = .previous
        case (Self.rightBracketKey, [.command, .shift]): self = .next
        case (Self.leftBracketKey, [.command, .shift]): self = .previous
        default:
            guard modifiers == .command,
                  let digit = event.charactersIgnoringModifiers.flatMap(Int.init),
                  (1...9).contains(digit) else { return nil }
            self = digit == 9 ? .last : .index(digit - 1)
        }
    }
}

/// Catches tab shortcuts before the web view or the menu sees them.
final class ViewerWindow: NSWindow {
    var onTabShortcut: ((TabShortcut) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let shortcut = TabShortcut(event), onTabShortcut?(shortcut) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        // ⌃Tab never arrives as a key equivalent; it would move the focus instead.
        if event.type == .keyDown, event.keyCode == 48, event.modifierFlags.contains(.control),
           let shortcut = TabShortcut(event), onTabShortcut?(shortcut) == true {
            return
        }
        super.sendEvent(event)
    }
}
