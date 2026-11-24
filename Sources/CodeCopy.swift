import AppKit
import WebKit

/// Copy buttons on code blocks. The page runs no scripts, so the click is handled
/// by the app's script world and the text goes to the pasteboard natively.
enum CodeCopy {
    static let messageName = "copy"

    static func install(in controller: WKUserContentController, world: WKContentWorld) {
        controller.add(MessageHandler(), contentWorld: world, name: messageName)
        controller.addUserScript(WKUserScript(
            source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
    }

    private static let script = """
    (function () {
      document.addEventListener('click', function (event) {
        var button = event.target.closest && event.target.closest('.code-block > button.copy');
        if (!button) return;
        event.preventDefault();
        var code = button.parentElement.querySelector('pre > code');
        if (!code) return;
        window.webkit.messageHandlers.\(messageName).postMessage(code.textContent);
        button.classList.add('copied');
        clearTimeout(button.nxmdTimer);
        button.nxmdTimer = setTimeout(function () { button.classList.remove('copied'); }, 1400);
      });
    })();
    """

    private final class MessageHandler: NSObject, WKScriptMessageHandler {
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let text = message.body as? String else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }
}
