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
    private var holdWork: DispatchWorkItem?
    private static let actionKey = "billClip"

    private var barkQueue: [String] = []
    private var isBarkShowing = false
    /// Every queued line is guaranteed at least this long on screen.
    private static let minimumBarkDisplay: TimeInterval = 1.9
    /// Beyond this the backlog is dropped oldest-first — a burst of events
    /// should not commit Bill to half a minute of monologue.
    private static let maxQueuedBarks = 3

    private var barkNode: SKNode?
    private var barkDismissWork: DispatchWorkItem?

    // Clip animation and the bark bubble are independent activity sources —
    // either alone (or both) should keep the view unpaused, and the view
    // should only re-pause once *both* have settled.
    private var isClipActive = false
    private var isBarkActive = false

    /// `true` when Bill needs the full frame rate, `false` when only the
    /// ambient idle bob is running.
    ///
    /// This replaces a pause signal that could never fire. The original design
    /// paused the `SKView` entirely while idle, but `setClipActive(false)` was
    /// never called anywhere, so `isPaused` went false on the first clip and
    /// stayed false for the whole session. Even if it had been called, ambient
    /// idle deliberately animates forever (Bill must never freeze), so pausing
    /// was never actually reachable. Dropping the frame rate instead is the
    /// win that was intended: idle is the overwhelming majority of the runtime
    /// and its content changes ~6.7 times a second, so rendering it at 30fps
    /// was roughly double what it needed.
    var onActivityChanged: ((Bool) -> Void)?
    /// Called every time a clip actually begins playing, with the state that
    /// started it. `CharacterEngine` wires this to `AnimationCoverage`.
    var onClipStarted: ((BillState) -> Void)?
    /// Fires when a speech bubble appears/disappears, so the host window can
    /// grow to make room for it and shrink back afterwards.
    var onBarkVisibilityChanged: ((Bool) -> Void)?

    init(rig: BillRigNode) {
        self.rig = rig
        equipProp(.none)
        // Ambient idle isn't kicked off here: `onActivityChanged` isn't
        // wired up by the host view yet at construction time (that happens
        // in `CharacterWindowController.init`, which runs after this), so
        // the resulting activity signal would fire into a nil closure and
        // be silently lost, leaving the view paused despite the bob action
        // technically running. `CharacterEngine.start()` — called once
        // everything is connected — starts it instead.
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
            // Resume the continuous idle bob rather than going fully static
            // — a variant beat is a brief interruption of ambient idle, not
            // a reason to freeze afterward.
            self?.startAmbientIdle()
        }
    }

    /// Starts (or resumes) Bill's continuous idle bob — see
    /// `AnimationClipLibrary.idle`'s doc comment for why this must never
    /// simply stop and leave him static. Safe to call repeatedly; each call
    /// just re-runs the same looping action under the same key.
    private func startAmbientIdle() {
        runClip(AnimationClipLibrary.idle, completion: nil)
        // `runClip` has just flagged the clip active; ambient idle is the one
        // clip that does NOT need the full frame rate, so step straight back
        // down. This is the only place the low-rate edge is produced.
        setAmbientOnly()
    }

    /// Queues a short-lived speech bubble above Bill's head. Independent of
    /// `currentState` — a bark can show up whether Bill's idle, coding,
    /// celebrating, whatever.
    ///
    /// **Queued, not stomped.** This used to `removeFromParent()` the previous
    /// bubble instantly, with no fade and no minimum on-screen time. Two barks
    /// fired in the same tick — which is routine, e.g. opening two apps in
    /// quick succession, or a transition line plus the destination app's own
    /// line — meant the first was destroyed before a single frame was drawn,
    /// so it may as well never have been generated. Now each line is
    /// guaranteed `minimumDisplay` on screen before the next one starts.
    func showBark(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        barkQueue.append(trimmed)
        // A hard cap so a burst of events cannot back up half a minute of
        // speech. The *newest* lines win: they describe what just happened.
        if barkQueue.count > Self.maxQueuedBarks {
            barkQueue.removeFirst(barkQueue.count - Self.maxQueuedBarks)
        }
        drainBarkQueue()
    }

    /// Clears anything waiting — used when Bill is interrupted (a drag, a
    /// chat opening) and the backlog is no longer relevant.
    func clearBarkQueue() {
        barkQueue.removeAll()
    }

    private func drainBarkQueue() {
        guard !isBarkShowing, !barkQueue.isEmpty else { return }
        let text = barkQueue.removeFirst()
        isBarkShowing = true
        present(bark: text)
    }

    private func present(bark text: String) {
        // Ask for the room *before* the bubble is measured and placed,
        // otherwise `nudgeBarkOnScreen` clamps it against a window that is
        // about to grow.
        onBarkVisibilityChanged?(true)
        barkNode?.removeFromParent()
        barkDismissWork?.cancel()

        // Wrapped to the on-screen width Bill's window actually has right
        // now (see `availableBarkWidth`) — a bubble that fits where it's
        // going can never be clipped by the window's own edge, which is
        // the "invisible border hides part of the message" failure the
        // old always-full-width bubble produced at screen edges.
        var bubble = BarkBubble.makeNode(text: text, maxWidth: availableBarkWidth())
        bubble.position = CGPoint(x: 0, y: 128)
        bubble.alpha = 0
        bubble.zPosition = 10
        rig.root.addChild(bubble)
        // The bubble sits above Bill but shifts left/right when the
        // centered spot would cross the walkable region's edge — with the
        // tail re-drawn over Bill so the origin visibly changes with the
        // placement (the explicit ask). Rebuilding the bitmap with a tail
        // offset is cheap and only happens when a shift is actually needed.
        bubble = repositionBark(bubble, text: text)
        barkNode = bubble
        nudgeBarkOnScreen(bubble)

        setBarkActive(true)
        bubble.run(.fadeIn(withDuration: 0.2))

        // Long enough to read, and never shorter than `minimumDisplay` even
        // for a two-word line, which is what makes the queue meaningful.
        let displayDuration = max(Self.minimumBarkDisplay, min(6.0, Double(text.count) * 0.045))
        let work = DispatchWorkItem { [weak self, weak bubble] in
            guard let self else { return }
            guard let bubble else {
                self.finishBark()
                return
            }
            bubble.run(.sequence([.fadeOut(withDuration: 0.3), .removeFromParent()])) { [weak self] in
                self?.finishBark()
            }
        }
        barkDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2 + displayDuration, execute: work)
    }

    private func finishBark() {
        isBarkShowing = false
        if barkQueue.isEmpty {
            setBarkActive(false)
            onBarkVisibilityChanged?(false)
        } else {
            drainBarkQueue()
        }
    }

    /// The horizontal room the bark bubble can occupy, in scene points:
    /// the intersection of Bill's (deliberately edge-hanging) window with
    /// the screen's visible frame. The bubble renders *inside* the window
    /// — an SKView clips drawing at its own bounds — so this is the only
    /// width that is both visible and renderable. Falls back to the
    /// historical 220pt when there's no window/screen to measure against
    /// (shouldn't happen in practice; keeps the math total).
    private func availableBarkWidth() -> CGFloat {
        guard
            let scene = rig.root.scene,
            let window = scene.view?.window,
            let visible = (window.screen ?? NSScreen.main)?.visibleFrame
        else { return 220 }
        let minX = max(0, visible.minX - window.frame.minX)
        let maxX = min(scene.frame.width, visible.maxX - window.frame.minX)
        return max(120, maxX - minX)
    }

    /// Shifts a freshly-placed bark bubble horizontally so it stays fully
    /// inside the window's on-screen region, and re-draws its tail so the
    /// tail still points down at Bill rather than at the bubble's own
    /// middle — the bubble's origin visibly changes with the placement
    /// ("sometimes left, sometimes right") while it keeps pointing at him.
    ///
    /// Centered placement is preferred whenever it fits; the shift happens
    /// only toward whichever side actually has the room. Combined with the
    /// width-wrapping in `availableBarkWidth`, this is what makes a bark
    /// impossible to clip no matter where Bill is standing.
    private func repositionBark(_ bubble: SKNode, text: String) -> SKNode {
        guard
            let scene = rig.root.scene,
            let window = scene.view?.window,
            let visible = (window.screen ?? NSScreen.main)?.visibleFrame
        else { return bubble }
        let rigScaleX = abs(rig.root.xScale) != 0 ? abs(rig.root.xScale) : 1

        let localFrame = bubble.calculateAccumulatedFrame()
        let left = scene.convert(CGPoint(x: localFrame.minX, y: 0), from: rig.root).x
        let right = scene.convert(CGPoint(x: localFrame.maxX, y: 0), from: rig.root).x

        let regionMinX = max(0, visible.minX - window.frame.minX)
        let regionMaxX = min(scene.frame.width, visible.maxX - window.frame.minX)

        // Scene points -> rig-local units (bubble.position's space).
        var dx: CGFloat = 0
        if right > regionMaxX {
            dx = regionMaxX - right
        } else if left < regionMinX {
            dx = regionMinX - left
        }
        guard dx != 0 else { return bubble }

        bubble.removeFromParent()
        // Tail offset in bitmap units: the tail must land over Bill, who
        // stays at rig x=0, so in the shifted bitmap's own coordinates it
        // moves by the negated shift. 1 bitmap unit = 1 BarkBubble
        // `effectivePixelScale` of on-screen point (text-size knob included).
        let tailUnits = -dx / rigScaleX / BarkBubble.effectivePixelScale
        let shifted = BarkBubble.makeNode(text: text, maxWidth: availableBarkWidth(), tailOffsetUnits: tailUnits)
        shifted.position = CGPoint(x: bubble.position.x + dx / rigScaleX, y: 128)
        shifted.alpha = bubble.alpha
        shifted.zPosition = 10
        rig.root.addChild(shifted)
        return shifted
    }

    /// Slides a just-placed bark bubble back into the *window's on-screen
    /// region* if Bill is standing somewhere that would push it out.
    ///
    /// Bill's window is much larger than Bill, and it is deliberately
    /// allowed to hang off the screen edges (see `BillPanel`) so that he
    /// himself can reach them — his window's empty margins, not his body,
    /// are what would otherwise collide with the screen bounds. The bubble
    /// lives in those margins. This used to clamp the bubble against the
    /// *screen* frame only, which silently broke at the window's own
    /// edge: the SKView clips drawing at the window bounds, so a wide
    /// bubble nudged sideways to dodge a screen edge crossed the window
    /// edge instead and lost a chunk of its text to an invisible border.
    /// Clamping in scene space against the window∩screen region — after
    /// `present` wrapped the bubble to exactly that region's width —
    /// guarantees every placement is both fully rendered and fully
    /// visible. The bubble would rather overlap Bill (normal comic
    /// framing) than end up unreadable.
    private func nudgeBarkOnScreen(_ bubble: SKNode) {
        guard let scene = rig.root.scene,
              let window = scene.view?.window,
              let visible = (window.screen ?? NSScreen.main)?.visibleFrame
        else { return }

        // `calculateAccumulatedFrame` is in the parent's (rig.root's) space,
        // so convert through the scene to land in window-local points —
        // which, with `.resizeFill`, are exactly scene points.
        let localFrame = bubble.calculateAccumulatedFrame()
        let bottomLeftInScene = scene.convert(CGPoint(x: localFrame.minX, y: localFrame.minY), from: rig.root)
        let topRightInScene = scene.convert(CGPoint(x: localFrame.maxX, y: localFrame.maxY), from: rig.root)

        // The window's on-screen region, in scene points.
        let regionMinX = max(0, visible.minX - window.frame.minX)
        let regionMaxX = min(scene.frame.width, visible.maxX - window.frame.minX)
        let regionMaxY = min(scene.frame.height, visible.maxY - window.frame.minY)

        // Scene points -> rig-local units, since `bubble.position` is
        // expressed in the (scaled) rig's own space.
        let rigScaleX = rig.root.xScale == 0 ? 1 : abs(rig.root.xScale)
        let rigScaleY = rig.root.yScale == 0 ? 1 : abs(rig.root.yScale)

        var dx: CGFloat = 0
        if topRightInScene.x > regionMaxX {
            dx = regionMaxX - topRightInScene.x
        } else if bottomLeftInScene.x < regionMinX {
            dx = regionMinX - bottomLeftInScene.x
        }

        var dy: CGFloat = 0
        if topRightInScene.y > regionMaxY {
            dy = regionMaxY - topRightInScene.y
        }

        guard dx != 0 || dy != 0 else { return }
        bubble.position = CGPoint(
            x: bubble.position.x + dx / rigScaleX,
            // Floored at Bill's own anchor: past that the bubble would be
            // sliding down *below* him, which never buys back any
            // visibility that moving it further could not.
            y: max(0, bubble.position.y + dy / rigScaleY)
        )
    }

    private func play(_ state: BillState) {
        currentState = state
        // Fires for every clip that genuinely starts, whatever requested it —
        // `AnimationCoverage` uses this as its single, unavoidable recording
        // point rather than trying to instrument each of the many call sites
        // that can request a state.
        onClipStarted?(state)
        equipProp(AnimationClipLibrary.prop(for: state))
        applyFX(AnimationClipLibrary.fx(for: state))
        let clip = AnimationClipLibrary.clip(for: state)
        holdWork?.cancel()
        holdWork = nil
        if state.isContinuous {
            runClip(clip, completion: nil)
            // A continuous *reaction* releases itself so it cannot block
            // roaming and idle behaviour forever — see `maxHoldDuration`.
            if let hold = state.maxHoldDuration {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.currentState == state else { return }
                    self.settleToIdle()
                }
                holdWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + hold, execute: work)
            }
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
        setClipActive(true)
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
        holdWork?.cancel()
        holdWork = nil
        pendingWork?.cancel()
        currentState = .idle
        equipProp(.none)
        applyFX(nil)

        for (part, node) in rig.parts {
            node.removeAction(forKey: Self.actionKey)
            let home = rig.homes[part] ?? PartHome()
            let move = SKAction.move(to: CGPoint(x: home.offset.dx, y: home.offset.dy), duration: 0.25)
            let rotate = SKAction.rotate(toAngle: home.rotation, duration: 0.25, shortestUnitArc: true)
            move.timingMode = .easeOut
            rotate.timingMode = .easeOut
            // Deliberately no scale reset here at all (there used to be a
            // `scale(to: 1)`): scale is not a "home transform" concept the
            // way offset/rotation are — nothing in this rig's rest pose
            // needs a scale of exactly `1` (the body's actual rest scale is
            // `BillRigNode.displayScale`, applied once at construction), and
            // a handful of clips (stretch, charging's pulse) already ease
            // their own scale back to neutral as their last keyframe. This
            // reset was firing on every settle regardless, which is what
            // was silently shrinking Bill from displayScale toward 1.0 and
            // (via the sign of that same target) fighting wander's
            // horizontal direction-flip. Scale is now only ever touched by
            // whatever explicitly wants to change it.
            var resetActions = [move, rotate]
            // Whatever clip was playing may have left the body on a
            // non-idle texture (annoyed's frown, a mid-walk-cycle frame,
            // ...) — settling back to idle has to restore the rest frame,
            // not just the transform. `resize: false` since every frame
            // shares one baked canvas size already (see `AnimationClip.
            // textureAction`'s doc comment for why `resize: true` is both
            // unnecessary and actively harmful here).
            if part == .body {
                resetActions.append(SKAction.setTexture(BillSpriteCatalog.restTexture, resize: false))
            }
            node.run(SKAction.group(resetActions), withKey: Self.actionKey)
        }

        setClipActive(true)
        // Once the ease-back-to-rest finishes, hand off to the continuous
        // idle bob rather than going static — see `startAmbientIdle`.
        let work = DispatchWorkItem { [weak self] in self?.startAmbientIdle() }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func setClipActive(_ active: Bool) {
        isClipActive = active
        onActivityChanged?(isClipActive || isBarkActive)
    }

    /// Called once a clip has fully settled back to ambient idle — this is the
    /// `false` edge that never used to exist.
    private func setAmbientOnly() {
        isClipActive = false
        onActivityChanged?(isBarkActive)
    }

    private func setBarkActive(_ active: Bool) {
        isBarkActive = active
        onActivityChanged?(isClipActive || isBarkActive)
    }

    /// Temporary diagnostic for tracking down a leaked-animation bug; not
    /// wired into the real UI, only the debug menu. Safe to delete once the
    /// underlying cause is confirmed fixed.
    func debugDump() {
        func countDescendants(_ node: SKNode) -> Int {
            1 + node.children.reduce(0) { $0 + countDescendants($1) }
        }
        print("=== Bill debug dump ===")
        print("currentState=\(currentState) isClipActive=\(isClipActive) isBarkActive=\(isBarkActive)")
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
