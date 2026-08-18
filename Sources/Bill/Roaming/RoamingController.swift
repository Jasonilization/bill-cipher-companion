import AppKit
import CoreGraphics

/// Turns `GravitySimulator` + `WindowTopology` into actual behaviour: picks
/// somewhere to go, walks/jumps/climbs there, drives the matching sprite
/// state, and moves the panel each tick.
///
/// **Cost at rest is exactly zero.** The tick timer only exists while a beat
/// is in flight; the moment Bill comes to rest it is invalidated, so a
/// stationary Bill adds no wakeups at all. Beats last a few seconds and are
/// separated by `restInterval`, so the 60Hz tick has a low single-digit duty
/// cycle even while roaming is on.
///
/// Replaces the old `beginWanderBeat`/`performWanderLeg` pair, which could
/// only slide the window horizontally along one fixed Y.
@MainActor
final class RoamingController {

    /// Where Bill is currently trying to get to.
    private enum Goal {
        /// Somewhere along the surface he is already standing on.
        case stroll(x: CGFloat)
        /// Onto the top edge of a specific window.
        case platform(rect: CGRect)
        /// Back down to the screen floor.
        case ground(x: CGFloat)
    }

    /// The step of the plan currently being executed.
    private enum Step {
        case approach(x: CGFloat, running: Bool)
        case crouch(until: Date, target: CGPoint)
        case launch(target: CGPoint)
        case airborne
        case peek(until: Date)
        case climb(direction: CGFloat)
        case settle(until: Date)
        case done
    }

    private let sim = GravitySimulator()
    private weak var panel: NSPanel?
    private let characterEngine: CharacterEngine
    private let preferences: AppPreferences

    private var tick: Timer?
    private var restTimer: Timer?
    private var goal: Goal?
    private var step: Step = .done
    private var lastAppliedState: BillState?
    private var facing: CGFloat = -1
    private var isSuspended = false
    private var beatStartedAt = Date.distantPast

    /// Emitted for anything worth speaking about. `CharacterWindowController`
    /// hooks this up to the bark path so dialogue tracks what Bill is
    /// physically doing.
    var onEvent: ((RoamEvent) -> Void)?

    /// Shared with the solver so the predicted arc and the integrated one
    /// can never disagree.
    private static var tickInterval: TimeInterval { GravitySimulator.timestep }
    /// A beat that has not finished by now is stuck (target window closed,
    /// unreachable geometry, a display change mid-flight) — abandon it rather
    /// than tick forever.
    private static let beatTimeout: TimeInterval = 14
    private static let restInterval: ClosedRange<TimeInterval> = 11...26
    /// Below this the goal is close enough that walking to it reads as
    /// fidgeting rather than travelling.
    private static let arrivalTolerance: CGFloat = 8
    /// Chance a beat targets a real window rather than strolling on the
    /// current surface. Kept high — climbing the desktop is the whole point.
    private static let windowGoalChance = 0.62

    /// Bill's feet sit this far above his window's own bottom edge, and his
    /// centreline this far from its left edge, both at `characterScale == 1`.
    /// Derived from the shared 118x111 sprite canvas (bottom-aligned, zero
    /// bottom gap), `BillRigNode.displayScale` of 1.9, and the rig anchor at
    /// y = 110 — verified against the alpha bounding boxes of the actual PNGs.
    static let feetInsetY: CGFloat = 4.55
    static let centerInsetX: CGFloat = 130

    init(panel: NSPanel, characterEngine: CharacterEngine, preferences: AppPreferences) {
        self.panel = panel
        self.characterEngine = characterEngine
        self.preferences = preferences
    }

    // MARK: - Lifecycle

    func start() {
        scheduleNextBeat()
    }

    func stop() {
        tick?.invalidate(); tick = nil
        restTimer?.invalidate(); restTimer = nil
        step = .done
        goal = nil
    }

