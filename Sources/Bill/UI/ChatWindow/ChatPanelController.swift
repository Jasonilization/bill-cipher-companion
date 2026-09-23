import AppKit
import SwiftUI

/// Owns the *secondary* full-view chat popup — a borderless, non-activating
/// panel (so summoning it never steals focus from whatever app the user was
/// in) showing the raw embedded ChatGPT page. The primary way to talk to
/// Bill is now `PixelChatInputPanel` (right-click Bill, the global hotkey,
/// or "Talk to Bill" in the menu bar) with replies in his own speech
/// bubble; this full view stays reachable from "Open Full Chat View…" in
/// the menu bar for anyone who wants the real ChatGPT UI, and is still
/// dismissed on an outside click.
@MainActor
final class ChatPanelController: NSObject {
    private let panel: NSPanel
    let chatBridge: ChatBridge
    private var outsideClickMonitor: Any?
    /// True only while the user has explicitly opened this panel via `show()`
    /// — distinct from `panel.isVisible`, which would also read `true`
    /// during `beginAwaitingResponse()`'s deliberately-invisible (alpha
    /// near zero) on-screen window, and needs to be told apart from that so
    /// `endAwaitingResponse()` never stomps on a genuinely-open full view.
    private var isExplicitlyShown = false

    init(chatBridge: ChatBridge) {
        self.chatBridge = chatBridge
        let size = NSSize(width: 420, height: 560)
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        configure(size: size)
    }

    private func configure(size: NSSize) {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        let hosting = NSHostingView(
            rootView: ChatPanelView(chatBridge: chatBridge, onClose: { [weak self] in self?.hide() })
        )
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        chatBridge.prepareIfNeeded()
        positionTopRight()
        panel.alphaValue = 1
        panel.ignoresMouseEvents = false
        panel.makeKeyAndOrderFront(nil)
        installOutsideClickMonitor()
        isExplicitlyShown = true
    }

    func hide() {
        panel.orderOut(nil)
        removeOutsideClickMonitor()
        isExplicitlyShown = false
    }

    /// Bill's own speech-bubble chat (`PixelChatBubble`) drives `chatBridge`
    /// directly and never renders `chatBridge.page` in any `WebView` of its
    /// own — a `WebPage` model object does not actually load or run its
    /// injected scripts until some real `WebView` renders it, and this
    /// panel's `WebView(page)` (in `ChatPanelView`) was the only place that
    /// ever happened. That meant talking to Bill through his own bubble
    /// silently produced nothing at all unless the user had also separately
    /// opened "Open Full Chat View…" at least once. A dedicated hidden
    /// `WebView`, created directly, unconditionally crashed macOS's
    /// SwiftUI/WebKit bridging (confirmed via crash log, both created
    /// synchronously and deferred a run loop turn, at two different window
    /// sizes) — so instead of a second, parallel hosting path, this reuses
    /// this panel's own already-working `WebView`.
    ///
    /// Deliberately *not* calling the public `show()`/`hide()` — those also
    /// install/remove a global outside-click monitor, which raced with
    /// `PixelChatBubble`'s own monitor closing it again almost immediately
    /// after `showCompose` (`chatBubble.isVisible` traced `true` right after
    /// `showCompose` returned, yet nothing was on screen a moment later).
    /// `orderFrontRegardless()` alone is enough to give SwiftUI's `WebView`
    /// its first real layout pass without any of that — and unlike
    /// `makeKeyAndOrderFront`, it never contends for key-window status
    /// either. `prepareIfNeeded()` (via `show()` before) already no-ops if a
    /// page exists, so gating this whole method on `chatBridge.page == nil`
    /// makes it naturally idempotent — later calls see a non-nil page and
    /// skip straight through.
    ///
    /// Ordered back out afterward — a brief real visibility window is
    /// enough for `NSHostingView` to actually mount the `WKWebView` (see
    /// `beginAwaitingResponse` for why it needs to come back *briefly*
    /// later too). An earlier version of this left the panel sitting
    /// on-screen at near-zero alpha permanently instead, which turned out
    /// to render as a faint but genuinely visible pale box near the top of
    /// the screen — not worth that cost just to keep one page's background
    /// timers alive for an entire session when the actual need for that is
    /// only ever a few seconds at a time.
    func warmUpIfNeeded() {
        guard !chatBridge.hasEngine else { return }
        chatBridge.prepareIfNeeded()
        positionTopRight()
        panel.alphaValue = 0.01
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        waitForLoadThenHide(deadline: Date().addingTimeInterval(Self.warmUpTimeout))
    }

