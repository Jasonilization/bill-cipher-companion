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
    /// Set by `AppDelegate` — forces a weather pull + loud report (the
    /// Settings "Test weather now" button).
    var onTestWeather: (() -> Void)?
    /// Set by `AppDelegate` — opens the quotes manager window.
    var onOpenQuotesManager: (() -> Void)?

    /// The window's frame in screen coordinates, or `nil` while closed —
    /// Bill's drop-by Easter egg (drag him onto Settings, he reacts)
    /// needs it.
    func contentFrame() -> NSRect? {
        window?.frame
    }

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
                onResetMemory: { [weak self] in self?.memoryStore.reset() },
                onTestWeather: { [weak self] in self?.onTestWeather?() },
                onOpenQuotesManager: { [weak self] in self?.onOpenQuotesManager?() }
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
