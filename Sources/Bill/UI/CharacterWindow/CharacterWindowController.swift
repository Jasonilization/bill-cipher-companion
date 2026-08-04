import AppKit
import SpriteKit
import Combine

@MainActor
final class CharacterWindowController: NSObject {
    private let panel: NSPanel
    private let hitView: BillHitTestView
    let characterEngine: CharacterEngine
    private let preferences: AppPreferences
    private let chatBridge: ChatBridge
    private let memoryStore: MemoryStore
    private let chatBubble = PixelChatBubble()
    private let contextMenu = NSMenu()
    private var wanderTimer: Timer?
    private var wasWanderingBeforeDrag = false
    private var wasWanderingBeforeChat = false
    private var isAwaitingChatResponse = false
    private var chatTimeoutWork: DispatchWorkItem?
    private var dialogueRefreshTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    /// Set by `AppDelegate` to `chatPanelController.warmUpIfNeeded` — see
    /// that method's doc comment for why this indirection exists (the real
    /// `WebView` chat needs has to come from the already-working full-panel
    /// path, not a dedicated hidden one, which crashed).
    var warmUpChatEngine: (() -> Void)?
    /// Set by `AppDelegate` to `chatPanelController.beginAwaitingResponse`/
    /// `endAwaitingResponse` — see those methods' doc comments for why a
    /// reply's underlying `WebView` needs to be genuinely on-screen for the
    /// short window while it's actually awaited, and why leaving it that
    /// way permanently isn't worth what it costs.
    var beginAwaitingChatResponse: (() -> Void)?
    var endAwaitingChatResponse: (() -> Void)?

    /// True while a *silent* background chat request (the daily dialogue
    /// refresh) is in flight — `AppDelegate`'s `isGenerating`-driven
    /// talking/idle animation checks this so a background request never
    /// makes Bill visibly "talk" for no reason the user can see.
    private(set) var isPerformingBackgroundChatWork = false

    /// A reply longer than this reads as a wall of text in a small speech
    /// bubble rather than a companion-popup aside — the persona preamble
    /// already asks ChatGPT to keep it short, but nothing enforces that on
    /// the far end, so this is a hard backstop.
    private static let maxBarkLength = 280
    /// A watchdog, not a flat timer: re-checked every `chatWatchdogTick`.
    /// If ChatGPT never even *starts* visibly generating within
    /// `chatStartGrace`, something upstream likely failed silently (page
    /// never finished loading, composer selectors didn't match) and it's
    /// safe to recover. But once real activity is observed, waiting
    /// continues all the way out to `chatHardTimeout` — a slow-but-working
    /// reply should never be mistaken for a dead one, which is exactly what
    /// the previous flat 25s timeout did.
    private static let chatWatchdogTick: TimeInterval = 5
    private static let chatStartGrace: TimeInterval = 20
    private static let chatHardTimeout: TimeInterval = 120

    /// Reference values `applyCharacterScale` scales together — all
    /// calibrated for `AppPreferences.characterScale == 1.0` (today's
    /// existing look). Scaling just `rig.root` alone (SpriteKit's `xScale`/
    /// `yScale`) would make Bill visually bigger or smaller *inside* an
    /// unchanged, fixed-size window — fine for shrinking, but clips a
    /// bigger Bill (and his bark bubble, which shares the same rig root)
    /// against the window's own edges. Growing the window, hit region, and
    /// rig anchor by the same factor keeps everything in the same relative
    /// proportion at any scale, not just 1.0.
    private static let baseWindowSize = NSSize(width: 260, height: 700)
    private static let baseHitRegion = CGRect(x: 60, y: 25, width: 140, height: 195)
    private static let baseBodyAnchorY: CGFloat = 110

    init(characterEngine: CharacterEngine, preferences: AppPreferences, chatBridge: ChatBridge, memoryStore: MemoryStore) {
        self.characterEngine = characterEngine
        self.preferences = preferences
        self.chatBridge = chatBridge
        self.memoryStore = memoryStore
        // Taller than Bill's own footprint to leave headroom above his hat
        // for the speech-bubble bark text — 360 wasn't enough once the bark
        // bubble moved to the chunkier pixel-font design (bigger per-line
        // height), which visibly clipped the top of anything past ~2 lines
        // against the view's own bounds. Grown again from 500 to 700
        // alongside raising `BarkBubble.maxLines` — idle/ambient text (up to
        // and including the longer ChatGPT-generated dialogue lines) should
        // always display in full rather than truncating with "…", and that
        // needs real headroom for a much taller bubble to not just move the
        // same clipping problem further up.
        let size = NSSize(width: 260, height: 700)
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        hitView = BillHitTestView(frame: NSRect(origin: .zero, size: size))
        super.init()
        configure(size: size)
        configureChat()
    }

