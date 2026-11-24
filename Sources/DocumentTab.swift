import AppKit
import WebKit

/// One open file in a window: its web view plus everything that belongs to it alone
/// (rendering, scroll position, source view, outline and find text).
final class DocumentTab: NSObject, WKNavigationDelegate, WKUIDelegate {
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdx"]
    /// The app's own scripts run in this world; the page's scripts are disabled.
    private static let world = WKContentWorld.world(name: "nxmd")

    let document: MarkdownDocument
    let webView: SmoothWebView
    weak var host: ViewerWindowController?

    private(set) var headings: [Heading] = []
    private(set) var showingSource = false
    /// Reading progress, or nil when the page does not scroll.
    private(set) var progress: CGFloat?
    /// Distance scrolled in the current direction; drives the toolbar auto-hide.
    private(set) var scrollRun: Double = 0
    private(set) var scrollY: Double = 0
    private(set) var scrollMax: Double = 0
    var findText = ""
    var isSearching = false

    private var pageLoaded = false
    private var loadedBaseURL: URL?

    var title: String { document.displayName }

    init(document: MarkdownDocument, zoom: Double) {
        self.document = document

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(LocalFileSchemeHandler(), forURLScheme: LocalFileSchemeHandler.scheme)
        // Markdown can contain raw HTML; never run scripts from it.
        config.defaultWebpagePreferences.allowsContentJavaScript = false

        webView = SmoothWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = true
        webView.pageZoom = zoom

        let proxy = ScrollMessageProxy()
        config.userContentController.add(proxy, contentWorld: Self.world, name: "scroll")
        config.userContentController.addUserScript(WKUserScript(
            source: Self.scrollScript, injectionTime: .atDocumentEnd,
            forMainFrameOnly: true, in: Self.world))

        super.init()

        proxy.owner = self
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
    }

    func teardown() {
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.stopLoading()
    }

    // MARK: - Rendering

    func render() {
        let body: String
        if showingSource {
            body = Renderer.shared.source(document.text)
            headings = []
        } else {
            let rendered = Renderer.shared.render(document.text)
            body = rendered.html
            headings = rendered.headings
        }

        let baseURL = document.fileURL.map {
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
        host?.tabDidRender(self)
    }

    private func loadPage(body: String, baseURL: URL?) {
        pageLoaded = false
        loadedBaseURL = baseURL
        webView.loadHTMLString(Renderer.shared.page(body: body), baseURL: baseURL)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
    }

    func runScript(_ source: String, _ arguments: [String: Any] = [:]) {
        webView.callAsyncJavaScript(source, arguments: arguments, in: nil, in: Self.world) { result in
            if case .failure(let error) = result { NSLog("nxmd script error: \(error)") }
        }
    }

    func toggleSource() {
        showingSource.toggle()
        render()
        runScript("nxmdStopSmooth(); window.scrollTo(0, 0)")
    }

    func jump(toHeading id: String) {
        runScript("nxmdStopSmooth(); document.getElementById(id)?.scrollIntoView({ block: 'start' })", ["id": id])
    }

    // MARK: - Scroll

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
        progress = max > 1 ? CGFloat(y / max) : nil
        let delta = y - scrollY
        scrollY = y
        scrollMax = max
        if delta != 0 {
            // Reset when the direction changes, so slow scrolls add up too.
            scrollRun = (scrollRun >= 0) == (delta >= 0) ? scrollRun + delta : delta
        }
        host?.tabDidScroll(self)
    }

    // MARK: - Find

    func find(backwards: Bool, completion: @escaping (Bool) -> Void) {
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.wraps = true
        config.caseSensitive = false
        webView.find(findText, configuration: config) { completion($0.matchFound) }
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
            // Opens as a new tab in this window (see ViewerWindowController.forNewDocument).
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

/// Breaks the retain cycle between WKUserContentController and the tab.
private final class ScrollMessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: DocumentTab?

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
