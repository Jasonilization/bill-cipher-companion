import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController!
    private var characterWindowController: CharacterWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        characterWindowController = CharacterWindowController()
        statusItemController = StatusItemController(appDelegate: self)
        characterWindowController.show()
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}
