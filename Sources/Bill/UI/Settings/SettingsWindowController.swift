import AppKit
import SwiftUI

/// A normal titled window (unlike the character overlay/chat popup) —
/// opening Settings is expected to behave like any other Mac app's
/// preferences: it can take focus normally.
@MainActor
final class SettingsWindowController: NSObject {
    private var window: NSWindow?
    private let preferences: AppPreferences
    private let memoryStore: MemoryStore
    private let onSignOut: () -> Void

    init(preferences: AppPreferences, memoryStore: MemoryStore, onSignOut: @escaping () -> Void) {
        self.preferences = preferences
        self.memoryStore = memoryStore
        self.onSignOut = onSignOut
    }

    func show() {
        if window == nil {
            let view = SettingsView(
                preferences: preferences,
                memoryStore: memoryStore,
                onSignOut: { [weak self] in self?.onSignOut() },
                onResetMemory: { [weak self] in self?.memoryStore.reset() }
            )
            let hosting = NSHostingController(rootView: view)
            let win = NSWindow(contentViewController: hosting)
            win.title = "Bill"
            win.styleMask = [.titled, .closable]
            win.isReleasedWhenClosed = false
            window = win
        }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
