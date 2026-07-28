import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let characterEngine = CharacterEngine()
    private var statusItemController: StatusItemController!
    private var characterWindowController: CharacterWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        characterWindowController = CharacterWindowController(characterEngine: characterEngine)
        statusItemController = StatusItemController(appDelegate: self, characterEngine: characterEngine)
        characterWindowController.show()
        characterEngine.start()
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}
