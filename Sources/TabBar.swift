import AppKit

/// Browser-style tabs in the title bar, shown while a window holds two or more files.
/// All black: a thin line runs under the bar, and the selected tab is outlined with a
/// rounded top and opens onto the page. Reading progress runs along its top edge.
final class TabBar: NSView {
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onMove: ((_ from: Int, _ to: Int) -> Void)?

    /// Space kept free for the traffic lights.
    var leadingInset: CGFloat = 80 { didSet { needsLayout = true } }

    private static let maxWidth: CGFloat = 220
    private static let minWidth: CGFloat = 72
    private static let gap: CGFloat = 2
    private static let trailingInset: CGFloat = 8
    private static let topInset: CGFloat = 8

    private let baseline = NSView()
    private let clip = NSView()
    private let strip = FlippedView()
    private let fade = CAGradientLayer()
    private let animator = FrameAnimator()

    private var items: [TabItemView] = []
    private(set) var selectedIndex = 0
    private var offset: CGFloat = 0
    /// After a close by mouse, tabs keep their width until the cursor leaves the bar,
    /// so the next close button lands under the cursor.
    private var frozenWidth: CGFloat?
    private var drag: (item: TabItemView, grab: CGFloat, startX: CGFloat, moved: Bool)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        baseline.wantsLayer = true
        baseline.layer?.backgroundColor = Theme.tabLine.cgColor
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        strip.wantsLayer = true
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        addSubview(baseline)
        addSubview(clip)
        clip.addSubview(strip)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Public API

    func insertTab(title: String, tooltip: String?, at index: Int, animated: Bool) {
        let item = TabItemView(bar: self)
        item.title = title
        item.toolTip = tooltip
        items.insert(item, at: index)
        strip.addSubview(item)
        if index <= selectedIndex, items.count > 1 { selectedIndex += 1 }
        frozenWidth = nil

        let width = tabWidth()
        let slot = slotFrame(index, width: width)
        if animated, !Theme.reduceMotion {
            item.frame = NSRect(x: slot.minX, y: slot.minY, width: 0, height: slot.height)
            item.alphaValue = 0
        } else {
            item.frame = slot
        }
        layoutItems(animated: animated)
    }

    func removeTab(at index: Int, byMouse: Bool) {
        guard items.indices.contains(index) else { return }
        if byMouse, frozenWidth == nil, items.count > 1 {
            frozenWidth = items[index].frame.width
        }
        let item = items.remove(at: index)
        item.isClosing = true
        if index < selectedIndex { selectedIndex -= 1 }
        selectedIndex = min(selectedIndex, max(items.count - 1, 0))
        let collapsed = NSRect(x: item.frame.minX, y: item.frame.minY, width: 0, height: item.frame.height)
        animator.animate(item, to: collapsed, alpha: 0) { [weak self] in
            item.removeFromSuperview()
            // The next tab slid under a still cursor: show its hover and close button.
            self?.items.forEach { $0.syncHover() }
        }
        layoutItems(animated: true)
    }

    func moveTab(from: Int, to: Int) {
        guard items.indices.contains(from), items.indices.contains(to), from != to else { return }
        let selected = items[selectedIndex]
        items.insert(items.remove(at: from), at: to)
        selectedIndex = items.firstIndex(of: selected) ?? selectedIndex
        layoutItems(animated: true)
    }

    func select(_ index: Int) {
        guard items.indices.contains(index) else { return }
        selectedIndex = index
        for (i, item) in items.enumerated() { item.isSelected = i == index }
        scrollToSelected(animated: true)
    }

    func setTitle(_ title: String, tooltip: String?, at index: Int) {
        guard items.indices.contains(index) else { return }
        items[index].title = title
        items[index].toolTip = tooltip
    }

    /// Reading progress of the selected tab; nil hides the line.
    func setProgress(_ value: CGFloat?) {
        guard items.indices.contains(selectedIndex) else { return }
        items[selectedIndex].progress = value
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        baseline.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
        clip.frame = NSRect(x: leadingInset, y: 0,
                            width: max(bounds.width - leadingInset - Self.trailingInset, 0),
                            height: bounds.height)
        layoutItems(animated: false)
    }

    private var itemHeight: CGFloat { max(bounds.height - Self.topInset, 0) }

    private func tabWidth() -> CGFloat {
        if let frozenWidth { return frozenWidth }
        let count = CGFloat(max(items.count, 1))
        let fit = floor((clip.bounds.width - Self.gap * (count - 1)) / count)
        return min(Self.maxWidth, max(Self.minWidth, fit))
    }

