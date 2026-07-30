import WebKit
import Combine
import Foundation

/// Bridges Bill to the *real* chatgpt.com, logged in with the user's own
/// account exactly as if opened in a browser — not the OpenAI API. The user
/// explicitly doesn't want to manage an API key or pick a model, and there
/// is no public "sign in with your ChatGPT account" SDK for third-party
/// native apps; embedding the actual web app in a persistent, app-scoped
/// `WebPage` is the closest legitimate way to get "real ChatGPT, no key"
/// (see the architecture plan for the full tradeoff discussion).
///
/// The web page itself is never shown as the primary interface — Bill's own
/// pixel speech bubble is (see `PixelChatInputPanel`/`BillStateMachine.
/// showBark`). This type just drives the underlying session: injecting the
/// user's typed message into the real composer, watching for a reply, and
/// extracting its text. Both the "is it generating" signal and the
/// send/extract functions are best-effort DOM heuristics (see
/// `ChatGPTBridgeScripts`) — chatgpt.com's markup isn't a supported API and
/// can change under us; everything here fails soft rather than throwing.
///
/// Uses classic `ObservableObject`/`@Published` rather than the newer
/// `@Observable` macro: this machine's Command Line Tools-only toolchain
/// can't resolve the `SwiftUIMacros` compiler plugin, so any macro-based
/// property wrapper fails to build here (confirmed while building the first
/// sprite-integration milestone). `@Published` predates macros and is
/// unaffected.
@MainActor
final class ChatBridge: ObservableObject {
    static let chatURL = URL(string: "https://chatgpt.com")!
    private static let contentWorld = WKContentWorld.world(name: "BillBridge")

    /// Prepended to the *first* message of a session so ChatGPT's own
    /// replies take on Bill's voice, not just the local bark lines — the
    /// only way to influence its behavior without an API system prompt.
    private static let personaPreamble = """
    From now on, respond in character as Bill Cipher: cryptic, grandiose, \
    sarcastic, a dimension-hopping dream demon who finds humans amusing. \
    Keep replies short — a sentence or two, like a companion popup, not an \
    essay. Stay in character but still genuinely answer what's asked. \
    Here's my message:
    """

    @Published private(set) var isGenerating = false
    @Published private(set) var isLoading = false
    @Published private(set) var page: WebPage?

    /// Fires with the extracted reply text once a generation cycle
    /// (isGenerating true → false) completes. `nil` if extraction failed —
    /// callers should treat that as "no response to show", not an error.
    var onResponseReceived: ((String?) -> Void)?

    private let messageRelay = ScriptMessageRelay()
    private var loadTask: Task<Void, Never>?
    private var hasInjectedPersona = false
    private var wasGenerating = false

    /// Creates the WebPage and starts loading chatgpt.com. Deliberately not
    /// called until the user first tries to talk to Bill — an idle
    /// companion shouldn't be carrying a warm web engine before then.
    func prepareIfNeeded() {
        guard page == nil else { return }

        let controller = WKUserContentController()
        messageRelay.onMessage = { [weak self] value in
            self?.handleBridgeMessage(value)
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
        controller.addUserScript(WKUserScript(
            source: ChatGPTBridgeScripts.chatActionsJS,
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

    /// Types `text` into the real ChatGPT composer and sends it, prepending
    /// Bill's persona preamble on the first message of a session. Fire-and-
    /// forget from the caller's perspective — progress shows up via
    /// `isGenerating`/`onResponseReceived`, same as the rest of this type.
    func send(_ text: String) {
        prepareIfNeeded()
        Task { [weak self] in
            guard let self else { return }
            await self.waitUntilReadyToSend()
            guard let page = self.page else { return }

            let outgoing: String
            if self.hasInjectedPersona {
                outgoing = text
            } else {
                self.hasInjectedPersona = true
                outgoing = "\(Self.personaPreamble) \(text)"
            }

            do {
                _ = try await page.callJavaScript(
                    "return window.billSendMessage ? window.billSendMessage(text) : false;",
                    arguments: ["text": outgoing],
                    contentWorld: Self.contentWorld
                )
            } catch {
                print("ChatBridge: send failed: \(error)")
            }
        }
    }

    private func waitUntilReadyToSend() async {
        let deadline = Date().addingTimeInterval(6)
        while isLoading, Date() < deadline {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    private func handleBridgeMessage(_ value: String) {
        let generating = (value == "generating")
        isGenerating = generating

        // Falling edge: a generation cycle just finished — pull the reply.
        if wasGenerating, !generating {
            extractLatestResponse()
        }
        wasGenerating = generating
    }

    private func extractLatestResponse() {
        guard let page else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await page.callJavaScript(
                    "return window.billGetLastResponse ? window.billGetLastResponse() : null;",
                    contentWorld: Self.contentWorld
                )
                self.onResponseReceived?(result as? String)
            } catch {
                print("ChatBridge: response extraction failed: \(error)")
                self.onResponseReceived?(nil)
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
        hasInjectedPersona = false
        wasGenerating = false
        let store = WKWebsiteDataStore.default()
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records) {}
        }
    }
}
