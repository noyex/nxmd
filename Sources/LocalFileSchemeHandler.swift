import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves files next to the Markdown document (relative images, linked files)
/// through a custom scheme, because WKWebView blocks file:// subresources
/// for pages loaded from a string.
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

    static func fileURL(from url: URL) -> URL {
        URL(fileURLWithPath: url.path)
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let id = ObjectIdentifier(task)
        activeTasks.insert(id)
        let file = Self.fileURL(from: url)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try Data(contentsOf: file) }
            DispatchQueue.main.async {
                guard let self, self.activeTasks.remove(id) != nil else { return }
                switch result {
                case .success(let data):
                    let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType
                        ?? "application/octet-stream"
                    task.didReceive(URLResponse(url: url, mimeType: mime,
                                                expectedContentLength: data.count,
                                                textEncodingName: nil))
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