    /// Called while the user is dragging Bill, or while chat is open — the
    /// simulation must not fight either of them for the window's position.
    func suspend() {
        isSuspended = true
        tick?.invalidate(); tick = nil
        restTimer?.invalidate(); restTimer = nil
        step = .done
        goal = nil
    }

    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        scheduleNextBeat()
    }

    /// Invalidates the cached window layout. Called when apps activate and
    /// when the display configuration changes.
    func invalidateTopology() {
        WindowTopology.invalidate()
    }

    // MARK: - Public commands

    /// Sends Bill to stand on the frontmost window of `pid`. This is how he
    /// physically "goes to" an app he is about to react to, and how Study
    /// Mode confronts a blocked app.
    @discardableResult
    func goToApp(pid: pid_t) -> Bool {
        guard !isSuspended, preferences.isRoamingEnabled else { return false }
        guard let panel, let target = WindowTopology.frontmostPlatform(
            ownedBy: pid, excludingWindowNumber: panel.windowNumber
        ) else { return false }
        restTimer?.invalidate()
        beginBeat(goal: .platform(rect: target.rect))
        return true
    }

    /// Forces a movement beat immediately, bypassing the rest timer and the
    /// idle-state gate — the debug menu's "Trigger Wander Now".
    func triggerNow() {
        restTimer?.invalidate()
        isSuspended = false
        beginBeat(goal: nil)
    }

    // MARK: - Beat scheduling

    private func scheduleNextBeat() {
        restTimer?.invalidate()
        guard !isSuspended else { return }
        let delay = Double.random(in: Self.restInterval)
        restTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.beginBeat(goal: nil) }
        }
    }

    private func beginBeat(goal explicitGoal: Goal?) {
        guard let panel else { return }
        guard preferences.isRoamingEnabled else { scheduleNextBeat(); return }
        // Only start from genuine rest — never yank Bill out of a reaction,
        // a rare Easter egg, or a chat exchange.
        if explicitGoal == nil {
            let current = characterEngine.stateMachine.currentState
            guard current == .idle || current.isRoamingMotion else { scheduleNextBeat(); return }
        }
        guard let screen = screenForBill() else { scheduleNextBeat(); return }

        buildWorld(on: screen, panel: panel)
        syncSimFromPanel(panel: panel, screen: screen)

        guard let chosen = explicitGoal ?? pickGoal(on: screen, panel: panel) else {
            scheduleNextBeat(); return
        }
        goal = chosen
        beatStartedAt = Date()
        planNextStep()
        startTicking()
    }

    // MARK: - World

    private func screenForBill() -> NSScreen? {
        guard let panel else { return nil }
        // `NSScreen.main` follows the *key window*, i.e. whatever app the user
        // is using — not where Bill is. Using it for clamping is what made the
        // old wander yank him back to display 1 after he was dragged to
        // display 2. Always resolve the screen he is actually on.
        let anchor = feetPosition(panel: panel)
        return NSScreen.screens.first { $0.frame.contains(anchor) }
            ?? panel.screen
            ?? NSScreen.main
    }

    private func buildWorld(on screen: NSScreen, panel: NSPanel) {
        let visible = screen.visibleFrame
        sim.scale = preferences.characterScale
        sim.worldBounds = visible
        sim.solids = WindowTopology
            .platforms(excludingWindowNumber: panel.windowNumber)
            .filter { $0.rect.intersects(visible) }
            .map { RoamSolid(rect: $0.rect) }
    }

    private func pickGoal(on screen: NSScreen, panel: NSPanel) -> Goal? {
        let visible = screen.visibleFrame
        let reachable = sim.solids
            .map(\.rect)
            .filter { rect in
                // Reachable by a direct leap onto the top edge, or by
                // catching the side and climbing.
                let landing = CGPoint(x: rect.midX, y: rect.maxY)
                if sim.solveJump(from: sim.feet, to: landing) != nil { return true }
                return sideGrabTarget(for: rect) != nil
            }

        if !reachable.isEmpty, Double.random(in: 0..<1) < Self.windowGoalChance {
            return .platform(rect: reachable.randomElement()!)
        }
        // Otherwise stroll along whatever he is standing on, or head home.
        if sim.feet.y > visible.minY + 4, Double.random(in: 0..<1) < 0.3 {
            return .ground(x: CGFloat.random(in: visible.minX + 80...visible.maxX - 80))
        }
        let span = CGFloat.random(in: 90...260) * (Bool.random() ? 1 : -1)
        let x = min(max(sim.feet.x + span, visible.minX + 40), visible.maxX - 40)
        return .stroll(x: x)
    }

    // MARK: - Planning

    private func planNextStep() {
        guard let goal else { step = .done; return }
        switch goal {
        case .stroll(let x):
            step = .approach(x: x, running: abs(x - sim.feet.x) > 240)

        case .ground(let x):
            // Walk to the nearest edge of the current surface and drop off.
            step = .peek(until: Date().addingTimeInterval(0.55))
            pendingDropX = x

        case .platform(let rect):
            let landing = CGPoint(x: rect.midX, y: rect.maxY)
            if abs(sim.feet.y - rect.maxY) < 2, abs(sim.feet.x - rect.midX) < Self.arrivalTolerance {
                step = .settle(until: Date().addingTimeInterval(0.3))
                return
            }
            if sim.solveJump(from: sim.feet, to: landing) != nil {
                step = .crouch(until: Date().addingTimeInterval(0.16), target: landing)
            } else if let grab = sideGrabTarget(for: rect) {
                // The top edge is out of leap range — a tall or maximised
                // window. Aim at the *side* instead: the swept horizontal
                // test converts a descending wall contact into a ledge grab,
                // and `handle(.grabbedLedge)` then climbs the rest of the way.
                // This is what makes windows taller than one jump reachable
                // at all, and it is the whole point of treating them as solid
                // rects rather than bare top edges.
                step = .crouch(until: Date().addingTimeInterval(0.16), target: grab)
            } else {
                // Too far to leap from here — close the horizontal gap first,
                // then re-plan and try again from the new position.
                let approachX = rect.midX < sim.feet.x ? rect.maxX + 30 : rect.minX - 30
                step = .approach(x: approachX, running: true)
            }
        }
    }

    /// A point just inside the near wall of `rect`, as high up it as one leap
    /// can manage, aimed so Bill is already descending when he makes contact
    /// (only a descending contact becomes a grab, never a walk-into).
    private func sideGrabTarget(for rect: CGRect) -> CGPoint? {
        let approachingFromLeft = sim.feet.x < rect.midX
        let wallX = approachingFromLeft ? rect.minX : rect.maxX
        let x = approachingFromLeft ? wallX + 6 : wallX - 6
        // Stay clear of the very top (that is the leap case) and of the very
        // bottom (there is nothing to climb from down there).
        let ceiling = sim.feet.y + sim.maxReachableRise * 0.9
        let y = min(rect.maxY - 40, ceiling)
        guard y > rect.minY + 24, y > sim.feet.y else { return nil }
        guard sim.solveJump(from: sim.feet, to: CGPoint(x: x, y: y)) != nil else { return nil }
        return CGPoint(x: x, y: y)
    }

    private var pendingDropX: CGFloat?

    // MARK: - Ticking

    private func startTicking() {
        tick?.invalidate()
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.stepOnce() }
        }
        // `.common` so the simulation keeps running while a menu is open or
        // the user is dragging another window around.
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
    }

    private func endBeat() {
        tick?.invalidate(); tick = nil
        step = .done
        goal = nil
        pendingDropX = nil
        sim.stop()
        applyState(.idle)
        scheduleNextBeat()
    }

    private func stepOnce() {
        guard let panel, !isSuspended else { endBeat(); return }
        if Date().timeIntervalSince(beatStartedAt) > Self.beatTimeout {
            onEvent?(.reachedGoal)
            endBeat()
            return
        }

        driveStep()
        let events = sim.step(dt: Self.tickInterval)
        applyMotionState()
        writeBack(panel: panel)

        for event in events {
            handle(event)
            onEvent?(event)
        }
        if case .done = step { endBeat() }
    }

    /// Issues the commands the current plan step needs, each tick.
    private func driveStep() {
        switch step {
        case .approach(let x, let running):
            let delta = x - sim.feet.x
            if abs(delta) <= Self.arrivalTolerance || !sim.isGrounded {
                if sim.isGrounded {
                    sim.stop()
                    // Re-plan: either we have arrived, or we walked close
                    // enough that the jump is now solvable.
                    if case .stroll = goal { step = .settle(until: Date().addingTimeInterval(0.4)) }
                    else { planNextStep() }
                }
                return
            }
            sim.walk(direction: delta, running: running)

        case .crouch(let until, let target):
            sim.stop()
            if Date() >= until { step = .launch(target: target) }

        case .launch(let target):
            if sim.jump(to: target) {
                step = .airborne
            } else {
                // The window moved or closed between planning and launching.
                planNextStep()
            }

        case .airborne:
            break

        case .peek(let until):
            sim.stop()
            if Date() >= until {
                if let x = pendingDropX {
                    step = .approach(x: x, running: false)
                    pendingDropX = nil
                } else {
                    step = .settle(until: Date().addingTimeInterval(0.3))
                }
            }

        case .climb(let direction):
            sim.climb(direction: direction)

        case .settle(let until):
            sim.stop()
            if Date() >= until { step = .done }

        case .done:
            break
        }
    }

    private func handle(_ event: RoamEvent) {
        switch event {
        case .landed:
            if case .airborne = step {
                // Arrived. Give the landing beat a moment to read before the
                // beat ends and ambient idle takes back over.
                step = .settle(until: Date().addingTimeInterval(0.45))
            }
        case .grabbedLedge:
            step = .climb(direction: 1)
        case .walkedOffEdge:
            step = .airborne
        case .bonkedHead:
            break
        case .fellOffWorld, .reachedGoal:
            step = .done
        }
    }

    // MARK: - Animation + window

    private func applyMotionState() {
        let state: BillState
        switch sim.motion {
        case .resting:               state = .idle
        case .walking(let dx):
            state = abs(dx) > sim.physics.walkSpeed * sim.scale * 1.3 ? .running : .walking
            updateFacing(dx)
        case .crouching:             state = .crouching
        case .launching:             state = .launching
        case .rising:                state = .rising
        case .falling:               state = .falling
        case .landing(let hard):     state = hard ? .landingHard : .landingSoft
        case .ledgeGrab:             state = .ledgeGrabbing
        case .climbing(let dy):      state = dy >= 0 ? .climbingUp : .climbingDown
        case .hanging:               state = .hangingIdle
        }
        applyState(state)
    }

    private func applyState(_ state: BillState) {
        guard state != lastAppliedState else { return }
        lastAppliedState = state
        characterEngine.request(state, force: true)
    }

    /// The sheet art is authored facing **left**, so a positive `xScale` is
    /// left-facing and a negative one mirrors him to face right.
    ///
    /// Also fixes a long-standing bug: `settleToIdle` deliberately never
    /// resets scale, and nothing else ever restored it, so after a single
    /// rightward move Bill stayed mirrored through idle and every subsequent
    /// clip until he happened to move left again. Facing is now restored to
    /// left whenever a beat ends.
    private func updateFacing(_ dx: CGFloat) {
        let want: CGFloat = dx > 0 ? -1 : 1
        guard want != facing else { return }
        facing = want
        characterEngine.rig.bodyNode.xScale = want * BillRigNode.displayScale
    }

    func resetFacing() {
        facing = 1
        characterEngine.rig.bodyNode.xScale = BillRigNode.displayScale
    }

    // MARK: - Panel <-> simulation

    /// Bill's feet in screen coordinates, derived from the panel's origin.
    private func feetPosition(panel: NSPanel) -> CGPoint {
        let s = preferences.characterScale
        return CGPoint(
            x: panel.frame.minX + Self.centerInsetX * s,
            y: panel.frame.minY + Self.feetInsetY * s
        )
    }

    private func syncSimFromPanel(panel: NSPanel, screen: NSScreen) {
        let feet = feetPosition(panel: panel)
        // Grounded if he is already sitting on the floor or on a ledge.
        let onSurface = abs(feet.y - screen.visibleFrame.minY) < 2
            || sim.solids.contains { abs(feet.y - $0.rect.maxY) < 2 }
        sim.place(feetAt: feet, grounded: onSurface)
    }

    private func writeBack(panel: NSPanel) {
        let s = preferences.characterScale
        let origin = NSPoint(
            x: sim.feet.x - Self.centerInsetX * s,
            y: sim.feet.y - Self.feetInsetY * s
        )
        // Direct `setFrameOrigin`, deliberately NOT `animator().setFrameOrigin`
        // — the animator proxy silently no-ops for window origins (a real,
        // previously-shipped bug), and an interpolated move would fight the
        // simulation, which is already producing a per-frame position.
        guard abs(origin.x - panel.frame.minX) > 0.01 || abs(origin.y - panel.frame.minY) > 0.01 else { return }
        panel.setFrameOrigin(origin)
    }
}