    private func slotFrame(_ index: Int, width: CGFloat) -> NSRect {
        // The strip is flipped; tabs hang from the top inset down to the bottom edge.
        NSRect(x: CGFloat(index) * (width + Self.gap), y: Self.topInset, width: width, height: itemHeight)
    }

    private var contentWidth: CGFloat {
        let count = CGFloat(items.count)
        return count == 0 ? 0 : count * tabWidth() + (count - 1) * Self.gap
    }

    private var maxOffset: CGFloat { max(contentWidth - clip.bounds.width, 0) }

    private func layoutItems(animated: Bool) {
        let width = tabWidth()
        for (index, item) in items.enumerated() {
            if let drag, drag.moved, drag.item === item { continue }
            let target = slotFrame(index, width: width)
            if animated {
                animator.animate(item, to: target, alpha: 1)
            } else if !animator.retarget(item, to: target) {
                item.frame = target
            }
        }
        strip.frame.size = NSSize(width: max(contentWidth, clip.bounds.width), height: clip.bounds.height)
        offset = min(offset, maxOffset)
        if animated { scrollToSelected(animated: true) } else { applyOffset(animated: false) }
    }

    private func scrollToSelected(animated: Bool) {
        guard items.indices.contains(selectedIndex) else { return }
        let slot = slotFrame(selectedIndex, width: tabWidth())
        if slot.minX < offset {
            offset = slot.minX
        } else if slot.maxX > offset + clip.bounds.width {
            offset = slot.maxX - clip.bounds.width
        }
        offset = min(max(offset, 0), maxOffset)
        applyOffset(animated: animated)
    }

    private func applyOffset(animated: Bool) {
        let target = NSRect(origin: NSPoint(x: -offset, y: 0), size: strip.frame.size)
        if animated {
            animator.animate(strip, to: target)
        } else if !animator.retarget(strip, to: target) {
            strip.frame = target
        }
        updateFade()
    }

    /// Fades the edges where more tabs are scrolled out of view.
    private func updateFade() {
        let width = clip.bounds.width
        guard maxOffset > 0.5, width > 0 else {
            clip.layer?.mask = nil
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let left: CGFloat = offset > 0.5 ? 20 / width : 0
        let right: CGFloat = offset < maxOffset - 0.5 ? 28 / width : 0
        fade.frame = clip.bounds
        fade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        fade.locations = [0, NSNumber(value: Double(left)), NSNumber(value: Double(1 - right)), 1]
        clip.layer?.mask = fade
        CATransaction.commit()
    }

    // MARK: - Mouse

    /// Empty parts of the bar fall through to the title bar (window drag, double-click to zoom).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit is TabItemView || hit is TabCloseButton ? hit : nil
    }

