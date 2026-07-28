import WebKit

/// Forwards `WKScriptMessageHandler` callbacks (which WebKit can invoke off
/// the main actor as far as the type system is concerned) into a MainActor
/// closure, so `ChatBridge` never has to deal with isolation directly.
final class ScriptMessageRelay: NSObject, WKScriptMessageHandler {
    var onMessage: (@MainActor (String) -> Void)?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? String else { return }
        let callback = onMessage
        Task { @MainActor in
            callback?(body)
        }
    }
}
