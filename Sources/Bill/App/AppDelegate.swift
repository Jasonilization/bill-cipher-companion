import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let characterEngine = CharacterEngine()
    private let chatBridge = ChatBridge()
    private let systemMonitor = SystemMonitor()
    private let preferences = AppPreferences()
    private let memoryStore = MemoryStore()
    let studyMode = StudyMode()
    private var reactionRouter: ReactionRouter!
    private var statusItemController: StatusItemController!
    private var characterWindowController: CharacterWindowController!
    private var chatPanelController: ChatPanelController!
    private var settingsWindowController: SettingsWindowController!
    private var dialogueRefreshLogWindowController: DialogueRefreshLogWindowController!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Decode the dialogue library before anything can ask it for a line.
        // A few milliseconds for ~750 short strings, and every bark path
        // depends on it, so it happens first rather than lazily mid-reaction.
        DialogueLibrary.shared.warmUp()

        characterWindowController = CharacterWindowController(characterEngine: characterEngine, preferences: preferences, chatBridge: chatBridge, memoryStore: memoryStore)
        chatPanelController = ChatPanelController(chatBridge: chatBridge)
        characterWindowController.warmUpChatEngine = { [weak self] in self?.chatPanelController.warmUpIfNeeded() }
        characterWindowController.beginAwaitingChatResponse = { [weak self] in self?.chatPanelController.beginAwaitingResponse() }
        characterWindowController.endAwaitingChatResponse = { [weak self] in self?.chatPanelController.endAwaitingResponse() }
        settingsWindowController = SettingsWindowController(
            preferences: preferences,
            memoryStore: memoryStore,
            onSignOut: { [weak self] in self?.chatBridge.signOut() }
        )
        dialogueRefreshLogWindowController = DialogueRefreshLogWindowController(characterWindowController: characterWindowController)
        statusItemController = StatusItemController(
            appDelegate: self,
            characterEngine: characterEngine,
            characterWindowController: characterWindowController,
            chatPanelController: chatPanelController,
            settingsWindowController: settingsWindowController,
            dialogueRefreshLogWindowController: dialogueRefreshLogWindowController
        )
        characterWindowController.show()
        characterEngine.start()

        preferences.$speakingFrequency
            .sink { [weak self] frequency in self?.characterEngine.speakingFrequencyMultiplier = frequency }
            .store(in: &cancellables)

        // Best-effort DOM-activity signal from the real ChatGPT page — see
        // ChatBridge's doc comment. Bill "talks" while it looks like content
        // is streaming in, and settles back down once it quiets.
        chatBridge.$isGenerating
            .removeDuplicates()
            .sink { [weak self] isGenerating in
                guard let self, characterWindowController.isPerformingBackgroundChatWork == false else { return }
                self.characterEngine.request(isGenerating ? .talking : .idle)
            }
            .store(in: &cancellables)

        GlobalHotKey.register { [weak self] in
            self?.characterWindowController.talkToBill()
        }

        reactionRouter = ReactionRouter(characterEngine: characterEngine, preferences: preferences, memoryStore: memoryStore)
        // Lets a reaction physically take Bill to the app it is about, rather
        // than commenting on it from wherever he happened to be standing.
        reactionRouter.goToApp = { [weak self] pid in
            self?.characterWindowController.sendBillToApp(pid: pid) ?? false
        }
        // Study Mode gets first refusal on every app activation, so a blocked
        // app is confronted instead of reacted to.
        reactionRouter.studyModeInterceptor = { [weak self] bundleID, name, pid in
            self?.studyMode.intercept(bundleID: bundleID, name: name, pid: pid) ?? false
        }
        studyMode.goToApp = { [weak self] pid in
            self?.characterWindowController.sendBillToApp(pid: pid) ?? false
        }
        studyMode.announce = { [weak self] keys, states, substitutions in
            self?.reactionRouter.announceStudy(keys: keys, states: states, substitutions: substitutions)
        }
        studyMode.onStateChanged = { [weak self] in
            self?.statusItemController.refreshStudyModeItem()
        }
        systemMonitor.onEvent = { [weak self] event in
            self?.reactionRouter.handle(event)
        }
        systemMonitor.start()
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}
