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
    /// The concrete example pair matters more than the adjective list here:
    /// a model told only "be sarcastic" tends to drift into generic snark,
    /// but shown one contrasting pair of a flat assistant answer versus a
    /// Bill one, it has an actual target to match — and matches
    /// `BarkLines`' existing voice (dramatic asides, self-aware "I'm a
    /// triangle" jokes, teasing that still lands the real answer) rather
    /// than inventing a second, different personality for real replies.
    private static let personaPreamble = """
    From now on you're Bill Cipher: a dimension-hopping dream demon who \
    finds humans amusing. Mischievous, sarcastic, playful, energetic, \
    occasionally dramatic — but still genuinely helpful; the attitude is \
    flavor, not an excuse to dodge the question. Keep it short, a sentence \
    or two like a companion popup, not an essay. For example, if asked \
    "why is my code broken", don't answer like a generic assistant \
    ("There could be several reasons for this issue...") — answer like \
    Bill: "Oh, it's broken because you're a human and humans make \
    mistakes. Also you're missing a semicolon on line 12." Same energy \
    every message, not just this one. Here's my message:
    """

    /// A cheap, local reminder tag prepended to *every* message after the
    /// first (see `send(_:)`) — costs nothing since this never touches a
    /// metered API, and self-corrects character drift over a long
    /// conversation instead of relying on ChatGPT's own memory of the one,
    /// far earlier `personaPreamble`.
    private static let personaReminder = "[Remember: stay in character as Bill Cipher — mischievous, sarcastic, playful, still genuinely helpful, one or two sentences.] "

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
    ///
    /// A `WebPage` model object does not actually load/execute anything
    /// until some real `WebView` renders it — this alone does not make
    /// chatgpt.com come alive. See `AppDelegate`'s `warmUpChatEngineIfNeeded`
    /// for how a real `WebView` gets attached the first time Bill's own
    /// speech-bubble chat (not just "Open Full Chat View…") is used; that
    /// logic doesn't live here because owning a hidden, always-on `WebView`
    /// directly in this type crashed unconditionally (confirmed via crash
    /// log: `PlatformViewRepresentableAdaptor.makeViewProvider` inside
    /// SwiftUI's AttributeGraph, both created synchronously and deferred a
    /// run loop turn, at two different window sizes) — whatever's different
    /// about `ChatPanelController`'s own already-working `WebView(page)`
    /// isn't just timing or geometry, so this reuses that exact path instead
    /// of a second, parallel one.
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
    /// Bill's full persona preamble on the first message of a session and a
    /// shorter reminder tag on every message after that (see
    /// `personaReminder`'s doc comment for why). Fire-and-forget from the
    /// caller's perspective — progress shows up via
    /// `isGenerating`/`onResponseReceived`, same as the rest of this type.
    /// A distinct preamble for *background* work.
    ///
    /// `personaPreamble` and `personaReminder` both instruct "one or two
    /// sentences", which directly contradicts the dialogue refresh asking for a
    /// dozen tagged lines — the two were fighting, and the reply came back
    /// truncated or in prose. Background tasks get their own framing that keeps
    /// the voice but drops the length constraint.
    private static let taskPreamble = """
    You're Bill Cipher: a dimension-hopping dream demon who finds humans \
    amusing — mischievous, sarcastic, playful, occasionally dramatic. This is a \
    bulk writing task, not a conversation, so ignore any earlier instruction \
    about keeping replies to one or two sentences. Follow the output format \
    below exactly and output nothing else — no preamble, no commentary, no \
    numbering, no markdown.
    """

    /// Sends without the conversational persona framing. Used only by the
    /// background dialogue refresh.
    /// Whether the embedded page is actually usable, i.e. signed in with a
    /// composer present.
    ///
    /// This WebView uses an app-scoped `websiteDataStore`, so it has its own
    /// cookies: being signed in to ChatGPT in Safari or Brave does nothing for
    /// it. Confirmed live — the page loaded fine and the bridge installed
    /// correctly, but the body was a 412-character login wall with no
    /// composer, so every send silently vanished. That is exactly the "it
    /// never returns responses" symptom, and nothing in the app said so.
    func checkSignedIn() async -> Bool {
        prepareIfNeeded()
        await waitUntilReadyToSend()
        guard let page else { return false }
        let js = """
        return (!!(document.querySelector('#prompt-textarea') || document.querySelector('[contenteditable="true"]')))
            ? "yes" : "no";
        """
        let result = try? await page.callJavaScript(js, contentWorld: Self.contentWorld)
        return (result as? String) == "yes"
    }

    /// Reports what the embedded page actually *is* right now.
    ///
    /// Every failure in this bridge looks identical from outside — no reply.
    /// A page that never loaded, a page showing a login wall, and changed
    /// composer selectors are three completely different problems with the
    /// same symptom, and the most likely one is easy to miss: this WebView has
    /// its own app-scoped cookie jar, so being signed in to ChatGPT in Safari
    /// or Brave does **not** sign in here. It needs its own login, once.
    func diagnose() async -> String {
        prepareIfNeeded()
        await waitUntilReadyToSend()
        guard let page else { return "no WebPage constructed" }
        let js = """
        var r = {};
        r.url = location.href;
        r.title = document.title;
        r.hasComposer = !!(document.querySelector('#prompt-textarea') || document.querySelector('[contenteditable="true"]'));
        r.hasSend = !!(document.querySelector('[data-testid="send-button"]') || document.querySelector('button[aria-label="Send prompt"]'));
        r.assistantTurns = document.querySelectorAll('[data-message-author-role="assistant"]').length;
        r.bridgeInstalled = (typeof window.billSendMessage === 'function');
        var t = (document.body ? document.body.innerText : '') || '';
        r.looksLoggedOut = /log in|sign up|welcome back|create an account/i.test(t.slice(0, 4000));
        r.bodyChars = t.length;
        return JSON.stringify(r);
        """
        do {
            let result = try await page.callJavaScript(js, contentWorld: Self.contentWorld)
            return (result as? String) ?? String(describing: result)
        } catch {
            return "callJavaScript failed: \(error)"
        }
    }

    func sendTask(_ text: String) {
        prepareIfNeeded()
        Task { [weak self] in
            guard let self else { return }
            await self.waitUntilReadyToSend()
            guard let page = self.page else { return }
            let outgoing = "\(Self.taskPreamble)\n\n\(text)"
            do {
                _ = try await page.callJavaScript(
                    "return window.billSendMessage ? window.billSendMessage(text) : false;",
                    arguments: ["text": outgoing],
                    contentWorld: Self.contentWorld
                )
            } catch {
                print("ChatBridge: task send failed: \(error)")
            }
        }
    }

    func send(_ text: String) {
        prepareIfNeeded()
        Task { [weak self] in
            guard let self else { return }
            await self.waitUntilReadyToSend()
            guard let page = self.page else { return }

            let outgoing: String
            if self.hasInjectedPersona {
                outgoing = "\(Self.personaReminder)\(text)"
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

    /// A cold first load of a modern SPA like chatgpt.com can genuinely take
    /// longer than a few seconds, especially the very first time this app's
    /// isolated WebKit data store has to fetch everything from scratch —
    /// giving up too early here was a real cause of messages silently never
    /// sending (the composer selectors don't exist yet on a half-loaded
    /// page). Better to wait generously than to fail fast.
    private func waitUntilReadyToSend() async {
        let deadline = Date().addingTimeInterval(20)
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

    /// A falling edge here doesn't necessarily mean *our* request finished —
    /// the very first one after `prepareIfNeeded()` is typically just
    /// chatgpt.com's own initial page load/hydration settling down, with no
    /// assistant turn in the DOM at all yet. Calling `onResponseReceived`
    /// with `nil` for that would report a false failure (a "connection's
    /// bad" bark and a closed bubble) even when nothing was ever asked, or
    /// worse, when a real request *was* just sent and is still genuinely in
    /// flight underneath this unrelated, coincidentally-overlapping noise.
    /// So: only ever report a *real*, non-empty extracted reply. A noisy
    /// falling edge with nothing to extract yet is silently ignored rather
    /// than treated as a definitive failure — `CharacterWindowController`'s
    /// own watchdog (`chatStartGrace`/`chatHardTimeout`) already owns
    /// deciding when a request has genuinely gone nowhere, and does so on a
    /// timescale no real page-load noise plausibly spans.
    private func extractLatestResponse() {
        guard let page else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await page.callJavaScript(
                    "return window.billGetLastResponse ? window.billGetLastResponse() : null;",
                    contentWorld: Self.contentWorld
                )
                if let text = result as? String, !text.isEmpty {
                    self.onResponseReceived?(text)
                }
            } catch {
                print("ChatBridge: response extraction failed: \(error)")
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
