import WebKit
import Combine
import Foundation

/// Bridges Bill's chat panel to the *real* chatgpt.com, logged in with the
/// user's own account exactly as if opened in a browser — not the OpenAI
/// API. The user explicitly doesn't want to manage an API key or pick a
/// model, and there is no public "sign in with your ChatGPT account" SDK for
/// third-party native apps; embedding the actual web app in a persistent,
/// app-scoped `WebPage` is the closest legitimate way to get "real ChatGPT,
/// no key" (see the architecture plan for the full tradeoff discussion).
///
/// `isGenerating` is a best-effort DOM-activity heuristic (see
/// `ChatGPTBridgeScripts`), used only to drive Bill's thinking/talking
/// animation — the chat itself works whether or not that signal ever fires.
///
/// Uses classic `ObservableObject`/`@Published` rather than the newer
/// `@Observable` macro: this machine's Command Line Tools-only toolchain
/// can't resolve the `SwiftUIMacros` compiler plugin, so any macro-based
/// property wrapper fails to build here (confirmed while building this
/// milestone — see commit history). `@Published` predates macros and is
/// unaffected.
@MainActor
final class ChatBridge: ObservableObject {
    static let chatURL = URL(string: "https://chatgpt.com")!
    private static let contentWorld = WKContentWorld.world(name: "BillBridge")

    @Published private(set) var isGenerating = false
    @Published private(set) var isLoading = false
    @Published private(set) var page: WebPage?

    private let messageRelay = ScriptMessageRelay()
    private var loadTask: Task<Void, Never>?

    /// Creates the WebPage and starts loading chatgpt.com. Deliberately not
    /// called until the chat panel is first summoned — an idle companion
    /// shouldn't be carrying a warm web engine before the user ever asks to
    /// chat.
    func prepareIfNeeded() {
        guard page == nil else { return }

        let controller = WKUserContentController()
        messageRelay.onMessage = { [weak self] value in
            self?.isGenerating = (value == "generating")
        }
        controller.add(messageRelay, contentWorld: Self.contentWorld, name: "billBridge")

        let cssJS = """
        (function() {
            const style = document.createElement('style');
            style.textContent = `\(ChatGPTBridgeScripts.hideChromeCSS)`;
            document.documentElement.appendChild(style);
        })();
        """
        controller.addUserScript(WKUserScript(source: cssJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(
            source: ChatGPTBridgeScripts.observeGeneratingStateJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: Self.contentWorld
        ))

        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .default()
        configuration.userContentController = controller

        let newPage = WebPage(configuration: configuration)
        page = newPage
        isLoading = true

        loadTask?.cancel()
        loadTask = Task { [weak self] in
            do {
                for try await event in newPage.load(Self.chatURL) {
                    if event == .committed || event == .finished {
                        self?.isLoading = false
                    }
                }
            } catch {
                print("ChatBridge: failed to load chatgpt.com: \(error)")
                self?.isLoading = false
            }
        }
    }

    /// Signs out of ChatGPT by clearing all persisted site data for this
    /// app. Next `prepareIfNeeded()` will show the normal chatgpt.com login.
    func signOut() {
        loadTask?.cancel()
        page = nil
        isLoading = false
        isGenerating = false
        let store = WKWebsiteDataStore.default()
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records) {}
        }
    }
}