    private func configure(size: NSSize) {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        // `BillHitTestView`'s own hitTest only decides which view *within
        // this window* handles an event — it doesn't make the window pass
        // events through to whatever's behind it on screen, which needs
        // `ignoresMouseEvents` toggled on the window itself. Starts `true`
        // (click-through) since the cursor's position relative to Bill is
        // unknown at launch; `startClickThroughTracking` (from `show()`)
        // corrects this within one tick regardless of where it actually is.
        panel.ignoresMouseEvents = true

        hitView.allowsTransparency = true
        hitView.ignoresSiblingOrder = true
        // Bill is small and simple — 30fps is imperceptible and halves render cost vs 60fps.
        hitView.preferredFramesPerSecond = 30
        hitView.onClick = { [weak self] in self?.handleClick() }
        hitView.onDragStarted = { [weak self] in self?.handleDragStarted() }
        hitView.onDragEnded = { [weak self] in self?.handleDragEnded() }
        hitView.onRightClick = { [weak self] event in self?.showContextMenu(for: event) }

        let scene = BillScene(size: size, characterEngine: characterEngine)
        hitView.presentScene(scene)
        panel.contentView = hitView

        // Idle Bill has nothing to draw every frame — pause the render loop
        // entirely and only wake it while a clip is actually playing.
        hitView.isPaused = true
        characterEngine.stateMachine.onActivityChanged = { [weak hitView] isActive in
            hitView?.isPaused = !isActive
        }

        applyCharacterScale(preferences.characterScale, keepingCurrentPosition: false)
        preferences.$characterScale
            .sink { [weak self] scale in self?.applyCharacterScale(scale, keepingCurrentPosition: true) }
            .store(in: &cancellables)
    }

    /// Resizes the window, `hitView`'s frame, Bill's clickable hit region,
    /// and his rig's own position/scale together from `Self.base*` — see
    /// their doc comment for why these all need to move as one unit rather
    /// than just scaling `rig.root` in isolation.
    ///
    /// `keepingCurrentPosition`: `false` (only at initial setup) anchors
    /// the window to its default screen corner the same way the original
    /// fixed-size window always did; `true` (every later call, e.g. the
    /// user dragging the Settings scale slider) instead keeps Bill's
    /// current horizontal center and bottom edge fixed, so adjusting scale
    /// grows/shrinks him in place rather than snapping him back to that
    /// corner from wherever he'd wandered to.
    private func applyCharacterScale(_ scale: CGFloat, keepingCurrentPosition: Bool) {
        let newSize = NSSize(width: Self.baseWindowSize.width * scale, height: Self.baseWindowSize.height * scale)
        var newOrigin: NSPoint
        if keepingCurrentPosition {
            let current = panel.frame
            newOrigin = NSPoint(x: current.midX - newSize.width / 2, y: current.minY)
        } else if let screen = NSScreen.main {
            newOrigin = NSPoint(
                x: screen.visibleFrame.maxX - newSize.width - 24,
                y: screen.visibleFrame.minY + 24
            )
        } else {
            newOrigin = panel.frame.origin
        }

        // `keepingCurrentPosition` re-centers on the *old* midpoint, so
        // scaling up while Bill sits near a screen edge (his default spot)
        // can push the wider/taller window partly off screen — clamp back
        // on, rather than letting him (and his hit region, and wherever
        // the chat bubble anchors from) drift somewhere half off-screen.
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            newOrigin.x = min(max(newOrigin.x, visible.minX), visible.maxX - newSize.width)
            newOrigin.y = min(max(newOrigin.y, visible.minY), visible.maxY - newSize.height)
        }

