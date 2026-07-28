import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let characterEngine = CharacterEngine()
    private let chatBridge = ChatBridge()
    private let systemMonitor = SystemMonitor()
    private let preferences = AppPreferences()
    private let memoryStore = MemoryStore()
    private var reactionRouter: ReactionRouter!
    private var statusItemController: StatusItemController!
    private var characterWindowController: CharacterWindowController!
    private var chatPanelController: ChatPanelController!
    private var settingsWindowController: SettingsWindowController!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        characterWindowController = CharacterWindowController(characterEngine: characterEngine, preferences: preferences)
        chatPanelController = ChatPanelController(chatBridge: chatBridge)
        settingsWindowController = SettingsWindowController(
            preferences: preferences,
            memoryStore: memoryStore,
            onSignOut: { [weak self] in self?.chatBridge.signOut() }
        )
        statusItemController = StatusItemController(
            appDelegate: self,
            characterEngine: characterEngine,
            chatPanelController: chatPanelController,
            settingsWindowController: settingsWindowController
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

        reactionRouter = ReactionRouter(characterEngine: characterEngine, preferences: preferences, memoryStore: memoryStore)
        systemMonitor.onEvent = { [weak self] event in
            self?.reactionRouter.handle(event)
        }
        systemMonitor.start()
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}
