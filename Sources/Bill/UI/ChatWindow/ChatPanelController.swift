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
        panel.makeKeyAndOrderFront(nil)
        installOutsideClickMonitor()
    }

    func hide() {
        panel.orderOut(nil)
        removeOutsideClickMonitor()
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
