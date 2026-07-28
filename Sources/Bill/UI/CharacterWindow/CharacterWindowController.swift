import AppKit
import SpriteKit

@MainActor
final class CharacterWindowController: NSObject {
    private let panel: NSPanel
    private let skView: SKView
    let characterEngine: CharacterEngine

    init(characterEngine: CharacterEngine) {
        self.characterEngine = characterEngine
        // Taller than Bill's own footprint to leave headroom above his hat
        // for the speech-bubble bark text.
        let size = NSSize(width: 260, height: 360)
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        skView = SKView(frame: NSRect(origin: .zero, size: size))
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
        // M1 placeholder: nothing hit-testable yet (dragging/pickup lands in a later milestone).
        panel.ignoresMouseEvents = true

        skView.allowsTransparency = true
        skView.ignoresSiblingOrder = true
        // Bill is small and simple — 30fps is imperceptible and halves render cost vs 60fps.
        skView.preferredFramesPerSecond = 30

        let scene = BillScene(size: size, characterEngine: characterEngine)
        skView.presentScene(scene)
        panel.contentView = skView

        // Idle Bill has nothing to draw every frame — pause the render loop
        // entirely and only wake it while a clip is actually playing.
        skView.isPaused = true
        characterEngine.stateMachine.onActivityChanged = { [weak skView] isActive in
            skView?.isPaused = !isActive
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
    }
}