        panel.setFrame(NSRect(origin: newOrigin, size: newSize), display: true)
        hitView.frame = NSRect(origin: .zero, size: newSize)
        hitView.hitRegion = CGRect(
            x: Self.baseHitRegion.minX * scale,
            y: Self.baseHitRegion.minY * scale,
            width: Self.baseHitRegion.width * scale,
            height: Self.baseHitRegion.height * scale
        )
        characterEngine.rig.root.position = CGPoint(x: newSize.width / 2, y: Self.baseBodyAnchorY * scale)
        characterEngine.rig.root.setScale(scale)
    }

    /// Bill *is* the chat interface now: right-click → "Talk" opens a small
    /// pixel speech bubble beside him, the typed message goes through the
    /// existing ChatGPT bridge, and the reply comes back in that same
    /// bubble — the raw web page is never the primary surface (see
    /// `ChatPanelController`, which stays around only as an opt-in "full
    /// view").
    private func configureChat() {
        let talkItem = NSMenuItem(title: "Talk", action: #selector(handleTalkMenuItem), keyEquivalent: "")
        talkItem.target = self
        contextMenu.addItem(talkItem)

        chatBubble.onSubmit = { [weak self] text in
            self?.handleChatSubmit(text)
        }
        chatBubble.onDismiss = { [weak self] in
            guard let self else { return }
            // Guards against Bill ever being stranded in `.talking`/
            // `.thinking` if the bubble closes mid-exchange — idempotent
            // when he's already idle.
            characterEngine.request(.idle)
            if wasWanderingBeforeChat {
                wasWanderingBeforeChat = false
                scheduleNextWander()
            }
        }
        chatBridge.onResponseReceived = { [weak self] response in
            guard let self else { return }
            if isPerformingBackgroundChatWork {
                finishDialogueRefresh(response)
            } else {
                handleChatResponse(response)
            }
        }
    }

    private func showContextMenu(for event: NSEvent) {
        NSMenu.popUpContextMenu(contextMenu, with: event, for: hitView)
    }

    @objc private func handleTalkMenuItem() {
        talkToBill()
    }

    /// Summons the pixel chat bubble beside Bill — the primary way to talk
    /// to him, reachable via right-click → "Talk", the global hotkey, or
    /// the menu bar. Reopening while it's already up just closes it, so the
    /// hotkey also works as a toggle.
    func talkToBill() {
        if chatBubble.isVisible {
            chatBubble.hide()
            return
        }
        guard !isAwaitingChatResponse else {
            characterEngine.bark(BarkLines.random(from: BarkLines.stillThinking))
            return
        }
        guard let screen = NSScreen.main else { return }
        wasWanderingBeforeChat = true
        wanderTimer?.invalidate()
        // Once per time chat is *opened*, not once ever — the user's recent
        // activity may well have changed since the last time they talked to
        // Bill, even if the conversation stack on screen is the same one
        // from earlier, so a stale context blurb from possibly hours ago
        // shouldn't keep being skipped.
        hasIncludedActivityContext = false
        // Must run before `showCompose` — this is what actually gets a real
        // `WebView` attached to the page (see `ChatPanelController.
        // warmUpIfNeeded`'s doc comment). Plain `chatBridge.prepareIfNeeded()`
        // alone only constructs the `WebPage` model object, which never
        // loads/executes anything on its own.
        warmUpChatEngine?()
        chatBubble.showCompose(near: panel.frame, on: screen)
    }

    private func handleChatSubmit(_ text: String) {
        isAwaitingChatResponse = true
        beginAwaitingChatResponse?()
        characterEngine.request(.thinking, force: true)
        chatBridge.send(contextualized(text))
        if let screen = NSScreen.main {
            chatBubble.showWaiting(near: panel.frame, on: screen)
        }
        scheduleChatWatchdog(elapsed: 0)
    }

    private var hasIncludedActivityContext = false

    /// Folds a short recent-activity summary into the first real message of
    /// each chat *session* (reset in `talkToBill()` every time the bubble
    /// is opened fresh) — enough for ChatGPT's replies to feel aware of how
    /// the Mac's actually being used, without repeating the same context
    /// block on every single message within one sitting.
    private func contextualized(_ text: String) -> String {
        guard !hasIncludedActivityContext else { return text }
        let summary = memoryStore.recentActivitySummary
        guard !summary.isEmpty else { return text }
        hasIncludedActivityContext = true
        return "[For your context, not to repeat verbatim: I've recently been using this Mac for \(summary).] \(text)"
    }

    /// Re-checks every `chatWatchdogTick` rather than firing once — see the
    /// type-level doc comment on the watchdog constants for why a flat
    /// timer isn't the right shape here. Still guarantees Bill can never be
    /// stuck in `.thinking` forever (the same class of bug as the earlier
    /// `celebrating` stuck-loop, just reachable from the network instead of
    /// an animation clip), just without mistaking "slow" for "dead."
    private func scheduleChatWatchdog(elapsed: TimeInterval) {
        chatTimeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.checkChatWatchdog(elapsed: elapsed + Self.chatWatchdogTick)
        }
        chatTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.chatWatchdogTick, execute: work)
    }

    private func checkChatWatchdog(elapsed: TimeInterval) {
        guard isAwaitingChatResponse else { return }

        if chatBridge.isGenerating {
            if elapsed >= Self.chatHardTimeout {
                handleChatResponse(nil)
            } else {
                scheduleChatWatchdog(elapsed: elapsed)
            }
            return
        }

        if elapsed >= Self.chatStartGrace {
            handleChatResponse(nil)
            return
        }
        // One well-timed "still working on it" beat partway through the
        // start grace — the animated "Thinking…" dots in the bubble already
        // carry most of the "still alive" signal, so this is deliberately a
        // single occasional aside rather than a recurring interruption.
        if abs(elapsed - Self.chatStartGrace / 2) < Self.chatWatchdogTick / 2 {
            characterEngine.bark(BarkLines.random(from: BarkLines.stillThinking))
        }
        scheduleChatWatchdog(elapsed: elapsed)
    }

    private func handleChatResponse(_ response: String?) {
        // `chatBridge`'s "generating" signal is a best-effort DOM-mutation
        // heuristic (see `ChatGPTBridgeScripts`), not a real event tied to
        // something Bill actually asked for — the warm-up flow's very first
        // page load alone causes enough DOM churn to look like a complete
        // generating-then-idle cycle before the user has typed anything.
        // Without this guard, that alone was enough to force-close a
        // freshly opened compose bubble and bark a false "connection's bad"
        // line a few seconds after opening chat, every time.
        guard isAwaitingChatResponse else { return }
        chatTimeoutWork?.cancel()
        chatTimeoutWork = nil
        isAwaitingChatResponse = false
        endAwaitingChatResponse?()
        guard let response, !response.isEmpty else {
            characterEngine.request(.idle)
            characterEngine.bark(BarkLines.random(from: BarkLines.chatFailed))
            chatBubble.hide()
            return
        }
        // If the user dismissed the bubble while Bill was still thinking,
        // don't force it back open — respect the dismissal and deliver the
        // reply through the lighter ambient bark instead. Only *that* small,
        // fixed-size aside (see `BarkBubble`) still needs truncating — the
        // pixel chat stack itself grows to fit a reply in full, which is the
        // whole point of it no longer being a single "companion aside" box.
        guard chatBubble.isVisible, let screen = NSScreen.main else {
            characterEngine.request(.idle)
            let trimmed = response.count > Self.maxBarkLength
                ? String(response.prefix(Self.maxBarkLength)) + "…"
                : response
            characterEngine.bark(trimmed)
            return
        }
        chatBubble.showResponse(response, near: panel.frame, on: screen)
        // A quick happy beat, then a talking gesture while the reply is up
        // — reads as Bill delivering the line rather than a webpage
        // repainting. Settles back to idle on its own regardless of
        // whether the user leaves the bubble open (the `.talking` loop
        // must never be the last state requested with nothing to end it —
        // see `onDismiss`'s doc comment for the same concern from the other
        // direction).
        characterEngine.request(.happy, force: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.characterEngine.request(.talking)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                self?.characterEngine.request(.idle)
            }
        }
    }

    /// Forces an immediate wander leg for manual verification — bypasses the
    /// random delay, the current-state gate, and the glance-only roll
    /// entirely, so it always visibly moves regardless of what Bill's doing.
    func debugTriggerWander() {
        wanderTimer?.invalidate()
        characterEngine.request(.idle)
        performWanderLeg(remaining: 2)
    }

    func show() {
        panel.orderFrontRegardless()
        scheduleNextWander()
        startCursorWatch()
        startClickThroughTracking()
        scheduleDialogueRefreshCheck()
    }

    // MARK: - Daily dialogue refresh

    /// Roughly once a day, silently asks ChatGPT (through the same bridge
    /// the visible chat uses) for a small batch of fresh Bill-voice lines
    /// about how this Mac has actually been used, and folds them into
    /// `MemoryStore`'s growing dialogue library (see
    /// `beginWanderBeat`/`fireIdleBeat`, where they get mixed into ambient
    /// commentary). Entirely best-effort: if ChatGPT is unavailable or the
    /// request fails, this just quietly doesn't add anything and the
    /// existing static `BarkLines` pools keep working exactly as before —
    /// this is additive, never a dependency.
    private static let dialogueRefreshCheckInterval: TimeInterval = 30 * 60
    private static let dialogueRefreshInterval: TimeInterval = 24 * 60 * 60

    private func scheduleDialogueRefreshCheck() {
        dialogueRefreshTimer?.invalidate()
        dialogueRefreshTimer = Timer.scheduledTimer(withTimeInterval: Self.dialogueRefreshCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.maybeRefreshDialogue() }
        }
    }

    /// Apps awaiting a description from the refresh currently in flight,
    /// keyed by the exact display name sent to ChatGPT — populated right
    /// before `send(_:)` and consumed in `finishDialogueRefresh`, since the
    /// response comes back as plain text with app *names*, not bundle IDs
    /// (much more natural for a model to read/write than a reverse-DNS
    /// string), and this is what maps a name back to the bundle ID
    /// `MemoryStore.setAppDescription` actually needs.
    private var pendingDescriptionRequests: [String: String] = [:]
    /// Cap on how many undescribed apps to ask about per refresh — this
    /// rides along on the same once-a-day dialogue request rather than
    /// its own schedule, so keeping the ask small keeps that request itself
    /// quick and easy for ChatGPT to fully answer in one reply.
    private static let maxAppDescriptionsPerRefresh = 5

    private func maybeRefreshDialogue() {
        guard memoryStore.shouldRefreshDialogue(interval: Self.dialogueRefreshInterval) else { return }
        performDialogueRefresh()
    }

    /// Manually forces the same daily refresh `maybeRefreshDialogue` fires
    /// on its own once every 24h — reachable from the menu bar's "Refresh
    /// Bill's Context Now" for anyone who doesn't want to wait for the
    /// timer, e.g. right after a burst of using some new app. Bypasses only
    /// the *interval* gate; still silently does nothing if a chat exchange
    /// is already in flight or the bubble is open, same as the automatic
    /// path, since this is meant to run invisibly in the background either
    /// way.
    func refreshDialogueNow() {
        performDialogueRefresh()
    }

    /// Kept purely for the debug log window (see `DialogueRefreshLogEntry`'s
    /// doc comment) — capped since this is a debug convenience, not
    /// something meant to grow unbounded over a long-running session.
    private(set) var dialogueRefreshLog: [DialogueRefreshLogEntry] = []
    private static let maxDialogueRefreshLogEntries = 20

    private func performDialogueRefresh() {
        guard !isAwaitingChatResponse, !chatBubble.isVisible, !isPerformingBackgroundChatWork else { return }
        let summary = memoryStore.recentActivitySummary
        guard !summary.isEmpty else { return }

        let undescribed = Array(memoryStore.undescribedFrequentApps().prefix(Self.maxAppDescriptionsPerRefresh))
        pendingDescriptionRequests = Dictionary(uniqueKeysWithValues: undescribed.map { ($0.name, $0.bundleID) })

        var prompt = """
            Generate exactly 6 short, one-sentence quips you'd say about how \
            this Mac has been used recently: \(summary). One per line, no \
            numbering, no quotes, each under 100 characters.
            """
        if !undescribed.isEmpty {
            let names = undescribed.map(\.name).joined(separator: ", ")
            prompt += """
                \n\nThen, one per line, prefixed with "APP:", give a single \
                short sarcastic-but-informative sentence describing what each \
                of these apps is for, formatted exactly as \
                "APP: <name>: <description>", for: \(names).
                """
        }

        dialogueRefreshLog.append(DialogueRefreshLogEntry(date: Date(), prompt: prompt))
        if dialogueRefreshLog.count > Self.maxDialogueRefreshLogEntries {
            dialogueRefreshLog.removeFirst(dialogueRefreshLog.count - Self.maxDialogueRefreshLogEntries)
        }

        isPerformingBackgroundChatWork = true
        beginAwaitingChatResponse?()
        chatBridge.prepareIfNeeded()
        chatBridge.send(prompt)
    }

    private func finishDialogueRefresh(_ response: String?) {
        isPerformingBackgroundChatWork = false
        endAwaitingChatResponse?()
        let pending = pendingDescriptionRequests
        pendingDescriptionRequests = [:]
        let logIndex = dialogueRefreshLog.indices.last

        guard let response else {
            if let logIndex { dialogueRefreshLog[logIndex].failureReason = "No response received (send failed or timed out)." }
            return
        }

        let trimChars = CharacterSet(charactersIn: " -•*0123456789.\"'")
        var dialogueLines: [String] = []
        var descriptionsAdded: [(name: String, description: String)] = []
        for rawLine in response.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("APP:") else {
                let cleaned = line.trimmingCharacters(in: trimChars)
                if !cleaned.isEmpty, cleaned.count <= 140 {
                    dialogueLines.append(cleaned)
                }
                continue
            }
            // "APP: <name>: <description>" — split on the *first two*
            // colons only, since a description is free text and may well
            // contain its own colons further in.
            let afterPrefix = line.dropFirst("APP:".count).trimmingCharacters(in: .whitespaces)
            guard let separatorRange = afterPrefix.range(of: ":") else { continue }
            let name = afterPrefix[afterPrefix.startIndex..<separatorRange.lowerBound].trimmingCharacters(in: .whitespaces)
            let description = afterPrefix[separatorRange.upperBound...].trimmingCharacters(in: .whitespaces)
            guard let bundleID = pending[name], !description.isEmpty else { continue }
            memoryStore.setAppDescription(bundleID: bundleID, description)
            descriptionsAdded.append((name: name, description: description))
        }
        let addedLines = Array(dialogueLines.prefix(8))
        memoryStore.addGeneratedDialogue(addedLines)

        if let logIndex {
            dialogueRefreshLog[logIndex].rawResponse = response
            dialogueRefreshLog[logIndex].dialogueLinesAdded = addedLines
            dialogueRefreshLog[logIndex].appDescriptionsAdded = descriptionsAdded
            if addedLines.isEmpty, descriptionsAdded.isEmpty {
                dialogueRefreshLog[logIndex].failureReason = "Response received but nothing usable was parsed from it."
            }
        }
    }

    private func handleClick() {
        characterEngine.request(.poked, force: true)
        characterEngine.bark(BarkLines.random(from: BarkLines.poked))
    }

    private func handleDragStarted() {
        wasWanderingBeforeDrag = true
        wanderTimer?.invalidate()
        characterEngine.request(.surprised, force: true)
    }

    private func handleDragEnded() {
        // `.dazed` exists specifically as "a brief post-surprise recovery
        // beat" (see its doc comment in `BillState`) but had no caller
        // anywhere — being picked up and dropped is exactly that moment,
        // and it settles back to idle on its own afterward since it's a
        // one-shot state.
        characterEngine.request(.dazed, force: true)
        if wasWanderingBeforeDrag {
            scheduleNextWander()
        }
    }

    /// Bill occasionally wanders across the screen while idle — otherwise
    /// "roaming" is a settings toggle with nothing behind it. Only ever
    /// fires from genuine idle, and only while roaming is on.
    ///
    /// Live-instrumented (temporary debug prints, since removed) against a
    /// real running instance to see why wandering felt entirely absent: a
    /// wander check only has a narrow window to land in — it's blocked
    /// outright while asleep or mid-beat on some other state (an idle-beat
    /// personality flourish, a rare Easter egg, chat, ...), and on top of
    /// that the old 30%-chance-to-actually-move meant even a check that
    /// *did* land during plain idle usually just did a glance instead. Four
    /// consecutive real checks in that instrumented run produced zero
    /// visible movement: sleep-blocked, a rare-event collision, then two
    /// glance-only rolls in a row. Fixed by making an eligible check
    /// overwhelmingly likely to actually move (15% glance chance, down from
    /// 30%) and checking more often (15-32s, down from 22-50s) so a
    /// same-moment collision with sleep/another beat has more follow-up
    /// chances rather than waiting the better part of a minute for the next
    /// one.
    private func scheduleNextWander() {
        wanderTimer?.invalidate()
        let delay = Double.random(in: 15...32)
        wanderTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.beginWanderBeat() }
        }
    }

    /// One "beat" of ambient movement: either a pure look-around (no
    /// relocation) or a short walk of one or two legs with a chance to
    /// pause and look around between legs — never one long uninterrupted
    /// slide, which is what made the first pass's wandering feel like a
    /// scripted slide rather than a choice Bill is making.
    private func beginWanderBeat() {
        guard preferences.isRoamingEnabled,
              characterEngine.stateMachine.currentState == .idle,
              NSScreen.main != nil
        else {
            scheduleNextWander()
            return
        }

        guard Double.random(in: 0..<1) > 0.15 else {
            // Stayed put, just glanced around — kept as a small chance for
            // variety, not the coin-flip it was (see this method's caller's
            // doc comment for why that made actual movement too rare).
            characterEngine.stateMachine.playIdleVariant(
                [.tiltCheck, .curious].randomElement()!
            )
            // Occasionally surface a line from the growing, ChatGPT-seeded
            // dialogue library instead of nothing — additive to the static
            // BarkLines pools, never a replacement for them.
            let generated = memoryStore.data.generatedDialogue
            if !generated.isEmpty, Double.random(in: 0..<1) < 0.25 {
                characterEngine.bark(BarkLines.random(from: generated))
            }
            scheduleNextWander()
            return
        }

        performWanderLeg(remaining: Int.random(in: 1...2))
    }

    private func performWanderLeg(remaining: Int) {
        guard remaining > 0, let screen = NSScreen.main else {
            characterEngine.request(.idle)
            scheduleNextWander()
            return
        }

        characterEngine.request(.walking)

        let currentOrigin = panel.frame.origin
        let deltaX = CGFloat.random(in: -170...170)
        let minX = screen.visibleFrame.minX
        let maxX = screen.visibleFrame.maxX - panel.frame.width
        let newX = min(max(currentOrigin.x + deltaX, minX), maxX)

        // The walk-cycle art is a side-facing run (legs kick and the lead
        // arm swings toward one specific side) — without mirroring it, Bill
        // would visibly "moonwalk" backward on every other leg since he
        // wanders both directions. The sheet's frames face left, so flip
        // for rightward travel.
        if newX > currentOrigin.x + 0.5 {
            characterEngine.rig.bodyNode.xScale = -BillRigNode.displayScale
        } else if newX < currentOrigin.x - 0.5 {
            characterEngine.rig.bodyNode.xScale = BillRigNode.displayScale
        }

        // Duration derived from a target speed (not independently randomized
        // from distance) so a short hop and a long crossing both move at
        // roughly the same natural pace instead of one looking like a slow
        // drift and the other a dash. Tuned to roughly match the walk
        // clip's slowed-down (ambling, not sprinting) frame rate — mismatch
        // between apparent foot-speed and actual ground-speed is what reads
        // as sliding/moonwalking, independent of the direction-flip itself.
        let distance = abs(newX - currentOrigin.x)
        let speed = CGFloat.random(in: 55...80)
        let duration = min(3.2, max(0.9, Double(distance / speed)))

        // `NSWindow.animator().setFrameOrigin(_:)` is not actually one of
        // the animator proxy's supported properties (unlike NSView, where
        // it works fine) — the completion handler fires right on schedule,
        // but the window's frame never actually changes. This was
        // confirmed by logging `panel.frame` inside the completion handler:
        // it read back identical to `currentOrigin` every time, so wander
        // was silently never moving Bill at all, just running his walk
        // texture-cycle in place — exactly what "he never visibly moves"
        // looks like. `setFrame(_:display:)` is the form NSWindow's
        // animator proxy actually supports.
        let targetFrame = NSRect(x: newX, y: currentOrigin.y, width: panel.frame.width, height: panel.frame.height)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(targetFrame, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.characterEngine.request(.idle)

                guard remaining > 1 else {
                    self.scheduleNextWander()
                    return
                }
                // Pause and look around before the next leg — an "inspecting
                // the neighborhood" beat rather than beelining to a
                // destination.
                self.characterEngine.stateMachine.playIdleVariant(.tiltCheck)
                DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 0.9...1.7)) { [weak self] in
                    self?.performWanderLeg(remaining: remaining - 1)
                }
            }
        }
    }

    // MARK: - Cursor awareness

    /// A coarse, cheap poll (not a global event tap — this project
    /// deliberately avoids those; see the architecture doc) that lets Bill
    /// notice when the cursor lingers right next to him and give a small
    /// acknowledgment, so he doesn't feel oblivious to the one thing
    /// sharing his screen. `NSEvent.mouseLocation` is a plain synchronous
    /// read, not a subscription, so polling it every few seconds while
    /// idle costs nothing measurable.
    private var cursorWatchTimer: Timer?
    private var lastCursorReactionDate: Date?
    private static let cursorProximityCheckInterval: TimeInterval = 2.5
    private static let cursorProximityReactionCooldown: TimeInterval = 100

    private func startCursorWatch() {
        cursorWatchTimer?.invalidate()
        cursorWatchTimer = Timer.scheduledTimer(withTimeInterval: Self.cursorProximityCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkCursorProximity() }
        }
    }

    private func checkCursorProximity() {
        guard preferences.isRoamingEnabled,
              characterEngine.stateMachine.currentState == .idle,
              panel.isVisible
        else { return }
        if let last = lastCursorReactionDate, Date().timeIntervalSince(last) < Self.cursorProximityReactionCooldown {
            return
        }
        let proximityRect = panel.frame.insetBy(dx: -30, dy: -30)
        guard proximityRect.contains(NSEvent.mouseLocation) else { return }

        lastCursorReactionDate = Date()
        characterEngine.stateMachine.playIdleVariant(.tiltCheck)
        if Bool.random() {
            characterEngine.bark(BarkLines.random(from: BarkLines.noticesCursor))
        }
    }

    // MARK: - Click-through outside Bill's silhouette

    /// `BillHitTestView.hitTest(_:)` returning `nil` only decides which
    /// view *inside this app's own window* handles an event — it does
    /// nothing to pass that event through to whatever app is behind the
    /// window on screen, since `panel.ignoresMouseEvents = false` means the
    /// window itself still claims every click/scroll anywhere within its
    /// frame. The character window's frame is large (260x700, to leave
    /// headroom for the bark bubble above Bill's head), so left as-is that
    /// silently ate clicks and scrolls over a sizable chunk of the screen —
    /// a real "can't control my Mac" problem, not just a visual one.
    ///
    /// The fix macOS actually supports is toggling `ignoresMouseEvents` on
    /// the whole window based on where the cursor currently is: `true`
    /// (events pass through to whatever's behind) whenever the cursor is
    /// outside Bill's own silhouette, `false` (events land on Bill, so
    /// click/drag/right-click still work) when it's inside. `NSEvent.
    /// mouseLocation` is a plain synchronous global read, so polling it
    /// frequently is cheap — this runs much faster than `cursorWatchTimer`
    /// above (that one's an occasional ambient-reaction check; this one
    /// needs to feel instantaneous to not itself feel like the bug it's
    /// fixing). Each tick itself is trivially cheap (a rect-contains-point
    /// comparison), but a continuous, forever-running timer still means
    /// the process never fully idles — macOS's energy-impact accounting
    /// weighs wakeup *frequency*, not just per-wakeup CPU time. 100ms is
    /// still well under human click-reaction time for a binary
    /// pass-through toggle, so this halves the wakeup rate from the
    /// original 20Hz with no perceptible responsiveness change.
    private var clickThroughTimer: Timer?
    private static let clickThroughCheckInterval: TimeInterval = 0.1

    private func startClickThroughTracking() {
        clickThroughTimer?.invalidate()
        clickThroughTimer = Timer.scheduledTimer(withTimeInterval: Self.clickThroughCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateClickThrough() }
        }
    }

    private func updateClickThrough() {
        // Never flip mid-gesture — switching to click-through while a
        // button is held would abandon an in-progress drag on Bill (or,
        // symmetrically, suddenly start swallowing a drag that started
        // elsewhere and is just passing over the window).
        guard NSEvent.pressedMouseButtons == 0 else { return }
        let hitRegionOnScreen = hitView.hitRegion.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
        panel.ignoresMouseEvents = !hitRegionOnScreen.contains(NSEvent.mouseLocation)
    }
}
