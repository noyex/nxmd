import Foundation
import JavaScriptCore

/// Converts Markdown to HTML with marked + highlight.js inside JavaScriptCore,
/// so the rendered page itself never needs to run JavaScript.
final class Renderer {
    static let shared = Renderer()

    private let context: JSContext
    private let renderFunction: JSValue?
    let stylesheet: String

    private init() {
        context = JSContext()
        context.exceptionHandler = { _, exception in
            NSLog("nxmd render error: \(exception?.toString() ?? "unknown")")
        }
        for name in ["marked.min", "highlight.min", "render"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "js"),
                  let source = try? String(contentsOf: url, encoding: .utf8) else {
                NSLog("nxmd: missing resource \(name).js")
                continue
            }
            context.evaluateScript(source, withSourceURL: url)
        }
        renderFunction = context.objectForKeyedSubscript("nxmdRender")
        stylesheet = Bundle.main.url(forResource: "style", withExtension: "css")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    func body(for markdown: String) -> String {
        guard let fn = renderFunction, !fn.isUndefined,
              let html = fn.call(withArguments: [markdown])?.toString() else {
            return "<pre>\(markdown.htmlEscaped)</pre>"
        }
        return html
    }

    func page(body: String) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>\(stylesheet)</style>
        </head><body><main id="content">\(body)</main></body></html>
        """
    }
}

extension String {
    var htmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
