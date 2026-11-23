import AppKit
import WebKit

final class ViewerWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation,
    NSSearchFieldDelegate, WKNavigationDelegate, WKUIDelegate {
    private static let frameName = "NxmdViewer"
    private static let zoomKey = "pageZoom"
    private static let zoomLevels: [Double] = [0.75, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2]
    private static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdx"]
    /// The app's own scripts run in this world; the page's scripts are disabled.
    private static let world = WKContentWorld.world(name: "nxmd")

    private let webView: SmoothWebView
    private let topBar = TopBar()
    private let dock: Dock
    private var dockBottom: NSLayoutConstraint!
    private var dockVisible = true

    private var pageLoaded = false
    private var loadedBaseURL: URL?
    private var headings: [Heading] = []
    private var showingSource = false
    private var lastScrollY: Double = 0
    private var scrollRun: Double = 0 // distance scrolled in the current direction

    init() {
        let window = NSWindow(
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

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(LocalFileSchemeHandler(), forURLScheme: LocalFileSchemeHandler.scheme)
        // Markdown can contain raw HTML; never run scripts from it.
        config.defaultWebpagePreferences.allowsContentJavaScript = false

        webView = SmoothWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = true
        let zoom = UserDefaults.standard.double(forKey: Self.zoomKey)
        webView.pageZoom = zoom > 0 ? zoom : 1

        let proxy = ScrollMessageProxy()
        config.userContentController.add(proxy, contentWorld: Self.world, name: "scroll")
        config.userContentController.addUserScript(WKUserScript(
            source: Self.scrollScript, injectionTime: .atDocumentEnd,
            forMainFrameOnly: true, in: Self.world))
        CodeCopy.install(in: config.userContentController, world: Self.world)

        dock = Dock()
        super.init(window: window)

        proxy.owner = self
        window.delegate = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.onWheel = { [weak self] delta, point in
            guard let self, self.pageLoaded, !Theme.reduceMotion else { return false }
            let zoom = self.webView.pageZoom
            self.runScript("nxmdWheel(dy, x, y)", [
                "dy": Double(delta) * 50,
                "x": Double(point.x) / zoom,
                "y": Double(point.y) / zoom,
            ])
            return true
        }
        for button in [dock.outline, dock.search, dock.zoom, dock.source, dock.edit] { button.target = self }
        dock.searchField.delegate = self
        if let editor = ExternalEditor.app {
            dock.edit.toolTip = "Open in \(editor.name) (⇧⌘E)"
        }
        updateZoomLabel()
        buildLayout(in: window)
        placeWindow(window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildLayout(in window: NSWindow) {
        let container = ContainerView()
        container.onMouseMove = { [weak self] point in
            if point.y < 110 { self?.setDockVisible(true) }
        }
        for view in [webView, topBar, dock] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        window.contentView = container

        let titleBarBottom = (window.contentLayoutGuide as? NSLayoutGuide)?.topAnchor ?? container.topAnchor
        dockBottom = dock.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -18)
        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            topBar.topAnchor.constraint(equalTo: container.topAnchor),
            topBar.bottomAnchor.constraint(equalTo: titleBarBottom),

            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

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

    override var document: AnyObject? {
        didSet { render() }
    }

    private var markdownDocument: MarkdownDocument? { document as? MarkdownDocument }

    func windowWillClose(_ notification: Notification) {
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    // MARK: - Rendering

    func render() {
        guard let doc = markdownDocument else { return }
        topBar.title = doc.displayName
        let body: String
        if showingSource {
            body = Renderer.shared.source(doc.text)
            headings = []
        } else {
            let rendered = Renderer.shared.render(doc.text)
            body = rendered.html
            headings = rendered.headings
        }
        dock.outline.isEnabled = !headings.isEmpty
        dock.source.isActive = showingSource

        let baseURL = doc.fileURL.map {
            LocalFileSchemeHandler.baseURL(forDirectory: $0.deletingLastPathComponent())
        }
        if pageLoaded, baseURL == loadedBaseURL {
            // Swap the content in place: keeps scroll position, no flash.
            webView.callAsyncJavaScript(
                "document.getElementById('content').innerHTML = html; nxmdReport();",
                arguments: ["html": body], in: nil, in: Self.world
            ) { [weak self] result in
                if case .failure = result { self?.loadPage(body: body, baseURL: baseURL) }
            }
        } else {
            loadPage(body: body, baseURL: baseURL)
        }
    }

    private func loadPage(body: String, baseURL: URL?) {
        pageLoaded = false
        loadedBaseURL = baseURL
        webView.loadHTMLString(Renderer.shared.page(body: body), baseURL: baseURL)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
    }

    private func runScript(_ source: String, _ arguments: [String: Any] = [:]) {
        webView.callAsyncJavaScript(source, arguments: arguments, in: nil, in: Self.world) { result in
            if case .failure(let error) = result { NSLog("nxmd script error: \(error)") }
        }
    }

    // MARK: - Scroll: progress line and toolbar auto-hide

    private static let scrollScript = """
    (function () {
      var pending = false;
      function report() {
        pending = false;
        var el = document.scrollingElement || document.documentElement;
        window.webkit.messageHandlers.scroll.postMessage({ y: el.scrollTop, max: el.scrollHeight - el.clientHeight });
      }
      globalThis.nxmdReport = function () {
        if (!pending) { pending = true; requestAnimationFrame(report); }
      };
      addEventListener('scroll', nxmdReport, { passive: true });
      addEventListener('resize', nxmdReport);
      nxmdReport();

      // Smooth mouse-wheel scrolling: ease toward a target position.
      var target = null, frame = 0, lastSet = null;
      function root() { return document.scrollingElement || document.documentElement; }
      function stop() {
        if (frame) cancelAnimationFrame(frame);
        target = null; frame = 0; lastSet = null;
      }
      function step() {
        var el = root();
        target = Math.max(0, Math.min(el.scrollHeight - el.clientHeight, target));
        var diff = target - el.scrollTop;
        if (Math.abs(diff) < 1.5) {
          el.scrollTo({ top: target, behavior: 'instant' });
          stop();
          return;
        }
        // Ease out, but always move at least 1px so rounding can't stall it.
        var move = Math.sign(diff) * Math.max(Math.abs(diff) * 0.2, 1);
        var before = el.scrollTop;
        el.scrollTo({ top: before + move, behavior: 'instant' });
        if (el.scrollTop === before) { stop(); return; } // can't move any further
        lastSet = el.scrollTop;
        frame = requestAnimationFrame(step);
      }
      // Any scroll we didn't make (keyboard, trackpad, find, links) cancels the animation.
      addEventListener('scroll', function () {
        if (target !== null && lastSet !== null && Math.abs(root().scrollTop - lastSet) > 2) stop();
      }, { passive: true });
      globalThis.nxmdStopSmooth = stop;

      // Nearest inner box under the cursor that can still scroll in this direction.
      function innerScrollable(x, y, dy) {
        var el = document.elementFromPoint(x, y);
        while (el && el !== document.body && el !== document.documentElement) {
          var overflow = getComputedStyle(el).overflowY;
          if ((overflow === 'auto' || overflow === 'scroll') && el.scrollHeight > el.clientHeight) {
            var canUp = el.scrollTop > 0;
            var canDown = el.scrollTop + el.clientHeight < el.scrollHeight - 1;
            if ((dy > 0 && canUp) || (dy < 0 && canDown)) return el;
          }
          el = el.parentElement;
        }
        return null;
      }

      globalThis.nxmdWheel = function (dy, x, y) {
        var inner = innerScrollable(x, y, dy);
        if (inner) { inner.scrollBy({ top: -dy, behavior: 'smooth' }); return; }
        var el = root();
        if (target === null) target = el.scrollTop;
        target = Math.max(0, Math.min(el.scrollHeight - el.clientHeight, target - dy));
        if (!frame) frame = requestAnimationFrame(step);
      };
    })();
    """

    fileprivate func pageScrolled(y: Double, max: Double) {
        topBar.setProgress(max > 1 ? CGFloat(y / max) : nil)

        let delta = y - lastScrollY
        lastScrollY = y
        if delta != 0 {
            // Reset when the direction changes, so slow scrolls add up too.
            scrollRun = (scrollRun >= 0) == (delta >= 0) ? scrollRun + delta : delta
        }
        guard !dock.isSearching else { return }
        let nearTop = y < 40
        let nearBottom = y > max - 8
        if nearTop || nearBottom || scrollRun < -24 {
            setDockVisible(true)
        } else if scrollRun > 24 {
            setDockVisible(false)
        }
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
        guard !headings.isEmpty else { return }
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
        runScript("nxmdStopSmooth(); document.getElementById(id)?.scrollIntoView({ block: 'start' })", ["id": id])
    }

    @objc func showZoomMenu(_ sender: Any?) {
        let menu = NSMenu()
        for level in Self.zoomLevels {
            let item = NSMenuItem(title: "\(Int((level * 100).rounded()))%", action: #selector(pickZoom(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = level
            item.state = abs(level - webView.pageZoom) < 0.01 ? .on : .off
            menu.addItem(item)
        }
        popUp(menu, above: dock.zoom)
    }

    @objc private func pickZoom(_ item: NSMenuItem) {
        if let level = item.representedObject as? Double { setZoom(level) }
    }

    @objc func toggleSource(_ sender: Any?) {
        showingSource.toggle()
        render()
        runScript("nxmdStopSmooth(); window.scrollTo(0, 0)")
    }

    @objc func openInEditor(_ sender: Any?) {
        if let url = markdownDocument?.fileURL { ExternalEditor.open(url) }
    }

    private func popUp(_ menu: NSMenu, above button: NSView) {
        let height = menu.size.height
        let y = button.isFlipped ? -(height + 8) : button.bounds.height + height + 8
        menu.popUp(positioning: nil, at: NSPoint(x: -4, y: y), in: button)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleSource(_:)):
            item.title = showingSource ? "Show Rendered" : "Show Source"
        case #selector(showOutline(_:)):
            return !headings.isEmpty
        case #selector(openInEditor(_:)):
            if let editor = ExternalEditor.app { item.title = "Open in \(editor.name)" }
            return markdownDocument?.fileURL != nil
        default:
            break
        }
        return true
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
        window?.makeFirstResponder(webView)
    }

    private func find(backwards: Bool) {
        let field = dock.searchField
        guard !field.stringValue.isEmpty else {
            field.textColor = .labelColor
            return
        }
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.wraps = true
        config.caseSensitive = false
        webView.find(field.stringValue, configuration: config) { result in
            field.textColor = result.matchFound ? .labelColor : .systemRed
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

    @objc func zoomIn(_ sender: Any?) { setZoom(webView.pageZoom * 1.1) }
    @objc func zoomOut(_ sender: Any?) { setZoom(webView.pageZoom / 1.1) }
    @objc func resetZoom(_ sender: Any?) { setZoom(1) }

    private func setZoom(_ value: Double) {
        let zoom = min(max(value, 0.5), 3)
        webView.pageZoom = zoom
        UserDefaults.standard.set(zoom, forKey: Self.zoomKey)
        updateZoomLabel()
    }

    private func updateZoomLabel() {
        dock.zoom.setTitle("\(Int((webView.pageZoom * 100).rounded()))%")
    }

    // MARK: - Links

    func webView(_ webView: WKWebView,
                 decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard action.navigationType == .linkActivated, let url = action.request.url else {
            decisionHandler(.allow)
            return
        }
        if url.fragment != nil, let current = webView.url, url.withoutFragment == current.withoutFragment {
            decisionHandler(.allow) // in-page anchor
            return
        }
        decisionHandler(.cancel)
        open(url)
    }

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { open(url) }
        return nil
    }

    private func open(_ url: URL) {
        guard url.scheme == LocalFileSchemeHandler.scheme else {
            NSWorkspace.shared.open(url)
            return
        }
        guard let file = LocalFileSchemeHandler.fileURL(from: url) else { return }
        if Self.markdownExtensions.contains(file.pathExtension.lowercased()) {
            NSDocumentController.shared.openDocument(withContentsOf: file, display: true) { _, _, _ in }
        } else {
            NSWorkspace.shared.open(file)
        }
    }

    // MARK: - Print

    func printOperation(printInfo: NSPrintInfo) -> NSPrintOperation {
        let info = printInfo.copy() as! NSPrintInfo
        info.isVerticallyCentered = false
        info.horizontalPagination = .fit
        let op = webView.printOperation(with: info)
        op.view?.frame = webView.bounds
        return op
    }
}

/// Breaks the retain cycle between WKUserContentController and the window controller.
private final class ScrollMessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: ViewerWindowController?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let y = (body["y"] as? NSNumber)?.doubleValue,
              let max = (body["max"] as? NSNumber)?.doubleValue else { return }
        owner?.pageScrolled(y: y, max: max)
    }
}

private extension URL {
    var withoutFragment: URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.url ?? self
    }
}
