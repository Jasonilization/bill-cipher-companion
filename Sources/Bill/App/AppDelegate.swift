import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let characterEngine = CharacterEngine()
    private let chatBridge = ChatBridge()
    private var statusItemController: StatusItemController!
    private var characterWindowController: CharacterWindowController!
    private var chatPanelController: ChatPanelController!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        characterWindowController = CharacterWindowController(characterEngine: characterEngine)
        chatPanelController = ChatPanelController(chatBridge: chatBridge)
        statusItemController = StatusItemController(
            appDelegate: self,
            characterEngine: characterEngine,
            chatPanelController: chatPanelController
        )
        characterWindowController.show()
        characterEngine.start()

        // Best-effort DOM-activity signal from the real ChatGPT page — see
        // ChatBridge's doc comment. Bill "talks" while it looks like content
        // is streaming in, and settles back down once it quiets.
        chatBridge.$isGenerating
            .removeDuplicates()
            .sink { [weak self] isGenerating in
                self?.characterEngine.request(isGenerating ? .talking : .idle)
            }
            .store(in: &cancellables)

        GlobalHotKey.register { [weak self] in
            self?.chatPanelController.toggle()
        }
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}