    override func scrollWheel(with event: NSEvent) {
        guard maxOffset > 0 else { return super.scrollWheel(with: event) }
        var delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas { delta *= 12 }
        offset = min(max(offset - delta, 0), maxOffset)
        animator.cancel(strip)
        applyOffset(animated: false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseExited(with event: NSEvent) {
        guard frozenWidth != nil, drag == nil else { return }
        frozenWidth = nil
        layoutItems(animated: true)
    }

    fileprivate func itemMouseDown(_ item: TabItemView, with event: NSEvent) {
        if let previous = drag?.item { itemMouseUp(previous) } // a drag that never got its mouse-up
        guard let index = items.firstIndex(of: item) else { return }
        if index != selectedIndex { onSelect?(index) }
        let x = strip.convert(event.locationInWindow, from: nil).x
        drag = (item, x - item.frame.minX, x, false)
    }

    fileprivate func itemMouseDragged(_ item: TabItemView, with event: NSEvent) {
        guard var state = drag, state.item === item, items.count > 1 else { return }
        let x = strip.convert(event.locationInWindow, from: nil).x
        if !state.moved {
            guard abs(x - state.startX) > 4 else { return }
            state.moved = true
            animator.cancel(item)
            item.layer?.zPosition = 1
        }
        drag = state

        let width = item.frame.width
        let left = min(max(x - state.grab, 0), max(contentWidth - width, 0))
        item.setFrameOrigin(NSPoint(x: left, y: item.frame.minY))

        // Keep the dragged tab in view when the bar scrolls.
        if left < offset {
            offset = left
            applyOffset(animated: false)
        } else if left + width > offset + clip.bounds.width {
            offset = min(left + width - clip.bounds.width, maxOffset)
            applyOffset(animated: false)
        }

        guard let from = items.firstIndex(of: item) else { return }
        let to = min(max(Int((left + width / 2) / (width + Self.gap)), 0), items.count - 1)
        guard to != from else { return }
        let selected = items[selectedIndex]
        items.insert(items.remove(at: from), at: to)
        selectedIndex = items.firstIndex(of: selected) ?? selectedIndex
        onMove?(from, to)
        layoutItems(animated: true)
    }

    fileprivate func itemMouseUp(_ item: TabItemView) {
        guard let state = drag, state.item === item else { return }
        drag = nil
        guard state.moved, let index = items.firstIndex(of: item) else { return }
        animator.animate(item, to: slotFrame(index, width: tabWidth())) {
            item.layer?.zPosition = 0
        }
    }

    fileprivate func pressed(_ item: TabItemView) {
        if let index = items.firstIndex(of: item), index != selectedIndex { onSelect?(index) }
    }

    fileprivate func close(_ item: TabItemView) {
        guard drag == nil, let index = items.firstIndex(of: item) else { return }
        onClose?(index)
    }
}

// MARK: - Tab

private final class TabItemView: NSView {
    weak var bar: TabBar?
    var title = "" { didSet { needsDisplay = true; updateAccessibility() } }
    var isSelected = false { didSet { refresh() } }
    var isClosing = false
    var progress: CGFloat? { didSet { if progress != oldValue { needsDisplay = true } } }
    private var hovering = false { didSet { refresh() } }
    private let closeButton = TabCloseButton()

    init(bar: TabBar) {
        self.bar = bar
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        closeButton.onClick = { [weak self] in
            guard let self else { return }
            self.bar?.close(self)
        }
        addSubview(closeButton)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isClosing ? nil : super.hitTest(point)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let size: CGFloat = 20
        closeButton.frame = NSRect(x: bounds.width - size - 5, y: (bounds.height - size) / 2, width: size, height: size)
        closeButton.isHidden = !showsClose
    }

    private var showsClose: Bool {
        (isSelected || hovering) && bounds.width >= 52
    }

    private func refresh() {
        closeButton.isHidden = !showsClose
        needsDisplay = true
        updateAccessibility()
    }

    private func updateAccessibility() {
        setAccessibilityLabel(title)
        setAccessibilityValue(isSelected)
        closeButton.setAccessibilityLabel("Close \(title)")
    }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width, h = bounds.height
        guard w > 1 else { return }
        let r = min(8, w / 2)

        if isSelected {
            // Outline with a rounded top, open at the bottom so it joins the page.
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 0.5, y: h))
            path.line(to: NSPoint(x: 0.5, y: r + 0.5))
            path.appendArc(from: NSPoint(x: 0.5, y: 0.5), to: NSPoint(x: r + 0.5, y: 0.5), radius: r)
            path.line(to: NSPoint(x: w - r - 0.5, y: 0.5))
            path.appendArc(from: NSPoint(x: w - 0.5, y: 0.5), to: NSPoint(x: w - 0.5, y: r + 0.5), radius: r)
            path.line(to: NSPoint(x: w - 0.5, y: h))
            Theme.background.setFill()
            path.fill() // also covers the bar's baseline under this tab
            Theme.tabOutline.setStroke()
            path.lineWidth = 1
            path.stroke()

            if let progress, progress > 0 {
                let track = NSRect(x: r, y: 0, width: w - 2 * r, height: 1)
                let fill = NSRect(x: track.minX, y: 0, width: track.width * min(progress, 1), height: 1)
                NSGradient(starting: Theme.progress.withAlphaComponent(0), ending: Theme.progress)?
                    .draw(in: fill, angle: 0)
            }
        } else if hovering {
            let rect = NSRect(x: 0, y: 0, width: w, height: h - 1) // keep the baseline visible
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0, dy: 0), xRadius: r, yRadius: r)
            Theme.tabHover.setFill()
            path.fill()
            NSRect(x: 0, y: h - 1 - r, width: w, height: r).fill() // square bottom corners
        }

        let color = isSelected ? Theme.foreground : (hovering ? Theme.tabHoverText : Theme.muted)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Theme.sans(12.5, weight: .medium),
            .foregroundColor: color,
            .paragraphStyle: style,
        ]
        let text = NSAttributedString(string: title, attributes: attributes)
        let lineHeight = ceil(text.size().height)
        let right: CGFloat = showsClose ? 28 : 12
        let rect = NSRect(x: 12, y: floor((h - lineHeight) / 2) + 0.5, width: max(w - 12 - right, 0), height: lineHeight)
        text.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func viewDidHide() { hovering = false }

    func syncHover() {
        guard let window else { return }
        hovering = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    override func accessibilityPerformPress() -> Bool {
        bar?.pressed(self)
        return true
    }

    override func mouseDown(with event: NSEvent) { bar?.itemMouseDown(self, with: event) }
    override func mouseDragged(with event: NSEvent) { bar?.itemMouseDragged(self, with: event) }
    override func mouseUp(with event: NSEvent) { bar?.itemMouseUp(self) }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2, bounds.contains(convert(event.locationInWindow, from: nil)) else {
            return super.otherMouseUp(with: event)
        }
        bar?.close(self)
    }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber != 2 { super.otherMouseDown(with: event) }
    }
}

