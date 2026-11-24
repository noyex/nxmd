import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves files through a custom scheme, because WKWebView blocks file://
/// subresources for pages loaded from a string.
/// - `nxmd-file://local/<absolute path>`: files next to the document (images, links)
/// - `nxmd-file://app/<path>`: the app's own resources (fonts)
final class LocalFileSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "nxmd-file"

    private var activeTasks = Set<ObjectIdentifier>()

    static func baseURL(forDirectory directory: URL) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "local"
        let path = directory.standardizedFileURL.path
        components.path = path.hasSuffix("/") ? path : path + "/"
        return components.url ?? URL(string: "\(scheme)://local/")!
    }

    /// The file a `nxmd-file://` URL points to, or nil if it is outside the allowed roots.
    static func fileURL(from url: URL) -> URL? {
        if url.host == "app" {
            guard let resources = Bundle.main.resourceURL?.standardizedFileURL else { return nil }
            let file = resources.appendingPathComponent(url.path).standardizedFileURL
            return file.path.hasPrefix(resources.path + "/") ? file : nil
        }
        return URL(fileURLWithPath: url.path)
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let file = Self.fileURL(from: url) else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let id = ObjectIdentifier(task)
        activeTasks.insert(id)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try Data(contentsOf: file) }
            DispatchQueue.main.async {
                guard let self, self.activeTasks.remove(id) != nil else { return }
                switch result {
                case .success(let data):
                    let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType
                        ?? "application/octet-stream"
                    // Fonts are loaded cross-origin (app -> local), so allow it explicitly.
                    let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                                   headerFields: ["Content-Type": mime,
                                                                  "Content-Length": "\(data.count)",
                                                                  "Access-Control-Allow-Origin": "*"])!
                    task.didReceive(response)
                    task.didReceive(data)
                    task.didFinish()
                case .failure(let error):
                    task.didFailWithError(error)
                }
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        activeTasks.remove(ObjectIdentifier(task))
    }
}
