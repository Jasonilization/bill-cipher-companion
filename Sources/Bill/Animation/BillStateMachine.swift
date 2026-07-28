import SpriteKit

/// Drives Bill's rig: turns `BillState` requests into running `SKAction`s,
/// handles priority-based interruption, swaps props/FX, and reports whether
/// anything is actively animating so the host view can pause its render
/// loop the rest of the time. This is the only place that touches SKActions
/// directly — everything else deals in `BillState`/clips.
@MainActor
final class BillStateMachine {
    private(set) var currentState: BillState = .idle
    private let rig: BillRigNode
    private var currentPropNode: SKNode?
    private var currentFXNodes: [SKNode] = []
    private var pendingWork: DispatchWorkItem?
    private static let actionKey = "billClip"

    /// Fires whenever animation starts (`true`) or fully settles (`false`),
    /// so the host `SKView` can be paused/unpaused accordingly.
    var onActivityChanged: ((Bool) -> Void)?

    init(rig: BillRigNode) {
        self.rig = rig
        equipProp(.cane)
    }

    /// Request a state change. Continuous states (walking, talking, sleeping,
    /// gaming, coding, heatingUp, charging) keep running until something else
    /// interrupts them; one-shot beats (happy, annoyed, surprised,
    /// celebrating) settle back to idle on their own.
    func request(_ state: BillState, force: Bool = false) {
        if state == .idle {
            settleToIdle()
            return
        }
        guard force || state.priority >= currentState.priority else { return }
        guard state != currentState else { return }
        play(state)
    }

    /// A short idle-only flourish (blink, look around, stretch) that doesn't
    /// change `currentState` — only valid while genuinely idle.
    func playIdleVariant(_ variant: AnimationClipLibrary.IdleVariant) {
        guard currentState == .idle else { return }
        runClip(variant.clip) { [weak self] in
            self?.onActivityChanged?(false)
        }
    }

    private func play(_ state: BillState) {
        currentState = state
        equipProp(AnimationClipLibrary.prop(for: state))
        applyFX(AnimationClipLibrary.fx(for: state))
        let clip = AnimationClipLibrary.clip(for: state)
        if state.isContinuous {
            runClip(clip, completion: nil)
        } else {
            runClip(clip) { [weak self] in
                self?.settleToIdle()
            }
        }
    }

    private func runClip(_ clip: AnimationClip, completion: (() -> Void)?) {
        pendingWork?.cancel()
        let actions = clip.buildActions(homes: rig.homes)
        guard !actions.isEmpty else {
            completion?()
            return
        }
        onActivityChanged?(true)
        for (part, action) in actions {
            rig.parts[part]?.run(action, withKey: Self.actionKey)
        }
        guard let completion, clip.loop == .once else { return }
        let duration = clip.singlePassDuration
        let work = DispatchWorkItem(block: completion)
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// Stops whatever is playing and eases every part back to its resting
    /// transform. Used both for natural beat completion and forced
    /// interruption, so a part frozen mid-gesture never gets stuck there.
    private func settleToIdle() {
        pendingWork?.cancel()
        currentState = .idle
        equipProp(.cane)
        applyFX(nil)

        for (part, node) in rig.parts {
            node.removeAction(forKey: Self.actionKey)
            let home = rig.homes[part] ?? PartHome()
            let move = SKAction.move(to: CGPoint(x: home.offset.dx, y: home.offset.dy), duration: 0.25)
            let rotate = SKAction.rotate(toAngle: home.rotation, duration: 0.25, shortestUnitArc: true)
            let scale = SKAction.scale(to: 1, duration: 0.25)
            move.timingMode = .easeOut
            rotate.timingMode = .easeOut
            scale.timingMode = .easeOut
            node.run(SKAction.group([move, rotate, scale]), withKey: Self.actionKey)
        }

        onActivityChanged?(true)
        let work = DispatchWorkItem { [weak self] in self?.onActivityChanged?(false) }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Temporary diagnostic for tracking down a leaked-animation bug; not
    /// wired into the real UI, only the debug menu. Safe to delete once the
    /// underlying cause is confirmed fixed.
    func debugDump() {
        func countDescendants(_ node: SKNode) -> Int {
            1 + node.children.reduce(0) { $0 + countDescendants($1) }
        }
        print("=== Bill debug dump ===")
        print("currentState=\(currentState)")
        for part in BillPart.allCases {
            let node = rig.parts[part]
            print("  \(part): hasActions=\(node?.hasActions() ?? false) actionForKey=\(node?.action(forKey: Self.actionKey) != nil)")
        }
        print("currentPropNode children=\(currentPropNode?.children.count ?? -1)")
        print("currentFXNodes count=\(currentFXNodes.count)")
        print("total rig.root descendants=\(countDescendants(rig.root))")
    }

    private func equipProp(_ prop: BillProp) {
        currentPropNode?.removeFromParent()
        currentPropNode = prop.makeNode()
        if let node = currentPropNode {
            rig.rightHandAnchor.addChild(node)
        }
    }

    private func applyFX(_ fx: BillFX?) {
        currentFXNodes.forEach { $0.removeFromParent() }
        currentFXNodes.removeAll()
        guard let fx else { return }

        switch fx {
        case .steam:
            let node = FXLibrary.steam()
            node.position = CGPoint(x: 0, y: 74)
            rig.root.addChild(node)
            currentFXNodes = [node]
        case .sparkle:
            let node = FXLibrary.sparkle()
            node.position = CGPoint(x: 0, y: 10)
            node.numParticlesToEmit = 24
            rig.root.addChild(node)
            currentFXNodes = [node]
        case .zzz:
            let node = FXLibrary.zzz()
            node.position = CGPoint(x: 36, y: 74)
            rig.root.addChild(node)
            currentFXNodes = [node]
        case .confettiAndSparkle:
            let confetti = FXLibrary.confetti()
            confetti.position = CGPoint(x: 0, y: 40)
            rig.root.addChild(confetti)
            let sparkle = FXLibrary.sparkle()
            sparkle.position = CGPoint(x: 0, y: 10)
            sparkle.numParticlesToEmit = 30
            rig.root.addChild(sparkle)
            currentFXNodes = [confetti, sparkle]
        }
    }
}