/// The small × on a tab. The hit area is larger than the drawn square.
private final class TabCloseButton: NSView {
    var onClick: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSRect(x: (bounds.width - 16) / 2, y: (bounds.height - 16) / 2, width: 16, height: 16)
        if hovering {
            (pressed ? Theme.border : Theme.tabCloseHover).setFill()
            NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        }
        let path = NSBezierPath()
        let inset: CGFloat = 4.75
        path.move(to: NSPoint(x: box.minX + inset, y: box.minY + inset))
        path.line(to: NSPoint(x: box.maxX - inset, y: box.maxY - inset))
        path.move(to: NSPoint(x: box.maxX - inset, y: box.minY + inset))
        path.line(to: NSPoint(x: box.minX + inset, y: box.maxY - inset))
        path.lineWidth = 1.3
        path.lineCapStyle = .round
        (hovering ? Theme.foreground : Theme.muted).setStroke()
        path.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func viewDidHide() { hovering = false; pressed = false }

    override func mouseDown(with event: NSEvent) { pressed = true }

    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Animates view frames and opacity with an ease-out curve. Frames are set directly
/// on every tick, so custom-drawn views redraw at their real size instead of stretching.
private final class FrameAnimator {
    private struct Animation {
        let view: NSView
        var from: NSRect
        var to: NSRect
        let fromAlpha: CGFloat
        let toAlpha: CGFloat
        let start: CFTimeInterval
        let duration: CFTimeInterval
        let completion: (() -> Void)?
    }

    private var running: [ObjectIdentifier: Animation] = [:]
    private var timer: Timer?

    deinit { timer?.invalidate() }

    func animate(_ view: NSView, to frame: NSRect, alpha: CGFloat? = nil,
                 duration: CFTimeInterval = 0.2, completion: (() -> Void)? = nil) {
        let previous = running.removeValue(forKey: ObjectIdentifier(view))
        if Theme.reduceMotion {
            view.frame = frame
            if let alpha { view.alphaValue = alpha }
            previous?.completion?()
            completion?()
            return
        }
        running[ObjectIdentifier(view)] = Animation(
            view: view, from: view.frame, to: frame,
            fromAlpha: view.alphaValue, toAlpha: alpha ?? view.alphaValue,
            start: CACurrentMediaTime(), duration: duration,
            completion: completion ?? previous?.completion)
        startTimer()
    }

    /// Points a running animation at a new end frame. Returns false if none is running.
    func retarget(_ view: NSView, to frame: NSRect) -> Bool {
        guard var animation = running[ObjectIdentifier(view)] else { return false }
        animation.to = frame
        running[ObjectIdentifier(view)] = animation
        return true
    }

    func cancel(_ view: NSView) {
        running.removeValue(forKey: ObjectIdentifier(view))
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let now = CACurrentMediaTime()
        var finished: [Animation] = []
        for (key, animation) in running {
            let t = min(max((now - animation.start) / animation.duration, 0), 1)
            let e = CGFloat(1 - pow(1 - t, 3)) // ease-out cubic
            let a = animation.from, b = animation.to
            animation.view.frame = NSRect(x: a.minX + (b.minX - a.minX) * e,
                                          y: a.minY + (b.minY - a.minY) * e,
                                          width: a.width + (b.width - a.width) * e,
                                          height: a.height + (b.height - a.height) * e)
            animation.view.alphaValue = animation.fromAlpha + (animation.toAlpha - animation.fromAlpha) * e
            if t >= 1 {
                running.removeValue(forKey: key)
                finished.append(animation)
            }
        }
        if running.isEmpty {
            timer?.invalidate()
            timer = nil
        }
        finished.forEach { $0.completion?() }
    }
}
