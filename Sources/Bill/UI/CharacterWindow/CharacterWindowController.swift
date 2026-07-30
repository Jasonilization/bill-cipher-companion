import AppKit
import SpriteKit

@MainActor
final class CharacterWindowController: NSObject {
    private let panel: NSPanel
    private let hitView: BillHitTestView
    let characterEngine: CharacterEngine
    private let preferences: AppPreferences
    private let chatBridge: ChatBridge
    private let chatInputPanel = PixelChatInputPanel()
    private var wanderTimer: Timer?
    private var wasWanderingBeforeDrag = false
    private var wasWanderingBeforeChat = false
    private var windowSize: NSSize = .zero
    private var isAwaitingChatResponse = false
    private var chatTimeoutWork: DispatchWorkItem?

    /// A reply longer than this reads as a wall of text in a small speech
    /// bubble rather than a companion-popup aside — the persona preamble
    /// already asks ChatGPT to keep it short, but nothing enforces that on
    /// the far end, so this is a hard backstop.
    private static let maxBarkLength = 280
    /// How long to wait for a reply before assuming the send/extract
    /// pipeline silently failed and recovering Bill back to idle.
    private static let chatTimeout: TimeInterval = 25

    init(characterEngine: CharacterEngine, preferences: AppPreferences, chatBridge: ChatBridge) {
        self.characterEngine = characterEngine
        self.preferences = preferences
        self.chatBridge = chatBridge
        // Taller than Bill's own footprint to leave headroom above his hat
        // for the speech-bubble bark text.
        let size = NSSize(width: 260, height: 360)
        windowSize = size
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
        // The panel itself accepts mouse events now; BillHitTestView's own
        // hitTest is what actually passes clicks through everywhere except
        // Bill's silhouette, so the empty space around him stays click-through.
        panel.ignoresMouseEvents = false

        hitView.allowsTransparency = true
        hitView.ignoresSiblingOrder = true
        // Bill is small and simple — 30fps is imperceptible and halves render cost vs 60fps.
        hitView.preferredFramesPerSecond = 30
        hitView.onClick = { [weak self] in self?.handleClick() }
        hitView.onDragStarted = { [weak self] in self?.handleDragStarted() }
        hitView.onDragEnded = { [weak self] in self?.handleDragEnded() }
        hitView.onRightClick = { [weak self] in self?.talkToBill() }

        let scene = BillScene(size: size, characterEngine: characterEngine)
        hitView.presentScene(scene)
        panel.contentView = hitView

        // Idle Bill has nothing to draw every frame — pause the render loop
        // entirely and only wake it while a clip is actually playing.
        hitView.isPaused = true
        characterEngine.stateMachine.onActivityChanged = { [weak hitView] isActive in
            hitView?.isPaused = !isActive
        }

        if let screen = NSScreen.main {
            let origin = NSPoint(
                x: screen.visibleFrame.maxX - size.width - 24,
                y: screen.visibleFrame.minY + 24
            )
            panel.setFrameOrigin(origin)
        }
    }

    /// Bill *is* the chat interface now: right-click summons a small pixel
    /// input box near him, the typed message goes through the existing
    /// ChatGPT bridge, and the reply comes back in his own speech bubble —
    /// the raw web page is never the primary surface (see `ChatPanelController`,
    /// which stays around only as an opt-in "full view").
    private func configureChat() {
        chatInputPanel.onSubmit = { [weak self] text in
            self?.handleChatSubmit(text)
        }
        chatInputPanel.onDismiss = { [weak self] in
            guard let self, wasWanderingBeforeChat else { return }
            wasWanderingBeforeChat = false
            scheduleNextWander()
        }
        chatBridge.onResponseReceived = { [weak self] response in
            self?.handleChatResponse(response)
        }
    }

    /// Summons the pixel chat input near Bill — the primary way to talk to
    /// him, reachable via right-click, the global hotkey, or the menu bar.
    /// Reopening while it's already up just closes it, so the hotkey also
    /// works as a toggle.
    func talkToBill() {
        if chatInputPanel.isVisible {
            chatInputPanel.hide()
            return
        }
        guard !isAwaitingChatResponse else {
            characterEngine.bark(BarkLines.random(from: BarkLines.stillThinking))
            return
        }
        wasWanderingBeforeChat = true
        wanderTimer?.invalidate()
        chatBridge.prepareIfNeeded()

        let frame = panel.frame
        let inputSize = NSSize(width: 220, height: 34)
        let origin = NSPoint(
            x: frame.origin.x + (windowSize.width - inputSize.width) / 2,
            y: frame.origin.y + 232
        )
        chatInputPanel.show(at: origin)
    }

    private func handleChatSubmit(_ text: String) {
        isAwaitingChatResponse = true
        characterEngine.request(.thinking, force: true)
        chatBridge.send(text)

        // chatgpt.com's DOM is a best-effort target (see ChatBridge) — if the
        // send never registers or the reply never gets picked up,
        // `onResponseReceived` simply never fires. Without a backstop Bill
        // would sit in `.thinking` forever and every future right-click
        // would just repeat "still thinking" — the same stuck-forever shape
        // as the earlier `celebrating` loop bug, just reachable from the
        // network instead of an animation clip.
        let work = DispatchWorkItem { [weak self] in
            self?.handleChatResponse(nil)
        }
        chatTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.chatTimeout, execute: work)
    }

    private func handleChatResponse(_ response: String?) {
        chatTimeoutWork?.cancel()
        chatTimeoutWork = nil
        isAwaitingChatResponse = false
        characterEngine.request(.idle)
        guard let response, !response.isEmpty else {
            characterEngine.bark(BarkLines.random(from: BarkLines.chatFailed))
            return
        }
        let trimmed = response.count > Self.maxBarkLength
            ? String(response.prefix(Self.maxBarkLength)) + "…"
            : response
        characterEngine.bark(trimmed)
    }

    func show() {
        panel.orderFrontRegardless()
        scheduleNextWander()
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
        characterEngine.request(.idle)
        if wasWanderingBeforeDrag {
            scheduleNextWander()
        }
    }

    /// Bill occasionally wanders a short distance across the screen while
    /// idle — otherwise "roaming" is a settings toggle with nothing behind
    /// it. Only ever fires from genuine idle, and only while roaming is on.
    private func scheduleNextWander() {
        wanderTimer?.invalidate()
        let delay = Double.random(in: 45...100)
        wanderTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.performWander() }
        }
    }

    private func performWander() {
        defer { scheduleNextWander() }
        guard preferences.isRoamingEnabled,
              characterEngine.stateMachine.currentState == .idle,
              let screen = NSScreen.main
        else { return }

        characterEngine.request(.walking)

        let currentOrigin = panel.frame.origin
        let deltaX = CGFloat.random(in: -160...160)
        let minX = screen.visibleFrame.minX
        let maxX = screen.visibleFrame.maxX - panel.frame.width
        let newX = min(max(currentOrigin.x + deltaX, minX), maxX)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 1.8
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrameOrigin(NSPoint(x: newX, y: currentOrigin.y))
        } completionHandler: { [weak self] in
            Task { @MainActor in
                self?.characterEngine.request(.idle)
            }
        }
    }
}
