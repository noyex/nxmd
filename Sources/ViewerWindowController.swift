import AppKit
import WebKit

final class ViewerWindowController: NSWindowController, WKNavigationDelegate, WKUIDelegate {
    private static let frameName = "NxmdViewer"
    private static let zoomKey = "pageZoom"
    private static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdx"]

    private let webView: WKWebView
    private let findBar = FindBar()
    private var pageLoaded = false
    private var loadedBaseURL: URL?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 940),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .textBackgroundColor
        window.minSize = NSSize(width: 420, height: 320)
        window.isRestorable = false

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(LocalFileSchemeHandler(), forURLScheme: LocalFileSchemeHandler.scheme)
        // Markdown can contain raw HTML; never run scripts from it.
        config.defaultWebpagePreferences.allowsContentJavaScript = false

        webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = true
        let zoom = UserDefaults.standard.double(forKey: Self.zoomKey)
        webView.pageZoom = zoom > 0 ? zoom : 1

        super.init(window: window)

        webView.navigationDelegate = self
        webView.uiDelegate = self

        let container = NSView()
        webView.translatesAutoresizingMaskIntoConstraints = false
        findBar.translatesAutoresizingMaskIntoConstraints = false
        findBar.webView = webView
        findBar.isHidden = true
        container.addSubview(webView)
        container.addSubview(findBar)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            findBar.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            findBar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
        ])
        window.contentView = container

        placeWindow(window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var document: AnyObject? {
        didSet { render() }
    }

    private var markdownDocument: MarkdownDocument? { document as? MarkdownDocument }

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

    // MARK: - Rendering

    func render() {
        guard let doc = markdownDocument else { return }
        let body = Renderer.shared.body(for: doc.text)
        let baseURL = doc.fileURL.map {
            LocalFileSchemeHandler.baseURL(forDirectory: $0.deletingLastPathComponent())
        }

        if pageLoaded, baseURL == loadedBaseURL {
            // Swap the content in place: keeps scroll position, no flash.
            webView.callAsyncJavaScript(
                "document.getElementById('content').innerHTML = html",
                arguments: ["html": body], in: nil, in: .page
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
        let file = LocalFileSchemeHandler.fileURL(from: url)
        if Self.markdownExtensions.contains(file.pathExtension.lowercased()) {
            NSDocumentController.shared.openDocument(withContentsOf: file, display: true) { _, _, _ in }
        } else {
            NSWorkspace.shared.open(file)
        }
    }

    // MARK: - Find

    @objc func showFindBar(_ sender: Any?) {
        findBar.show()
    }

    @objc func findNext(_ sender: Any?) {
        findBar.isHidden ? findBar.show() : findBar.find(backwards: false)
    }

    @objc func findPrevious(_ sender: Any?) {
        findBar.isHidden ? findBar.show() : findBar.find(backwards: true)
    }

    // MARK: - Zoom

    @objc func zoomIn(_ sender: Any?) { setZoom(webView.pageZoom * 1.1) }
    @objc func zoomOut(_ sender: Any?) { setZoom(webView.pageZoom / 1.1) }
    @objc func resetZoom(_ sender: Any?) { setZoom(1) }

    private func setZoom(_ value: Double) {
        let zoom = min(max(value, 0.5), 3)
        webView.pageZoom = zoom
        UserDefaults.standard.set(zoom, forKey: Self.zoomKey)
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

private extension URL {
    var withoutFragment: URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.url ?? self
    }
}
