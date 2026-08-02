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
    }

    /// Fades back to invisible rather than `orderOut` — see `warmUpIfNeeded`'s
    /// doc comment for why this panel needs to stay genuinely on-screen
    /// (just invisible) instead of ordered out once chat has been used.
    func hide() {
        panel.alphaValue = 0.01
        panel.ignoresMouseEvents = true
        removeOutsideClickMonitor()
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
    /// Left genuinely on-screen at `alphaValue` near zero afterward, rather
    /// than `orderOut` — WKWebView throttles a page's timers/observers once
    /// its window is fully ordered out (occluded), and `ChatGPTBridgeScripts`
    /// leans entirely on a `MutationObserver` plus `setTimeout` debouncing to
    /// notice a reply. Ordering this panel out after warm-up meant that
    /// observer could go quiet the moment the panel hid, so a reply might
    /// never get reported back to Bill's own bubble until the user
    /// separately opened "Open Full Chat View…" — which re-showed the panel
    /// and let the *same*, already-arrived DOM content finally get noticed.
    /// Staying on-screen (just invisible and click-through) keeps the page
    /// running normally the whole time instead.
    func warmUpIfNeeded() {
        guard chatBridge.page == nil else { return }
        chatBridge.prepareIfNeeded()
        positionTopRight()
        panel.alphaValue = 0.01
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
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
