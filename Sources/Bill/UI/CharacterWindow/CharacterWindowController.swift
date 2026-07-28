import AppKit
import SpriteKit

@MainActor
final class CharacterWindowController: NSObject {
    private let panel: NSPanel
    private let hitView: BillHitTestView
    let characterEngine: CharacterEngine
    private let preferences: AppPreferences
    private var wanderTimer: Timer?
    private var wasWanderingBeforeDrag = false

    init(characterEngine: CharacterEngine, preferences: AppPreferences) {
        self.characterEngine = characterEngine
        self.preferences = preferences
        // Taller than Bill's own footprint to leave headroom above his hat
        // for the speech-bubble bark text.
        let size = NSSize(width: 260, height: 360)
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        hitView = BillHitTestView(frame: NSRect(origin: .zero, size: size))
        super.init()
        configure(size: size)
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

    func show() {
        panel.orderFrontRegardless()
        scheduleNextWander()
    }

    private func handleClick() {
        characterEngine.request([.surprised, .happy, .annoyed].randomElement()!, force: true)
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
