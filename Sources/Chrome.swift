import AppKit
import WebKit

/// Icon button with a soft hover background, used in the floating toolbar.
final class ToolButton: NSButton {
    var isActive = false { didSet { refresh() } }
    override var isEnabled: Bool { didSet { refresh() } }
    private var hovering = false { didSet { refresh() } }

    init(symbol: String? = nil, title: String? = nil, tooltip: String, action: Selector, width: CGFloat = 32) {
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryChange)
        self.title = ""
        self.action = action
        toolTip = tooltip
        setAccessibilityLabel(tooltip)
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
            imagePosition = .imageOnly
        }
        if let title { setTitle(title) }
        wantsLayer = true
        layer?.cornerRadius = 8
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: 32),
        ])
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setTitle(_ text: String) {
        title = text
        refresh()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func viewDidHide() { hovering = false }
    override func viewDidUnhide() { hovering = false }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    private func refresh() {
        let lit = isEnabled && (hovering || isActive)
        let color = !isEnabled ? Theme.muted.withAlphaComponent(0.4) : (lit ? Theme.foreground : Theme.muted)
        layer?.backgroundColor = lit ? Theme.hover.cgColor : NSColor.clear.cgColor
        contentTintColor = color
        if !title.isEmpty {
            attributedTitle = NSAttributedString(string: title, attributes: [
                .font: Theme.mono(12, weight: .medium),
                .foregroundColor: color,
            ])
        }
    }
}

/// The floating toolbar at the bottom of the window.
final class Dock: NSView {
    let outline = ToolButton(symbol: "list.bullet", tooltip: "Outline", action: #selector(ViewerWindowController.showOutline(_:)))
    let search = ToolButton(symbol: "magnifyingglass", tooltip: "Find (⌘F)", action: #selector(ViewerWindowController.showFindBar(_:)))
    let zoom = ToolButton(title: "100%", tooltip: "Text size", action: #selector(ViewerWindowController.showZoomMenu(_:)), width: 54)
    let source = ToolButton(symbol: "chevron.left.forwardslash.chevron.right", tooltip: "Show Markdown source (⌥⌘U)", action: #selector(ViewerWindowController.toggleSource(_:)))
    let edit = ToolButton(symbol: "pencil", tooltip: "Open in editor (⇧⌘E)", action: #selector(ViewerWindowController.openInEditor(_:)))
    let searchField = NSSearchField()

    private let stack = NSStackView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.dockFill.cgColor
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.borderColor = Theme.border.cgColor
        shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.6)
            s.shadowBlurRadius = 24
            s.shadowOffset = NSSize(width: 0, height: -8)
            return s
        }()

        searchField.placeholderString = "Find"
        searchField.font = Theme.sans(13)
        searchField.focusRingType = .none
        searchField.sendsSearchStringImmediately = true
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(equalToConstant: 190).isActive = true
        searchField.isHidden = true

        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [outline, search, searchField, Self.divider(), zoom, Self.divider(), source, edit] {
            stack.addArrangedSubview(view)
        }
        stack.setCustomSpacing(6, after: searchField)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var isSearching: Bool { !searchField.isHidden }

    func setSearching(_ on: Bool, animated: Bool = true) {
        guard on != isSearching else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Theme.reduceMotion || !animated ? 0 : 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            searchField.isHidden = !on
            search.isActive = on
            superview?.layoutSubtreeIfNeeded()
        }
    }

    private static func divider() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = Theme.border.cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 1),
            view.heightAnchor.constraint(equalToConstant: 18),
        ])
        return view
    }
}

/// File name centered in the title bar, with a thin reading-progress line under it.
final class TopBar: NSView {
    private let label = NSTextField(labelWithString: "")
    private let progressLayer = CAGradientLayer()
    private var progress: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        label.font = Theme.sans(13, weight: .medium)
        label.textColor = Theme.muted
        label.lineBreakMode = .byTruncatingMiddle
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 90),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -90),
        ])
        progressLayer.startPoint = CGPoint(x: 0, y: 0.5)
        progressLayer.endPoint = CGPoint(x: 1, y: 0.5)
        progressLayer.colors = [Theme.progress.withAlphaComponent(0).cgColor, Theme.progress.cgColor]
        progressLayer.opacity = 0
        layer?.addSublayer(progressLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    /// `nil` hides the line (the page does not scroll).
    func setProgress(_ value: CGFloat?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progressLayer.opacity = value == nil ? 0 : 1
        progress = min(max(value ?? 0, 0), 1)
        layoutProgress()
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        layoutProgress()
    }

    private func layoutProgress() {
        progressLayer.frame = CGRect(x: 0, y: 0, width: bounds.width * progress, height: 1)
    }
}

/// Root view that reports mouse movement, so the toolbar can reappear near the bottom edge.
final class ContainerView: NSView {
    var onMouseMove: ((NSPoint) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        onMouseMove?(convert(event.locationInWindow, from: nil))
    }
}

/// Mouse wheels scroll in coarse steps in WebKit. Hand them to `onWheel` to animate;
/// trackpads (precise deltas with native momentum) pass through untouched.
final class SmoothWebView: WKWebView {
    /// Vertical delta and the cursor position in top-left view coordinates.
    var onWheel: ((CGFloat, NSPoint) -> Bool)?

    override func scrollWheel(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        var point = convert(event.locationInWindow, from: nil)
        if !isFlipped { point.y = bounds.height - point.y }
        if !event.hasPreciseScrollingDeltas, plain, event.scrollingDeltaY != 0,
           let onWheel, onWheel(event.scrollingDeltaY, point) {
            return
        }
        super.scrollWheel(with: event)
    }
}
