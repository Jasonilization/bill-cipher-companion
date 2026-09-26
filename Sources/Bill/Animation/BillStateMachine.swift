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
    /// Directional barks: before placing, the state machine picks a side
    /// (or below) from screen room and calls this so the character window
    /// can grow that one side — the bubble renders inside the window, so
    /// a bubble beside Bill physically needs the window widened. The
    /// controller grows the panel synchronously and adjusts the roaming
    /// feet inset when growing left.
    var onBarkCanvasWiden: ((_ side: Bool, _ growthScreenPt: CGFloat) -> Void)?

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
        // otherwise the placement pass clamps against a window that is about
        // to grow.
        onBarkVisibilityChanged?(true)
        barkNode?.removeFromParent()
        barkDismissWork?.cancel()

        // Directional placement — the explicit ask: the bubble sits
        // directly left or right of Bill, or below him, whichever the
        // on-screen region has room for, with the outlined tail pointing
        // at him from whichever edge faces him. Above-his-head is the last
        // resort, not the default.
        //
        // The engine measures the region first, builds the bubble for the
        // chosen edge, and positions it in one pass. The pre-measure picks
        // the side from SCREEN room (the window itself is only as wide as
        // Bill, so side room inside the window is zero until it's widened),
        // asks the host to widen the window that one side, then places.
        preWidenCanvasForSideBark()
        let (bubble, home) = makeDirectionalBark(text: text)
        barkNode = bubble
        barkHome = home

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
    // MARK: - Directional bark placement
    //
    // The explicit ask, finally implemented as meant: the bubble sits
    // directly left or right of Bill, or below him — comic-panel framing
    // around the character — with the outlined tail pointing at him from
    // whichever edge faces him. Above-his-head is the last resort when
    // the region has no room on either side or below (e.g. Bill parked at
    // a bottom corner).

    /// The bubble's placed rig-space center — reclamps always recompute
    /// from this rather than accumulating, so dragging Bill can never
    /// leave the bubble drifted somewhere it wasn't placed.
    private var barkHome: CGPoint = .zero

    /// The window∩screen region in *scene* points, the one true
    /// coordinate space for placement math. `calculateAccumulatedFrame()`
    /// already returns scene-space rects — the old code converted them
    /// *again* through the rig, double-applying the scale and anchor,
    /// which is precisely why the bubble sat high and the directional
    /// shift misfired.
    private var barkRegionScene: CGRect? {
        guard
            let scene = rig.root.scene,
            let window = scene.view?.window,
            let visible = (window.screen ?? NSScreen.main)?.visibleFrame
        else { return nil }
        let minX = max(0, visible.minX - window.frame.minX)
        let minY = max(0, visible.minY - window.frame.minY)
        let maxX = min(scene.frame.width, visible.maxX - window.frame.minX)
        let maxY = min(scene.frame.height, visible.maxY - window.frame.minY)
        guard maxX > minX, maxY > minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The region mapped into rig space (the space bubble positions live
    /// in): scene → rig via the rig root's position and scale.
    private var barkRegionRig: CGRect? {
        guard let region = barkRegionScene else { return nil }
        let sx = rig.root.xScale == 0 ? 1 : abs(rig.root.xScale)
        let sy = rig.root.yScale == 0 ? 1 : abs(rig.root.yScale)
        let origin = rig.root.position
        return CGRect(
            x: (region.minX - origin.x) / sx,
            y: (region.minY - origin.y) / sy,
            width: region.width / sx,
            height: region.height / sy
        )
    }

    /// Bill's half-extents in rig space, from the body node's own frame —
    /// exact and FX-independent.
    private var bodyHalfWidth: CGFloat { rig.bodyNode.size.width / 2 }
    private var bodyHalfHeight: CGFloat { rig.bodyNode.size.height / 2 }
    /// Rig-space y of roughly his eye — side bubbles center on it so
    /// they read as speaking toward his face.
    private var eyeLevelY: CGFloat { bodyHalfHeight * 0.45 }
    /// The gap between the tail tip and Bill, in rig units.
    private static let barkGap: CGFloat = 4
    /// Tail length in rig points (3 bitmap units × effective pixel scale).
    private var barkTailLength: CGFloat {
        3 * BarkBubble.effectivePixelScale
    }

    /// Builds and places the bark bubble for the room actually available,
    /// choosing the edge by preference: roomier side → other side →
    /// below → above. Returns the node (already added to the rig) and the
    /// home center for the re-clamp contract.
    private func makeDirectionalBark(text: String) -> (SKNode, CGPoint) {
        // Pre-wrapped widths are measured against the *full* region so the
        // wrap budgets below stay honest.
        func regionWidth() -> CGFloat {
            guard let region = barkRegionRig else { return 220 }
            return max(120, region.width)
        }
        func aboveRoom() -> CGFloat {
            guard let region = barkRegionRig else { return 340 }
            return max(60, region.maxY)
        }

        let fallback: (SKNode, CGPoint) = {
            let bubble = BarkBubble.makeNode(
                text: text, maxWidth: regionWidth(),
                maxHeight: aboveRoom(), tailEdge: .above
            )
            bubble.alpha = 0
            bubble.zPosition = 10
            let home = CGPoint(
                x: 0,
                y: bodyHalfHeight + Self.barkGap + barkTailLength
                    + bubble.frame.height / 2
            )
            bubble.position = home
            rig.root.addChild(bubble)
            return (bubble, home)
        }()

        guard let region = barkRegionRig else { return fallback }

        let tail = barkTailLength
        let gap = Self.barkGap
        let sideMinWidth: CGFloat = 108

        // Room on each side, measured from his body edge to the region.
        let roomRight = region.maxX - (bodyHalfWidth + gap + tail)
        let roomLeft = (0 - bodyHalfWidth - gap - tail) - region.minX
        let roomBelow = (0 - bodyHalfHeight - gap - tail) - region.minY
        let roomAbove = region.maxY - (bodyHalfHeight + gap + tail)

        func sideBubble(right: Bool) -> (SKNode, CGPoint)? {
            let room = right ? roomRight : roomLeft
            guard room >= sideMinWidth else { return nil }
            let edge: BarkBubble.TailEdge = right ? .leftSide : .rightSide
            let bubble = BarkBubble.makeNode(
                text: text,
                maxWidth: room,
                maxHeight: aboveRoom(),
                tailEdge: edge
            )
            bubble.alpha = 0
            bubble.zPosition = 10
            let halfW = bubble.frame.width / 2
            let x = right
                ? bodyHalfWidth + gap + tail + halfW
                : -(bodyHalfWidth + gap + tail + halfW)
            var home = CGPoint(x: x, y: eyeLevelY)
            // Keep the bubble inside the region vertically; the tail
            // offset keeps pointing at his eye level when clamped.
            let halfH = bubble.frame.height / 2
            var tailOffset: CGFloat = 0
            if home.y - halfH < region.minY {
                home.y = region.minY + halfH
                tailOffset = (eyeLevelY - home.y) / BarkBubble.effectivePixelScale
            } else if home.y + halfH > region.maxY {
                home.y = region.maxY - halfH
                tailOffset = (eyeLevelY - home.y) / BarkBubble.effectivePixelScale
            }
            if tailOffset != 0 {
                bubble.removeFromParent()
                let rebuilt = BarkBubble.makeNode(
                    text: text,
                    maxWidth: room,
                    maxHeight: aboveRoom(),
                    tailEdge: edge,
                    tailOffsetUnits: tailOffset
                )
                rebuilt.alpha = 0
                rebuilt.zPosition = 10
                rebuilt.position = home
                rig.root.addChild(rebuilt)
                return (rebuilt, home)
            }
            bubble.position = home
            rig.root.addChild(bubble)
            return (bubble, home)
        }

        func belowBubble() -> (SKNode, CGPoint)? {
            guard roomBelow >= 80 else { return nil }
            let bubble = BarkBubble.makeNode(
                text: text,
                maxWidth: regionWidth(),
                maxHeight: roomBelow,
                tailEdge: .below
            )
            bubble.alpha = 0
            bubble.zPosition = 10
            let halfH = bubble.frame.height / 2
            let home = CGPoint(
                x: 0,
                y: -(bodyHalfHeight + gap + tail + halfH)
            )
            bubble.position = home
            rig.root.addChild(bubble)
            return (bubble, home)
        }

        // Preference: the roomier side first, then the other side, then
        // below, then above.
        if roomRight >= roomLeft, let placed = sideBubble(right: true) {
            return placed
        }
        if let placed = sideBubble(right: false) {
            return placed
        }
        if let placed = belowBubble() {
            return placed
        }
        if roomAbove <= 40 {
            return fallback
        }
        // Above: the last resort, height-capped to the room actually
        // there, tail tracking Bill if clamped sideways.
        let bubble = BarkBubble.makeNode(
            text: text,
            maxWidth: regionWidth(),
            maxHeight: roomAbove,
            tailEdge: .above
        )
        bubble.alpha = 0
        bubble.zPosition = 10
        let halfW = bubble.frame.width / 2
        var home = CGPoint(
            x: 0,
            y: bodyHalfHeight + gap + tail + bubble.frame.height / 2
        )
        var tailOffset: CGFloat = 0
        if home.x - halfW < region.minX {
            home.x = region.minX + halfW
            tailOffset = -home.x / BarkBubble.effectivePixelScale
        } else if home.x + halfW > region.maxX {
            home.x = region.maxX - halfW
            tailOffset = -home.x / BarkBubble.effectivePixelScale
        }
        if tailOffset != 0 {
            bubble.removeFromParent()
            let rebuilt = BarkBubble.makeNode(
                text: text,
                maxWidth: regionWidth(),
                maxHeight: roomAbove,
                tailEdge: .above,
                tailOffsetUnits: tailOffset
            )
            rebuilt.alpha = 0
            rebuilt.zPosition = 10
            rebuilt.position = home
            rig.root.addChild(rebuilt)
            return (rebuilt, home)
        }
        bubble.position = home
        rig.root.addChild(bubble)
        return (bubble, home)
    }


    /// Picks the bark side from SCREEN room and asks the host to widen the
    /// character window on that one side — the bubble renders inside the
    /// window, so "directly left/right of Bill" is physically impossible in
    /// the base window that is exactly as wide as him. Growth is capped to
    /// the screen space actually available. Below/above barks need no
    /// widening.
    private func preWidenCanvasForSideBark() {
        guard
            let scene = rig.root.scene,
            let window = scene.view?.window,
            let visible = (window.screen ?? NSScreen.main)?.visibleFrame
        else { return }
        let s = rig.root.xScale == 0 ? 1 : abs(rig.root.xScale)

        // Bill's screen-space edges (rig extents × scale, window centers him).
        let center = window.frame.midX
        let billRight = center + bodyHalfWidth * s
        let billLeft = center - bodyHalfWidth * s
        let lead = (Self.barkGap + barkTailLength) * s

        let roomRightScreen = visible.maxX - billRight - lead
        let roomLeftScreen = billLeft - visible.minX - lead
        guard roomRightScreen > 54 || roomLeftScreen > 54 else { return }

        let rightPreferred = roomRightScreen >= roomLeftScreen
        let roomScreen = rightPreferred ? roomRightScreen : roomLeftScreen
        // Cap the side bubble to a comfortable max (~300 rig points) and
        // to whatever screen room exists.
        let bubbleRig = min(300, roomScreen / s)
        guard bubbleRig >= 108 else { return }

        // How far past the window's edge on the chosen side the bubble
        // must reach.
        let windowEdge = rightPreferred ? window.frame.maxX : window.frame.minX
        let edgeDistance = rightPreferred
            ? windowEdge - billRight
            : billLeft - windowEdge
        let neededScreen = bubbleRig * s + lead - edgeDistance + 8
        guard neededScreen > 0 else { return }
        onBarkCanvasWiden?(rightPreferred, neededScreen)
    }

    /// Keeps a *showing* bark inside the region as Bill moves — the cheap
    /// per-move half of placement (no bitmap rebuild). Always recomputed
    /// from the placed home center, never by accumulating increments: a
    /// bubble clamped at a screen edge returns to its home placement the
    /// moment Bill is back in open space — it can never be "pushed" and
    /// left somewhere.
    func reclampVisibleBark() {
        guard
            let bubble = barkNode,
            let region = barkRegionScene
        else { return }
        let sx = rig.root.xScale == 0 ? 1 : abs(rig.root.xScale)
        let sy = rig.root.yScale == 0 ? 1 : abs(rig.root.yScale)

        // The frame *as if at home* — clamps are computed against the
        // home placement, not the current (possibly already-clamped) one.
        let frame = bubble.calculateAccumulatedFrame()
        let homeFrame = frame.offsetBy(
            dx: (barkHome.x - bubble.position.x) * sx,
            dy: (barkHome.y - bubble.position.y) * sy
        )

        var dx: CGFloat = 0
        if homeFrame.maxX > region.maxX {
            dx = region.maxX - homeFrame.maxX
        } else if homeFrame.minX < region.minX {
            dx = region.minX - homeFrame.minX
        }
        var dy: CGFloat = 0
        if homeFrame.maxY > region.maxY {
            dy = region.maxY - homeFrame.maxY
        } else if homeFrame.minY < region.minY {
            dy = region.minY - homeFrame.minY
        }

        let target = CGPoint(
            x: barkHome.x + dx / sx,
            y: barkHome.y + dy / sy
        )
        if bubble.position != target {
            bubble.position = target
        }
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
