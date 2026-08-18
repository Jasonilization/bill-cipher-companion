import AppKit
import SwiftUI

/// A normal titled debug window showing `CharacterWindowController.
/// dialogueRefreshLog` — like `SettingsWindowController`, this is a real
/// window (not the character overlay/chat popup styling), since it's a
/// developer-facing tool rather than part of Bill's in-character UI.
@MainActor
final class DialogueRefreshLogWindowController: NSObject {
    private var window: NSWindow?
    private let characterWindowController: CharacterWindowController

    init(characterWindowController: CharacterWindowController) {
        self.characterWindowController = characterWindowController
    }

    /// The view observes the store directly now, so it stays live while the
    /// window is open — no rebuild-on-show workaround needed.
    func show() {
        let view = DialogueRefreshLogView(store: characterWindowController.dialogueRefreshStore)
        let hosting = NSHostingController(rootView: view)
        if let window {
            window.contentViewController = hosting
        } else {
            let win = NSWindow(contentViewController: hosting)
            win.title = "Bill — Dialogue Refresh Log"
            win.styleMask = [NSWindow.StyleMask.titled, .closable, .resizable]
            win.isReleasedWhenClosed = false
            window = win
        }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
