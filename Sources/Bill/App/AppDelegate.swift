import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let characterEngine = CharacterEngine()
    let chatBridge = ChatBridge()
    private let systemMonitor = SystemMonitor()
    private let weatherMonitor = WeatherMonitor()
    private let preferences = AppPreferences()
    private let memoryStore = MemoryStore()
    let studyMode = StudyMode()
    private var habitNagger: HabitNagger?
    var awarenessMonitor: AwarenessMonitor!
    private var reactionRouter: ReactionRouter!
    private var statusItemController: StatusItemController!
    private var characterWindowController: CharacterWindowController!
    private var chatPanelController: ChatPanelController!
    private var settingsWindowController: SettingsWindowController!
    private var personalizationSetupController: PersonalizationSetupController!
    private var dialogueRefreshLogWindowController: DialogueRefreshLogWindowController!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Decode the dialogue library before anything can ask it for a line.
        // A few milliseconds for ~750 short strings, and every bark path
        // depends on it, so it happens first rather than lazily mid-reaction.
        DialogueLibrary.shared.warmUp()
        // Fold in whatever the last ChatGPT refresh produced. This is the step
        // that makes generated dialogue actually reachable: previously the
        // generated lines were only ever read from one branch of the wander
        // beat, at roughly 3.75% of beats and only when roaming was enabled,
        // which is why new dialogue read as "not implemented".
        DialogueLibrary.shared.setGenerated(memoryStore.generatedPools)
        // Same for the personalized half — the per-app, per-time-of-day
        // lines the setup flow generated on this machine (see
        // `PersonalizationEngine`). Absent on a fresh install, present from
        // the first relaunch after setup.
        PersonalizedDialogueStore.shared.publishToDialogueLibrary()

        characterWindowController = CharacterWindowController(characterEngine: characterEngine, preferences: preferences, chatBridge: chatBridge, memoryStore: memoryStore)
        chatPanelController = ChatPanelController(chatBridge: chatBridge)
        characterWindowController.warmUpChatEngine = { [weak self] in self?.chatPanelController.warmUpIfNeeded() }
        characterWindowController.beginAwaitingChatResponse = { [weak self] in self?.chatPanelController.beginAwaitingResponse() }
        characterWindowController.openFullChat = { [weak self] in self?.chatPanelController.show() }
        characterWindowController.setChatEngineMounted = { [weak self] mounted in
            self?.chatPanelController.keepMounted = mounted
        }
        characterWindowController.endAwaitingChatResponse = { [weak self] in self?.chatPanelController.endAwaitingResponse() }
        // Weather rides along with the first chat message of each session,
        // the same way the recent-activity blurb does.
        characterWindowController.weatherBlurbProvider = { [weak self] in
            self?.weatherMonitor.latest?.contextBlurb
        }
        personalizationSetupController = PersonalizationSetupController(
            model: characterWindowController.personalizationEngine.model
        )
        personalizationSetupController.onStart = { [weak self] in
            self?.characterWindowController.runPersonalizationSetup()
        }
        personalizationSetupController.onOpenLogin = { [weak self] in
            self?.showFullChat()
        }
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

        // Live "proper app to edit more things" wiring: each Settings
        // control below writes straight into the running app.
        preferences.$ambientAnimationSpacing
            .removeDuplicates()
            .sink { [weak self] spacing in self?.characterEngine.ambientAnimationSpacingMultiplier = spacing }
            .store(in: &cancellables)
        preferences.$bubbleAccentColorHex
            .removeDuplicates()
            .sink { [weak self] hex in
                BillPalette.bubbleAccent = BillPalette.color(fromHex: hex)
                self?.characterWindowController.relayoutChatBubble()
            }
            .store(in: &cancellables)
        preferences.$bubbleTextScale
            .removeDuplicates()
            .sink { [weak self] scale in
                BarkBubble.textScaleMultiplier = CGFloat(scale)
                self?.characterWindowController.relayoutChatBubble()
            }
            .store(in: &cancellables)
        preferences.$chatBubbleMaxWidth
            .removeDuplicates()
            .sink { [weak self] width in
                PixelChatBubble.maxWidth = CGFloat(width)
                self?.characterWindowController.relayoutChatBubble()
            }
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
        awarenessMonitor = AwarenessMonitor(preferences: preferences)
        awarenessMonitor.onInsight = { [weak self] insight in
            self?.reactionRouter.reportInsight(insight)
        }
        awarenessMonitor.start()
        // `BILL_AWARENESS_DIAGNOSTIC=1` runs the same report the debug menu
        // shows, shortly after launch, so the pipeline can be verified from a
        // terminal without clicking through the menu bar.
        // `BILL_REFRESH_ON_LAUNCH=1` forces a dialogue refresh shortly after
        // launch. This is the only end-to-end exercise of the whole ChatGPT
        // bridge — WebView warm-up, page load, script injection, send, response
        // extraction and parsing — so it is how that path gets tested without
        // clicking through the menu bar.
        if ProcessInfo.processInfo.environment["BILL_REFRESH_ON_LAUNCH"] == "1" {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                self?.characterWindowController.refreshDialogueNow()
            }
        }
        if ProcessInfo.processInfo.environment["BILL_CHAT_DIAGNOSTIC"] == "1" {
            Task { @MainActor [weak self] in
                self?.characterWindowController.warmUpChatEngine?()
                self?.chatPanelController.keepMounted = true
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                let report = await self?.chatBridge.diagnose() ?? "nil"
                print("=== chat bridge diagnostic ===")
                print(report)
                print("=== end chat diagnostic ===")
                self?.chatPanelController.keepMounted = false
            }
        }
        if ProcessInfo.processInfo.environment["BILL_AWARENESS_DIAGNOSTIC"] == "1" {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                guard let report = await self?.awarenessMonitor.diagnose() else { return }
                print("=== screen awareness diagnostic ===")
                print(report)
                print("=== end diagnostic ===")
            }
        }
        // Start/stop the periodic sampler when the toggle changes, rather than
        // only at launch.
        preferences.$isWindowAwarenessEnabled
            .sink { [weak self] _ in
                Task { @MainActor in self?.awarenessMonitor.refresh() }
            }
            .store(in: &cancellables)

        let nagger = HabitNagger(memoryStore: memoryStore)
        nagger.onNag = { [weak self] key in self?.reactionRouter.nag(key) }
        reactionRouter.habitNagger = nagger
        habitNagger = nagger
        studyMode.onStateChanged = { [weak self] in
            self?.statusItemController.refreshStudyModeItem()
        }
        systemMonitor.onEvent = { [weak self] event in
            self?.reactionRouter.handle(event)
        }
        systemMonitor.start()

        // Weather: fires only on a real condition change (rain starting,
        // skies clearing) and rides into chat context via
        // `weatherBlurbProvider` above. Keyless services (Open-Meteo +
        // geojs) — verified live during development.
        weatherMonitor.onConditionChanged = { [weak self] snapshot in
            self?.reactionRouter.handle(.weatherChanged(snapshot))
        }
        weatherMonitor.start()

        // First-run offer of the personalization setup — the flow that
        // writes Bill's per-app commentary via ChatGPT on this machine.
        // Offered once, automatically; re-runnable any time from the menu
        // bar.
        if !PersonalizedDialogueStore.shared.isPersonalized,
           UserDefaults.standard.object(forKey: Self.didOfferPersonalizationKey) == nil {
            UserDefaults.standard.set(true, forKey: Self.didOfferPersonalizationKey)
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                self?.personalizationSetupController?.present()
            }
        }
    }

    private static let didOfferPersonalizationKey = "bill.didOfferPersonalizationSetup"

    /// Presents the setup window (menu bar → "Personalize Bill's
    /// Commentary…"). If a run is already in flight the window simply
    /// shows its live progress.
    func openPersonalizationSetup() {
        personalizationSetupController?.present()
    }

    /// Nothing used to run at shutdown at all — no monitors stopped, no state
    /// flushed. Now that persistence is coalesced (see `MemoryStore.save()`),
    /// a clean flush here is load-bearing rather than merely tidy.
    func applicationWillTerminate(_ notification: Notification) {
        systemMonitor.stop()
        characterEngine.stop()
        awarenessMonitor?.stop()
        characterEngine.coverage.flushNow()
        memoryStore.flushNow()
    }

    func showFullChat() {
        chatPanelController.show()
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}