    /// Stays mounted until the page has genuinely finished loading.
    ///
    /// This used to order the panel back out after a flat **0.3 seconds**,
    /// which is nowhere near enough for chatgpt.com — a cold SPA load takes
    /// seconds. Ordering the window out mid-load lets WebKit throttle and
    /// effectively suspend it, so the page never finished, `billSendMessage`
    /// was never defined, and talking to Bill through his own speech bubble
    /// produced nothing at all. The only way to get a reply was to open the
    /// full chat window, which is exactly the complaint. Now it waits for the
    /// real signal instead of guessing at a duration.
    private func waitForLoadThenHide(deadline: Date) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            // Never yank it away while the user is actually using chat.
            if self.isExplicitlyShown || self.keepMounted { return }
            if self.chatBridge.isLoading, Date() < deadline {
                self.waitForLoadThenHide(deadline: deadline)
                return
            }
            self.panel.orderOut(nil)
        }
    }

    /// Set while Bill's speech-bubble chat is open, so the page stays live for
    /// the whole exchange rather than only while a reply is outstanding.
    var keepMounted = false {
        didSet {
            guard keepMounted != oldValue else { return }
            if keepMounted {
                guard chatBridge.hasEngine, !isExplicitlyShown else { return }
                positionTopRight()
                panel.alphaValue = 0.01
                panel.ignoresMouseEvents = true
                panel.orderFrontRegardless()
            } else if !isExplicitlyShown {
                panel.orderOut(nil)
            }
        }
    }

    /// Generous: a cold first load of chatgpt.com in an app-private data store
    /// genuinely can take this long.
    private static let warmUpTimeout: TimeInterval = 30

    /// Call right after sending a message Bill is now awaiting a reply to.
    /// Briefly brings this panel's `WebView` back to a genuinely on-screen
    /// (not fully occluded/ordered-out) state — invisible in a screen
    /// corner at near-zero alpha, click-through — only for the duration of
    /// that one exchange: WKWebView throttles a fully-hidden page's own
    /// timers/observers, and `ChatGPTBridgeScripts`'s "did a reply arrive"
    /// signal depends entirely on the page's `MutationObserver` continuing
    /// to run. Pairs with `endAwaitingResponse()`, which puts it back to
    /// fully hidden once the exchange resolves, so this doesn't cost real
    /// CPU/GPU for the rest of an idle session the way leaving it
    /// permanently on-screen did.
    func beginAwaitingResponse() {
        guard chatBridge.hasEngine, !isExplicitlyShown else { return }
        positionTopRight()
        panel.alphaValue = 0.01
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
    }

    /// Pairs with `beginAwaitingResponse()` — never fires while the user has
    /// the full view genuinely open (`isExplicitlyShown`), so a reply
    /// resolving mid-browse doesn't yank the window out from under them.
    func endAwaitingResponse() {
        guard !isExplicitlyShown else { return }
        panel.orderOut(nil)
    }

    private func positionTopRight() {
        guard let screen = NSScreen.main else { return }
        let size = panel.frame.size
        let origin = NSPoint(
            x: screen.visibleFrame.maxX - size.width - 20,
            y: screen.visibleFrame.maxY - size.height - 8
        )
        panel.setFrameOrigin(origin)
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.hide()
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }
}
