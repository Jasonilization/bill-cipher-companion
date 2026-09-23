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
    /// Keeps the (invisible) chat WebView mounted for as long as Bill's own
    /// speech-bubble chat is open, so the page stays live across the whole
    /// exchange instead of only while a reply is outstanding.
    var setChatEngineMounted: ((Bool) -> Void)?
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
    /// Normal size: just Bill, with a little headroom for his hat.
    ///
    /// The window used to be 260x700 at all times — roughly 500pt of empty,
    /// invisible window sitting directly above him. Click-through hides most
    /// of that, but only on a poll, so a click landing in that column within a
    /// tick of the cursor being near him was still swallowed by an invisible
    /// window. Shrinking to what he actually occupies removes the problem
    /// rather than papering over it: there is simply no window there to eat
    /// anything.
    private static let baseWindowSize = NSSize(width: 260, height: 250)
    /// Grown to this only while a speech bubble is on screen, which is the one
    /// time the headroom is genuinely needed.
    private static let barkWindowHeight: CGFloat = 700
    private static let baseHitRegion = CGRect(x: 60, y: 25, width: 140, height: 195)
    private static let baseBodyAnchorY: CGFloat = 110

    /// Full rate, used while a real clip, a bark, or a roaming beat is running.
    private static let activeFramesPerSecond = 30
    /// The ambient idle bob changes content ~6.7 times a second (7 frames at
    /// 0.15s), so rendering it faster than this buys nothing visible.
    private static let ambientFramesPerSecond = 12

    init(characterEngine: CharacterEngine, preferences: AppPreferences, chatBridge: ChatBridge, memoryStore: MemoryStore) {
        self.characterEngine = characterEngine
        self.preferences = preferences
        self.chatBridge = chatBridge
        self.memoryStore = memoryStore
        // Starts compact. The tall form (`barkWindowHeight`) is only adopted
        // while a speech bubble is on screen — see `setPanelExpanded`.
        let size = Self.baseWindowSize
        // `BillPanel`, not a plain `NSPanel` — see its doc comment: the
        // stock frame constraint pins this (deliberately headroom-heavy)
        // window's top to the menu bar, which is what stopped Bill being
        // draggable past roughly 60% of the screen height.
        panel = BillPanel(
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
        // Bill is small and simple — 30fps is imperceptible and halves render
        // cost vs 60fps. See `onActivityChanged` below for the ambient step-down.
        hitView.preferredFramesPerSecond = Self.activeFramesPerSecond
        hitView.onClick = { [weak self] in self?.handleClick() }
        hitView.onDragStarted = { [weak self] in self?.handleDragStarted() }
        hitView.onDragEnded = { [weak self] in self?.handleDragEnded() }
        hitView.onRightClick = { [weak self] event in self?.showContextMenu(for: event) }

        let scene = BillScene(size: size, characterEngine: characterEngine)
        hitView.presentScene(scene)
        panel.contentView = hitView

        // Idle Bill still animates (the ambient bob must never freeze), so the
        // render loop cannot simply be paused. Instead it runs at
        // `ambientFramesPerSecond` while nothing but that bob is happening and
        // steps up to `activeFramesPerSecond` for real clips, barks and
        // roaming. Idle dominates the runtime, so this is where the GPU time
        // actually goes.
        hitView.preferredFramesPerSecond = Self.ambientFramesPerSecond
        characterEngine.stateMachine.onActivityChanged = { [weak hitView] isActive in
            hitView?.preferredFramesPerSecond = isActive
                ? Self.activeFramesPerSecond
                : Self.ambientFramesPerSecond
        }
        // The tall window exists only for speech bubbles, so it only exists
        // while one is showing.
        characterEngine.stateMachine.onBarkVisibilityChanged = { [weak self] isShowing in
            self?.setPanelExpanded(isShowing)
        }

        // Keep the speech bubble glued to Bill wherever he ends up — roaming,
        // a drag, or a window shoving him all move the panel.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.followBubbleToBill() }
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
    /// True while a bark bubble needs the tall window.
    private var isPanelExpanded = false

    /// Grows/shrinks the window around Bill without moving him.
    ///
    /// The window is bottom-left anchored and Bill sits a fixed distance above
    /// its bottom edge, so changing only the height (and leaving `origin.y`
    /// alone) adds or removes space purely at the top. The scene is
    /// `.resizeFill` and the rig is anchored from the bottom, so nothing about
    /// Bill's own position or scale changes.
    private func setPanelExpanded(_ expanded: Bool) {
        guard expanded != isPanelExpanded else { return }
        isPanelExpanded = expanded
        let scale = preferences.characterScale
        let height = (expanded ? Self.barkWindowHeight : Self.baseWindowSize.height) * scale
        let width = Self.baseWindowSize.width * scale
        let origin = panel.frame.origin
        panel.setFrame(NSRect(x: origin.x, y: origin.y, width: width, height: height), display: false)
        hitView.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
    }

    private func applyCharacterScale(_ scale: CGFloat, keepingCurrentPosition: Bool) {
        let baseHeight = isPanelExpanded ? Self.barkWindowHeight : Self.baseWindowSize.height
        let newSize = NSSize(width: Self.baseWindowSize.width * scale, height: baseHeight * scale)
        let newHitRegion = CGRect(
            x: Self.baseHitRegion.minX * scale,
            y: Self.baseHitRegion.minY * scale,
            width: Self.baseHitRegion.width * scale,
            height: Self.baseHitRegion.height * scale
        )
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

        // Clamp so Bill's actual silhouette (`newHitRegion`) stays
        // reachable on screen — *not* the full window rect, which is
        // mostly empty, click-through headroom reserved above his hat for
        // the bark bubble. Clamping the whole window there meant a taller
        // window at larger scale pushed Bill further and further down as
        // scale grew, even though that empty headroom never needed to be
        // on screen at all. This still lets the window's top run off
        // screen, which is exactly what lets Bill's own hat reach the
        // screen's actual top edge instead of stopping short of it.
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let minOriginX = visible.minX - newHitRegion.minX
            let maxOriginX = visible.maxX - newHitRegion.maxX
            newOrigin.x = min(max(newOrigin.x, minOriginX), maxOriginX)
            let minOriginY = visible.minY - newHitRegion.minY
            let maxOriginY = visible.maxY - newHitRegion.maxY
            newOrigin.y = min(max(newOrigin.y, minOriginY), maxOriginY)
        }

        panel.setFrame(NSRect(origin: newOrigin, size: newSize), display: true)
        hitView.frame = NSRect(origin: .zero, size: newSize)
        hitView.hitRegion = newHitRegion
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
            setChatEngineMounted?(false)
            if wasWanderingBeforeChat {
                wasWanderingBeforeChat = false
                roaming?.resume()
            }
        }
        chatBridge.onResponseReceived = { [weak self] response in
            guard let self else { return }
            if personalizationEngine.isActive {
                personalizationEngine.handleResponse(response)
            } else if isPerformingBackgroundChatWork {
                finishDialogueRefresh(response)
            } else {
                handleChatResponse(response)
            }
        }
    }

    // MARK: - Personalization setup

    /// The first-run "study my apps" flow. Owned here rather than in
    /// `AppDelegate` because the flow needs this controller's WebView
    /// mounting callbacks and quiet-mode flag — the exact plumbing the
    /// dialogue refresh already uses. Lazy because the engine needs the
    /// already-injected `memoryStore` for app prioritization.
    private(set) lazy var personalizationEngine = PersonalizationEngine(memoryStore: memoryStore)

    /// Kicks off (or re-runs) the setup flow. Guarded so a run can never
    /// collide with a live user chat or the daily refresh — all three share
    /// one ChatGPT page.
    func runPersonalizationSetup() {
        guard !personalizationEngine.isActive, !isAwaitingChatResponse, !isPerformingBackgroundChatWork else {
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await self.chatBridge.checkSignedIn() else {
                self.personalizationEngine.requireLogin()
                return
            }
            self.reallyRunPersonalization()
        }
    }

    private func reallyRunPersonalization() {
        // Re-guard after the async sign-in check — a second click during
        // that gap must not stack a second run.
        guard !personalizationEngine.isActive, !isPerformingBackgroundChatWork else { return }
        isPerformingBackgroundChatWork = true
        roaming?.suspend()

        personalizationEngine.send = { [weak self] prompt in
            guard let self else { return }
            // Same mounting dance as a real user send: the page must be
            // genuinely on-screen for its DOM observers to run (see
            // `ChatPanelController.beginAwaitingResponse`).
            self.warmUpChatEngine?()
            self.setChatEngineMounted?(true)
            self.beginAwaitingChatResponse?()
            self.chatBridge.send(prompt)
        }
        personalizationEngine.presentLogin = { [weak self] in
            self?.openFullChat?()
        }
        personalizationEngine.weatherBlurbProvider = { [weak self] in
            self?.weatherBlurbProvider?()
        }
        personalizationEngine.onRunFinished = { [weak self] in
            guard let self else { return }
            self.setChatEngineMounted?(false)
            self.endAwaitingChatResponse?()
            self.isPerformingBackgroundChatWork = false
            self.roaming?.resume()
        }
        personalizationEngine.begin()
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
        guard let screen = panel.screen ?? NSScreen.main else { return }
        wasWanderingBeforeChat = true
        roaming?.suspend()
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
        setChatEngineMounted?(true)
        chatBubble.showCompose(near: panel.frame, on: screen)
    }

    private func handleChatSubmit(_ text: String) {
        // Bail out loudly rather than sending into a login wall.
        Task { @MainActor [weak self] in
            guard let self else { return }
            if await self.chatBridge.checkSignedIn() == false {
                self.reportSignedOut()
                return
            }
            self.reallySubmit(text)
        }
    }

    /// Tells the user the one thing they need to know, and puts the login page
    /// in front of them so it is one click to fix.
    private func reportSignedOut() {
        isAwaitingChatResponse = false
        chatTimeoutWork?.cancel()
        characterEngine.request(.confused, force: true)
        characterEngine.bark(
            DialogueLibrary.shared.line("chat.signedOut")
                ?? "I'M NOT SIGNED IN OVER HERE. OPENING THE LOGIN — SORT IT OUT.",
            importance: .always
        )
        if let screen = panel.screen ?? NSScreen.main {
            chatBubble.showResponse(
                "I have my own browser, and it isn't signed in to ChatGPT. Log in in the window I just opened — once is enough.",
                near: panel.frame, on: screen
            )
        }
        openFullChat?()
    }

    /// Set by `AppDelegate` — brings the full chat panel up so the user can
    /// actually sign in.
    var openFullChat: (() -> Void)?
    /// Set by `AppDelegate` — the latest weather pull as a blurb, folded
    /// into the first chat message of each session alongside the
    /// recent-activity summary (both the user's explicit "relevant
    /// commentary" asks).
    var weatherBlurbProvider: (() -> String?)?

    private func reallySubmit(_ text: String) {
        isAwaitingChatResponse = true
        beginAwaitingChatResponse?()
        characterEngine.request(.thinking, force: true)
        chatBridge.send(contextualized(text))
        if let screen = panel.screen ?? NSScreen.main {
            chatBubble.showWaiting(near: panel.frame, on: screen)
        }
        scheduleChatWatchdog(elapsed: 0)
    }

    private var hasIncludedActivityContext = false

    /// Folds a short recent-activity summary — and, when a weather pull has
    /// succeeded this session, the current conditions — into the first real
    /// message of each chat *session* (reset in `talkToBill()` every time
    /// the bubble is opened fresh). Enough for ChatGPT's replies to feel
    /// aware of how the Mac's actually being used and what the sky is doing,
    /// without repeating the same context block on every single message
    /// within one sitting.
    private func contextualized(_ text: String) -> String {
        guard !hasIncludedActivityContext else { return text }
        var contextParts: [String] = []
        let summary = memoryStore.recentActivitySummary
        if !summary.isEmpty {
            contextParts.append("I've recently been using this Mac for \(summary)")
        }
        if let weather = weatherBlurbProvider?(), !weather.isEmpty {
            contextParts.append("outside the window, \(weather)")
        }
        guard !contextParts.isEmpty else { return text }
        hasIncludedActivityContext = true
        let context = contextParts.joined(separator: "; ")
        return "[For your context, not to repeat verbatim: \(context).] \(text)"
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

    /// Forces an immediate roaming beat for manual verification — bypasses
    /// the rest delay and the idle-state gate entirely, so it always visibly
    /// moves regardless of what Bill's doing.
    func debugTriggerWander() {
        characterEngine.request(.idle)
        roaming?.triggerNow()
    }

    func show() {
        panel.orderFrontRegardless()
        startRoaming()
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
        performDialogueRefresh(trigger: "daily timer")
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
        performDialogueRefresh(trigger: "menu: Refresh Bill's Context Now")
    }

    /// Kept purely for the debug log window (see `DialogueRefreshLogEntry`'s
    /// doc comment) — capped since this is a debug convenience, not
    /// something meant to grow unbounded over a long-running session.
    /// Observable + persisted, so the log window updates live and survives a
    /// relaunch. See `DialogueRefreshStore` for the three defects this fixes.
    let dialogueRefreshStore = DialogueRefreshStore()

    private var activeRefreshID: UUID?
    private var refreshMarker: String?
    private var refreshWatchdog: DispatchWorkItem?
    /// Generous: a cold chatgpt.com load plus a dozen generated lines can
    /// legitimately take a while. What matters is that it *always* resolves.
    private static let refreshTimeout: TimeInterval = 150

    /// The pools a refresh is allowed to write into. Deliberately a subset —
    /// the ones where an extra line is pure upside. System-critical pools
    /// (study mode, battery warnings) stay fully authored.
    private static let refreshablePools = [
        "coding", "gaming", "browsing", "music", "creative",
        "productivity", "communication", "aiChat", "tinkering", "finder",
    ]

    private func performDialogueRefresh(trigger: String) {
        // Every early return is now recorded. Previously these returned before
        // the log entry was appended, so the log was emptiest exactly when
        // something had gone wrong — which is precisely why it read as broken.
        if isPerformingBackgroundChatWork {
            dialogueRefreshStore.recordImmediateFailure(
                trigger: trigger,
                reason: "A refresh is already in flight. (If this persists, the previous one is stuck — it will time out on its own.)"
            )
            return
        }
        if isAwaitingChatResponse || chatBubble.isVisible {
            dialogueRefreshStore.recordImmediateFailure(
                trigger: trigger, reason: "Skipped: you were mid-conversation with Bill."
            )
            return
        }
        let summary = memoryStore.recentActivitySummary
        if summary.isEmpty {
            dialogueRefreshStore.recordImmediateFailure(
                trigger: trigger,
                reason: "No recent activity to describe yet — open a few recognised apps first."
            )
            return
        }

        let undescribed = Array(memoryStore.undescribedFrequentApps().prefix(Self.maxAppDescriptionsPerRefresh))
        pendingDescriptionRequests = Dictionary(uniqueKeysWithValues: undescribed.map { ($0.name, $0.bundleID) })

        // A per-request marker. The DOM observer that tells us a reply landed
        // fires on *any* mutation, so without this we can consume the previous
        // assistant turn and drop the real answer. Requiring the marker back
        // makes a stale read detectable instead of silent.
        let marker = "BILL-\(Int.random(in: 100000...999999))"
        refreshMarker = marker

        let pools = Self.refreshablePools.joined(separator: ", ")
        let times = "any, morning, midday, afternoon, night"
        var prompt = """
            \(marker)
            Recent activity on this Mac: \(summary).

            Write 12 short Bill-Cipher quips about it, ONE PER LINE, each in \
            exactly this pipe-separated format and nothing else:
            POOL|TIME|LINE

            POOL must be exactly one of: \(pools)
            TIME must be exactly one of: \(times)
            LINE must be under 100 characters, no quotes, no numbering.

            Spread them across at least 4 different POOLs and at least 3 \
            different TIMEs. TIME is when the line makes sense — a "night" line \
            should only work at night. Begin your reply with \(marker) on its \
            own line.
            """
        if !undescribed.isEmpty {
            let names = undescribed.map(\.name).joined(separator: ", ")
            prompt += """
                \n\nThen, one per line, prefixed with "APP:", one short \
                sarcastic-but-informative sentence describing what each of \
                these apps is for, formatted exactly as \
                "APP: <name>: <description>", for: \(names).
                """
        }

        activeRefreshID = dialogueRefreshStore.begin(trigger: trigger, prompt: prompt)
        isPerformingBackgroundChatWork = true
        // Fail fast and legibly when the page is a login wall — otherwise this
        // burns the full 150s watchdog and reports a timeout, which points at
        // the wrong problem entirely.
        Task { @MainActor [weak self] in
            guard let self, self.isPerformingBackgroundChatWork else { return }
            if await self.chatBridge.checkSignedIn() == false {
                self.resolveRefresh(
                    response: nil,
                    failure: "Not signed in. Bill's chat view has its own cookies — open \"Open Full Chat View…\" and log in to ChatGPT there once."
                )
            }
        }

        // Correct order, and the step that was missing entirely.
        //
        // `prepareIfNeeded()` only constructs the `WebPage` model object; its
        // injected scripts do not run until a real `WebView` actually renders
        // it, so on a cold session `window.billSendMessage` was undefined and
        // the send silently did nothing — the menu item genuinely did nothing
        // at all. `warmUpChatEngine` is what mounts that view. And
        // `beginAwaitingChatResponse` has to come *after* `prepareIfNeeded`,
        // because it bails out when `chatBridge.page` is still nil.
        warmUpChatEngine?()
        chatBridge.prepareIfNeeded()
        beginAwaitingChatResponse?()
        chatBridge.sendTask(prompt)

        scheduleRefreshWatchdog()
    }

    /// The background path had no watchdog at all — only the interactive chat
    /// path did. So a refresh that never came back left
    /// `isPerformingBackgroundChatWork` true *forever*, which both blocked
    /// every future refresh and permanently disabled Bill's talking animation
    /// (AppDelegate suppresses it while that flag is set). One failure bricked
    /// the feature for the rest of the session.
    private func scheduleRefreshWatchdog() {
        refreshWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.isPerformingBackgroundChatWork else { return }
                self.resolveRefresh(
                    response: nil,
                    failure: "Timed out after \(Int(Self.refreshTimeout))s with no reply. ChatGPT may not be signed in, or the page never finished loading."
                )
            }
        }
        refreshWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.refreshTimeout, execute: work)
    }

    private func finishDialogueRefresh(_ response: String?) {
        guard let response, !response.isEmpty else {
            resolveRefresh(response: nil, failure: "Empty response.")
            return
        }
        // Stale-reply guard: if our marker isn't in there, this is a different
        // (usually earlier) assistant turn that the DOM observer surfaced.
        // Keep waiting rather than consuming it — the watchdog still bounds it.
        if let marker = refreshMarker, !response.contains(marker) {
            return
        }
        resolveRefresh(response: response, failure: nil)
    }

    /// The single place the in-flight state is cleared, so it cannot leak.
    private func resolveRefresh(response: String?, failure: String?) {
        refreshWatchdog?.cancel()
        refreshWatchdog = nil
        isPerformingBackgroundChatWork = false
        endAwaitingChatResponse?()
        refreshMarker = nil

        let pending = pendingDescriptionRequests
        pendingDescriptionRequests = [:]
        let id = activeRefreshID
        activeRefreshID = nil

        guard let response else {
            if let id {
                dialogueRefreshStore.finish(id, rawResponse: nil, linesAdded: [], descriptions: [], failureReason: failure)
            }
            return
        }

        let parsed = Self.parseRefresh(response, pending: pending)
        for (name, description) in parsed.descriptions {
            if let bundleID = pending[name] {
                memoryStore.setAppDescription(bundleID: bundleID, description)
            }
        }

        if !parsed.pools.isEmpty {
            // Merge into what is already stored rather than replacing, capped
            // per bucket so the generated half cannot grow without bound.
            var merged = memoryStore.generatedPools
            for (key, pool) in parsed.pools {
                var existing = merged[key] ?? DialoguePool()
                existing.merge(pool, cappingBucketsAt: 12)
                merged[key] = existing
            }
            memoryStore.setGeneratedPools(merged)
            DialogueLibrary.shared.setGenerated(merged)
        }

        // Broken into explicit steps: the one-liner form of this took the
        // type checker past its budget.
        var flat: [String] = []
        for (key, pool) in parsed.pools {
            var lines: [String] = pool.any
            lines.append(contentsOf: pool.morning)
            lines.append(contentsOf: pool.midday)
            lines.append(contentsOf: pool.afternoon)
            lines.append(contentsOf: pool.night)
            for line in lines {
                flat.append(key + ": " + line)
            }
        }
        let descriptions = parsed.descriptions.map {
            DialogueRefreshLogEntry.AppDescription(name: $0.key, description: $0.value)
        }
        let reason = (flat.isEmpty && descriptions.isEmpty)
            ? "Reply received but nothing matched the POOL|TIME|LINE format."
            : nil
        if let id {
            dialogueRefreshStore.finish(id, rawResponse: response, linesAdded: flat, descriptions: descriptions, failureReason: reason)
        }
    }

    /// Strict parser for the tagged format.
    ///
    /// The old one accepted *any* non-`APP:` line as dialogue, so a
    /// conversational preamble ("Sure! Here are six quips:") was stored and
    /// later spoken as though Bill had written it. This one requires the
    /// pipe-separated shape and validates both fields, so anything
    /// conversational is simply not matched.
    static func parseRefresh(
        _ response: String,
        pending: [String: String]
    ) -> (pools: [String: DialoguePool], descriptions: [String: String]) {
        var pools: [String: DialoguePool] = [:]
        var descriptions: [String: String] = [:]
        var seen = Set<String>()
        let validPools = Set(refreshablePools)
        let validTimes = Set(TimeOfDay.allCases.map(\.rawValue) + ["any"])

        for raw in response.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("APP:") {
                let after = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
                guard let sep = after.range(of: ":") else { continue }
                let name = String(after[..<sep.lowerBound]).trimmingCharacters(in: .whitespaces)
                let text = String(after[sep.upperBound...]).trimmingCharacters(in: .whitespaces)
                guard pending[name] != nil, !text.isEmpty, text.count <= 160 else { continue }
                descriptions[name] = text
                continue
            }

            let parts = line.components(separatedBy: "|")
            guard parts.count >= 3 else { continue }
            let pool = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let time = parts[1].trimmingCharacters(in: .whitespaces).lowercased()
            let text = parts[2...].joined(separator: "|").trimmingCharacters(in: .whitespaces)
            guard validPools.contains(pool), validTimes.contains(time) else { continue }
            guard !text.isEmpty, text.count <= 120 else { continue }
            let key = "\(pool)|\(time)|\(text.lowercased())"
            guard seen.insert(key).inserted else { continue }

            var entry = pools[pool] ?? DialoguePool()
            switch time {
            case "morning":   entry.morning.append(text)
            case "midday":    entry.midday.append(text)
            case "afternoon": entry.afternoon.append(text)
            case "night":     entry.night.append(text)
            default:          entry.any.append(text)
            }
            pools[pool] = entry
        }
        return (pools, descriptions)
    }

    /// Being clicked. Escalates: prodding him repeatedly should get a
    /// different response than the first tap.
    private func handleClick() {
        pokeCount += 1
        if Date().timeIntervalSince(lastPokeAt) > 25 { pokeCount = 1 }
        lastPokeAt = Date()
        let states: [BillState] = pokeCount >= 5 ? [.rampaging, .meltdown, .grumpEyes, .shadowHands]
                                : pokeCount >= 3 ? [.annoyed, .huffy, .grumpEyes]
                                                 : [.poked, .surprised, .flinching, .dazed]
        if let state = characterEngine.coverage.pick(from: states) {
            characterEngine.request(state, force: true)
        }
        let key = pokeCount >= 5 ? "poked.furious" : pokeCount >= 3 ? "poked.annoyed" : "poked"
        characterEngine.bark(DialogueLibrary.shared.line(key) ?? "", importance: .always)
    }

    /// Coalesces the burst of move notifications a roaming beat produces —
    /// re-laying out the bubble 60 times a second would be absurd.
    private var bubbleFollowWork: DispatchWorkItem?

    private func followBubbleToBill() {
        guard chatBubble.isVisible else { return }
        bubbleFollowWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.chatBubble.isVisible,
                      let screen = self.panel.screen ?? NSScreen.main else { return }
                self.chatBubble.reanchor(near: self.panel.frame, on: screen)
            }
        }
        bubbleFollowWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private var pokeCount = 0
    private var lastPokeAt = Date.distantPast

    private func handleDragStarted() {
        // The simulation must not fight the user for the window's position.
        roaming?.suspend()
        characterEngine.request(.surprised, force: true)
        characterEngine.bark(DialogueLibrary.shared.line("grabbed") ?? "")
    }

    private func handleDragEnded() {
        // `.dazed` exists specifically as "a brief post-surprise recovery
        // beat" (see its doc comment in `BillState`) but had no caller
        // anywhere — being picked up and dropped is exactly that moment,
        // and it settles back to idle on its own afterward since it's a
        // one-shot state.
        characterEngine.request(.dazed, force: true)
        characterEngine.bark(DialogueLibrary.shared.line("dropped") ?? "")
        // Dropped mid-air, Bill should fall to whatever is beneath him rather
        // than hang there — resuming re-seeds the simulation from wherever the
        // user actually let go, and gravity takes it from there.
        roaming?.resume()
    }

    // MARK: - Desktop roaming

    /// Bill roams the desktop under gravity rather than sliding along one
    /// fixed Y: he walks, crouches, leaps onto the top edges of real
    /// application windows, catches their sides on the way past, climbs, and
    /// drops back to the floor. See `RoamingController` for the behaviour
    /// layer, `GravitySimulator` for the physics, and `WindowTopology` for
    /// where the platforms come from.
    ///
    /// This replaces the previous `beginWanderBeat`/`performWanderLeg` pair,
    /// which animated `panel.animator().setFrame` horizontally between two
    /// points at a constant height. That version also clamped against
    /// `NSScreen.main` (the screen of whatever app the *user* is in, not the
    /// one Bill is on) and against `hitRegion`, whose lower edge sits ~20pt
    /// above Bill's actual feet — so he could stand visibly inside the Dock.
    /// Both are fixed here: the simulation resolves Bill's own screen, and
    /// clamps to real feet geometry.
    private(set) var roaming: RoamingController?

    private func startRoaming() {
        let controller = RoamingController(
            panel: panel,
            characterEngine: characterEngine,
            preferences: preferences
        )
        controller.onEvent = { [weak self] event in self?.handleRoamEvent(event) }
        roaming = controller
        controller.start()

        // The window layout Bill navigates changes whenever the user switches
        // apps or reconfigures displays. Both are push notifications, so the
        // topology cache is refreshed exactly when it is actually stale
        // rather than on a poll.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak controller] _ in
            Task { @MainActor in controller?.invalidateTopology() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak controller] _ in
            Task { @MainActor in controller?.invalidateTopology() }
        }
    }

    /// Sends Bill to physically stand on the frontmost window of `pid` — used
    /// so a reaction to an app happens *at* that app rather than wherever he
    /// happened to be standing.
    @discardableResult
    func sendBillToApp(pid: pid_t) -> Bool {
        roaming?.goToApp(pid: pid) ?? false
    }

    private func handleRoamEvent(_ event: RoamEvent) {
        switch event {
        case .landed(let hard, let fromHeight):
            // Only a genuinely long drop is worth remarking on; every routine
            // hop would be chatter, which is exactly what we are removing.
            if hard, fromHeight > 260 {
                characterEngine.bark(BarkLines.random(from: BarkLines.roamHardLanding))
            }
        case .grabbedLedge:
            characterEngine.bark(BarkLines.random(from: BarkLines.roamLedgeGrab))
        case .fellOffWorld:
            characterEngine.bark(BarkLines.random(from: BarkLines.roamFellOffWorld))
        case .shoved:
            characterEngine.bark(BarkLines.random(from: BarkLines.roamShoved))
        case .bonkedHead, .walkedOffEdge, .reachedGoal:
            break
        }
    }


    // MARK: - Cursor awareness (removed)
    //
    // A 2.5s poll used to check whether the cursor was lingering near Bill
    // and, on a 50/50 roll behind a 100s cooldown, emit a `noticesCursor`
    // line. That was the fourth and last source of non-contextual chatter —
    // "the mouse is near me" is not something happening on the machine, it is
    // just proximity — so it has been deleted along with its timer rather
    // than left running silently. Net effect: one fewer always-on wakeup
    // source, and Bill only ever speaks about things that actually happened.


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
    /// Near Bill, where the answer can actually change, and 100ms of latency
    /// on a binary pass-through toggle is imperceptible.
    private static let clickThroughNearInterval: TimeInterval = 0.1
    /// Far from Bill the answer is "pass everything through" and cannot flip
    /// without the cursor first crossing `clickThroughNearRadius` — so polling
    /// ten times a second there is pure waste. This is now the *usual* rate,
    /// since the cursor is far from Bill the overwhelming majority of the time.
    private static let clickThroughFarInterval: TimeInterval = 0.4
    /// How close counts as "near". Generously larger than the fast interval's
    /// worst-case cursor travel (a very fast flick is ~2000pt/s, i.e. ~200pt
    /// in one far-tick), so the cursor cannot cross the whole band and reach
    /// Bill between two slow ticks without at least one landing inside it.
    private static let clickThroughNearRadius: CGFloat = 260
    private var isClickThroughFast = false

    private func startClickThroughTracking() {
        scheduleClickThrough(fast: false)
    }

    private func scheduleClickThrough(fast: Bool) {
        clickThroughTimer?.invalidate()
        isClickThroughFast = fast
        let interval = fast ? Self.clickThroughNearInterval : Self.clickThroughFarInterval
        clickThroughTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
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
        let cursor = NSEvent.mouseLocation
        panel.ignoresMouseEvents = !hitRegionOnScreen.contains(cursor)

        // Step the poll rate to match how close the cursor actually is.
        let shouldBeFast = hitRegionOnScreen
            .insetBy(dx: -Self.clickThroughNearRadius, dy: -Self.clickThroughNearRadius)
            .contains(cursor)
        if shouldBeFast != isClickThroughFast {
            scheduleClickThrough(fast: shouldBeFast)
        }
    }
}
