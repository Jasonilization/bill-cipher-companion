import Foundation

/// Bill's behavior brain — separate from both the renderer (`Animation/`)
/// and the AI chat system. Decides *when* Bill should be in a given state:
/// idle-variety boredom beats, occasional personality flourishes, and rare
/// Easter eggs while genuinely idle; the system monitor and chat bridge
/// call `request(_:)` the same way for everything else.
@MainActor
final class CharacterEngine {
    let rig: BillRigNode
    let stateMachine: BillStateMachine

    private var idleBeatTimer: Timer?
    private var isRunning = false
    private var lastRareEventDate: Date?

    /// Rare Easter eggs (power surge / zodiac vision / summon ritual / …)
    /// are deliberately dramatic — see `BillState.rareEasterEggs` — so
    /// they're gated to a small chance per idle beat *and* a cooldown,
    /// rather than ever showing up back-to-back.
    private static let rareEventChance = 0.03
    private static let caneFlourishChance = 0.08
    private static let smugChance = 0.12
    private static let ambientBarkChance = 0.18
    private static let rareEventCooldown: TimeInterval = 10 * 60

    init() {
        rig = BillRigNode.build()
        stateMachine = BillStateMachine(rig: rig)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        // Kicks off the continuous idle bob (see `BillStateMachine.init`'s
        // doc comment for why this can't happen at construction time) so
        // Bill is already gently moving before the very first idle beat,
        // rather than sitting frozen for the first 4-9s.
        stateMachine.request(.idle)
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
        defer { scheduleNextIdleBeat() }
        guard stateMachine.currentState == .idle else { return }

        if rollRareEvent() {
            return
        }

        var roll = Double.random(in: 0..<1)

        if roll < Self.caneFlourishChance {
            stateMachine.request(.caneFlourish)
            if Bool.random() {
                stateMachine.showBark(BarkLines.random(from: BarkLines.caneFlourish))
            }
            return
        }
        roll -= Self.caneFlourishChance

        if roll < Self.smugChance {
            stateMachine.request(.smug)
            return
        }
        roll -= Self.smugChance

        if roll < Self.ambientBarkChance {
            stateMachine.showBark(BarkLines.random(from: BarkLines.idleAmbient + BarkLines.mischief))
            return
        }

        let variant = AnimationClipLibrary.IdleVariant.allCases.randomElement()!
        stateMachine.playIdleVariant(variant)
        if variant == .curious, Bool.random() {
            stateMachine.showBark(BarkLines.random(from: BarkLines.curiosity))
        }
    }

    /// Returns `true` if a rare Easter egg fired (caller should skip the
    /// normal idle-variant roll for this beat).
    private func rollRareEvent() -> Bool {
        if let last = lastRareEventDate, Date().timeIntervalSince(last) < Self.rareEventCooldown {
            return false
        }
        guard Double.random(in: 0..<1) < Self.rareEventChance else { return false }

        lastRareEventDate = Date()
        let event = BillState.rareEasterEggs.randomElement()!
        stateMachine.request(event, force: true)
        stateMachine.showBark(BarkLines.random(from: BarkLines.rareEvent(for: event)))
        return true
    }
}
