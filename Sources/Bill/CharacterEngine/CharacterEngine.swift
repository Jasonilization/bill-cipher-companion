import Foundation

/// Bill's behavior brain — separate from both the renderer (`Animation/`)
/// and the AI chat system. Decides *when* Bill should be in a given state:
/// right now that's just idle-variety boredom beats; the system monitor
/// (M3) and chat bridge (M2) will call `request(_:)` the same way.
@MainActor
final class CharacterEngine {
    let rig: BillRigNode
    let stateMachine: BillStateMachine

    private var idleBeatTimer: Timer?
    private var isRunning = false

    init() {
        rig = BillRigNode.build()
        stateMachine = BillStateMachine(rig: rig)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        scheduleNextIdleBeat()
    }

    func stop() {
        isRunning = false
        idleBeatTimer?.invalidate()
        idleBeatTimer = nil
    }

    /// Entry point for reactions: chat bridge, system monitor, debug menu.
    func request(_ state: BillState, force: Bool = false) {
        stateMachine.request(state, force: force)
    }

    /// Shows a bark line above Bill's head without necessarily changing his
    /// animation state — used by the reaction router for ambient commentary.
    func bark(_ text: String) {
        stateMachine.showBark(text)
    }

    private func scheduleNextIdleBeat() {
        idleBeatTimer?.invalidate()
        let delay = Double.random(in: 4...9)
        idleBeatTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.fireIdleBeat()
            }
        }
    }

    private func fireIdleBeat() {
        guard isRunning else { return }
        if stateMachine.currentState == .idle {
            let variant = AnimationClipLibrary.IdleVariant.allCases.randomElement()!
            stateMachine.playIdleVariant(variant)
        }
        scheduleNextIdleBeat()
    }
}
