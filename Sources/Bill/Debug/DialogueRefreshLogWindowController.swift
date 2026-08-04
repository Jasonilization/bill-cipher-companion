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

    /// Rebuilds the content each time rather than reusing a cached view —
    /// the log keeps growing in the background, so a stale snapshot from
    /// whenever the window happened to first open wouldn't be useful.
    func show() {
        let view = DialogueRefreshLogView(entries: characterWindowController.dialogueRefreshLog)
        let hosting = NSHostingController(rootView: view)
        if let window {
            window.contentViewController = hosting
        } else {
            let win = NSWindow(contentViewController: hosting)
            win.title = "Bill — Dialogue Refresh Log"
            win.styleMask = [.titled, .closable, .resizable]
            win.isReleasedWhenClosed = false
            window = win
        }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
