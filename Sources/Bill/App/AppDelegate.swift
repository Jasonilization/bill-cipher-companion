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
    private var quotesManagerController: QuotesManagerController!
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
        personalizationSetupController.onPresent = { [weak self] in
            self?.characterWindowController.personalizationEngine.previewDetectedApps()
        }
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
        settingsWindowController.onTestWeather = { [weak self] in
            self?.testWeatherNow()
        }
        settingsWindowController.onOpenQuotesManager = { [weak self] in
            self?.openQuotesManager()
        }
        settingsWindowController.onTestTrigger = { [weak self] keys, animationKey in
            guard let self else { return }
            // Fire the trigger live: request the assigned animation (or
            // the standard pool for that key) and bark the line.
            if let assigned = self.preferences.customAnimationMap[animationKey],
               let state = BillState(rawValue: assigned) {
                self.characterEngine.request(state, force: true)
            } else if let pool = Self.testTriggerAnimations[animationKey],
                      let state = self.characterEngine.coverage.pick(from: pool) {
                self.characterEngine.request(state, force: true)
            }
            if let line = DialogueLibrary.shared.firstLine(keys) {
                self.characterEngine.bark(line, importance: .always)
            }
        }
        characterWindowController.settingsWindowFrameProvider = { [weak self] in
            self?.settingsWindowController?.contentFrame()
        }
        quotesManagerController = QuotesManagerController()
        quotesManagerController.refreshStore = characterWindowController.dialogueRefreshStore
        quotesManagerController.onRefreshAll = { [weak self] in
            self?.characterWindowController.refreshDialogueNow()
        }
        quotesManagerController.onShowLog = { [weak self] in
            self?.dialogueRefreshLogWindowController.show()
        }
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
        // The multicolour prism beat as the opening flourish — a brief
        // welcome light-show that says "I'm here and I'm fabulous"
        // without the commitment of a full rare event.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.characterEngine.request(.prismDance, force: true)
        }
        characterEngine.start()

        preferences.$speakingFrequency
            .sink { [weak self] frequency in self?.characterEngine.speakingFrequencyMultiplier = frequency }
            .store(in: &cancellables)

        // Sync the dark mode preference to the shared static for views
        // that can't reach the preferences instance.
        AppPreferences.isDarkModeChromeShared = preferences.isDarkModeChrome

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
                PixelChatBubble.panelWidth = CGFloat(width)
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
        // `BILL_BARK_DIAGNOSTIC=1` showcases the bark bubble end-to-end from
        // a terminal: a long multi-line centered bark first (wrapping,
        // rounded corners, outlined tail, near-hat gap), then Bill is
        // parked at the screen's right edge and barks again — the bubble
        // shifts left to stay on screen with the tail tracking him, which
        // is the directional-placement behavior in one screenshot.
        if ProcessInfo.processInfo.environment["BILL_BARK_DIAGNOSTIC"] == "1" {
            Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                self.characterWindowController.characterEngine.bark(
                    "AH, A TEST SUBJECT. WATCH CLOSELY: THIS BUBBLE SITS RIGHT ABOVE MY HAT, WRAPS ITS TEXT PROPERLY, AND ITS TAIL IS PART OF THE BORDER.",
                    importance: .always
                )
                try? await Task.sleep(nanoseconds: 7_000_000_000)
                self.characterWindowController.debugParkNearScreenEdge()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self.characterWindowController.characterEngine.bark(
                    "NOW I'M AT THE SCREEN'S EDGE. NOTICE: THE BUBBLE SHIFTED LEFT, AND MY TAIL FOLLOWED ME. DIRECTIONAL. GEOMETRY IS A LIFESTYLE.",
                    importance: .always
                )
            }
        }
        // `BILL_WEATHER_DIAGNOSTIC=1` fires a forced weather pull at launch
        // and barks whatever the API actually returns — proving the whole
        // pipeline end-to-end: geo → Open-Meteo → condition → dialogue
        // → bark panel on screen.
        if ProcessInfo.processInfo.environment["BILL_WEATHER_DIAGNOSTIC"] == "1" {
            Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                print("=== WEATHER DIAGNOSTIC: pulling ===")
                let snapshot = await WeatherMonitor.pull()
                guard let snapshot else {
                    print("=== WEATHER DIAGNOSTIC: PULL FAILED ===")
                    self.characterWindowController.characterEngine.bark(
                        "THE WEATHER PULL FAILED. CHECK YOUR CONNECTION.",
                        importance: .always
                    )
                    return
                }
                let temp = String(format: "%.0f", snapshot.temperatureC.rounded())
                print("=== WEATHER DIAGNOSTIC: \(snapshot.condition) \(temp)°C in \(snapshot.city ?? "?") ===")
                let conditionKey = "weather.\(snapshot.condition.rawValue)"
                print("=== WEATHER DIAGNOSTIC: looking up dialogue pool '\(conditionKey)' ===")
                if let line = DialogueLibrary.shared.firstLine([conditionKey]) {
                    print("=== WEATHER DIAGNOSTIC: barking '\(line)' ===")
                    self.characterWindowController.characterEngine.bark(line, importance: .always)
                } else {
                    print("=== WEATHER DIAGNOSTIC: no line for '\(conditionKey)' ===")
                    self.characterWindowController.characterEngine.bark(
                        "IT'S \(temp) DEGREES AND \(snapshot.condition.rawValue.uppercased()) OUT THERE. I'D SAY SOMETHING WITTY BUT MY SCRIPT WRITER IS ASLEEP.",
                        importance: .always
                    )
                }
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

        // Weather: reports through the monitor's four-reason callback;
        // gated by the Settings enable toggle, periodic interval honored
        // for steady-weather days. The Test button forces a loud report.
        weatherMonitor.onReport = { [weak self] snapshot, reason in
            self?.reactionRouter.handle(.weatherChanged(snapshot, reason))
        }
        weatherMonitor.onFetchError = { [weak self] message in
            guard let self else { return }
            self.characterEngine.bark(message, importance: .always)
        }
        weatherMonitor.isEnabledProvider = { [weak self] in
            self?.preferences.isWeatherEnabled ?? true
        }
        weatherMonitor.announceIntervalMinutesProvider = { [weak self] in
            self?.preferences.weatherAnnounceMinutes ?? 0
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

    /// Settings/menu "Test weather now" — force a pull and announce it
    /// loudly, whatever the current condition happens to be.
    func testWeatherNow() {
        weatherMonitor.testNow()
    }

    /// Opens the quotes manager: every pool, every line, source badges
    /// (authored/generated/personalized), refresh-everything, and the
    /// recent log strip.
    /// Animation pools for the Settings "Reaction Triggers" test buttons —
    /// mirrors what the `ReactionRouter` would pick for each trigger.
    private static let testTriggerAnimations: [String: [BillState]] = [
        "batteryLow": [.stressed, .dreading, .huffy, .grumpEyes, .watched, .annoyed],
        "networkLost": [.confused, .glitchForm, .spooked, .dazed, .glitching, .ambushed],
        "networkRestored": [.celebrating, .happy, .charged, .zipAround, .fractaling],
        "volume.100": [.dancing, .grooving, .happy, .flinching, .surprised, .caneFlourish],
        "volume.mute": [.dancing, .grooving, .happy, .flinching, .surprised, .caneFlourish],
        "poked": [.poked, .surprised, .flinching, .dazed],
        "chatFailed": [.confused, .spooked, .glitchForm],
        "stillThinking": [.thinking, .focused],
        "incognito.search": [.rampaging],
        "deal.offer": [.caneFlourish, .smug],
        "cipher.message": [.scanning],
        "userReturned": [.watched, .smug, .presenting],
        "clock.morning": [.presenting, .dispatching, .watched, .smug, .zodiacVision],
        "clock.night": [.presenting, .dispatching, .watched, .smug, .zodiacVision],
    ]

    func openQuotesManager() {
        quotesManagerController?.present()
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
