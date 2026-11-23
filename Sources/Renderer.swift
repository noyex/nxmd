import Foundation
import JavaScriptCore

struct Heading {
    let level: Int
    let text: String
    let id: String
}

struct RenderedMarkdown {
    let html: String
    let headings: [Heading]
}

/// Converts Markdown to HTML with marked + highlight.js inside JavaScriptCore,
/// so the rendered page itself never needs to run JavaScript.
final class Renderer {
    static let shared = Renderer()

    private let context: JSContext
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
        stylesheet = Bundle.main.url(forResource: "style", withExtension: "css")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    func render(_ markdown: String) -> RenderedMarkdown {
        guard let result = call("nxmdRender", markdown),
              let html = result.forProperty("html")?.toString() else {
            return RenderedMarkdown(html: "<pre>\(markdown.htmlEscaped)</pre>", headings: [])
        }
        let raw = result.forProperty("headings")?.toArray() as? [[String: Any]] ?? []
        let headings = raw.compactMap { item -> Heading? in
            guard let level = (item["level"] as? NSNumber)?.intValue,
                  let text = item["text"] as? String,
                  let id = item["id"] as? String else { return nil }
            return Heading(level: level, text: text, id: id)
        }
        return RenderedMarkdown(html: html, headings: headings)
    }

    func source(_ markdown: String) -> String {
        call("nxmdSource", markdown)?.toString() ?? "<pre class=\"source\">\(markdown.htmlEscaped)</pre>"
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

    private func call(_ name: String, _ argument: String) -> JSValue? {
        guard let fn = context.objectForKeyedSubscript(name), !fn.isUndefined,
              let value = fn.call(withArguments: [argument]), !value.isUndefined else { return nil }
        return value
    }
}

extension String {
    var htmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
