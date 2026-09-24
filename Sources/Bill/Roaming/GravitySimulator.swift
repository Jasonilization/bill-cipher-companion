import CoreGraphics
import Foundation

/// Pure, AppKit-free platformer physics for Bill. Everything here is in Cocoa
/// screen coordinates (bottom-left origin, Y up) and measured in points and
/// points-per-second, so the caller can hand the resulting `feet` position
/// straight to `CharacterWindowController` without any conversion.
///
/// Deliberately a value-semantics simulation with an explicit `step(dt:)`:
/// there is no timer, no run loop and no AppKit in this file, so the physics
/// can be reasoned about (and, later, unit-tested) in isolation from the
/// window plumbing that drives it.
struct RoamPhysics {
    /// Downward acceleration. Tuned against the 1.9x sprite display scale so
    /// a jump to a typical window title bar (~350pt up) takes a bit under a
    /// second of flight — fast enough to read as decisive, slow enough that
    /// the rise/apex/fall animation beats are all actually visible.
    var gravity: CGFloat = 2000
    var walkSpeed: CGFloat = 72
    var runSpeed: CGFloat = 155
    var climbSpeed: CGFloat = 95
    /// Stops a long drop turning into an un-animatable blur.
    var terminalVelocity: CGFloat = 1500
    var maxLaunchSpeedX: CGFloat = 520
    /// A single leap reaches `maxLaunchSpeedY^2 / (2 * gravity) - apexClearance`
    /// ≈ 855pt of rise. Sized deliberately: at 1350 the ceiling was ~410pt,
    /// which could not reach the title bar of a maximised window from the
    /// Dock — the single most obvious jump on the desktop. Anything taller
    /// than this is reached by grabbing the window's side and climbing, which
    /// is why the ceiling does not need to cover the whole screen height.
    var maxLaunchSpeedY: CGFloat = 1900
    /// How far above the destination ledge the arc peaks, so Bill visibly
    /// clears it rather than scraping along it.
    var apexClearance: CGFloat = 46
    /// Grace period after walking off a ledge during which a jump is still
    /// allowed — the standard platformer "coyote time" that stops edge
    /// departures feeling like they ate the input.
    var coyoteTime: TimeInterval = 0.09
    /// How close to a wall Bill has to be, while falling, to catch it.
    var ledgeGrabReach: CGFloat = 14
    /// A landing from higher than this plays the hard-landing beat.
    var hardLandingSpeed: CGFloat = 780
    /// How far from a surface still counts as standing on it.
    ///
    /// This has to be the *same* number everywhere. It was not: `place(feetAt:)`
    /// accepted "within 2pt of the floor" as grounded, while the swept landing
    /// test required `previous.y >= ledge - 0.5`. Bill's panel origin rounds to
    /// whole points, so he routinely started a beat 1pt below the floor line:
    /// grounded by one test, in mid-air by the other. The observed result was
    /// `walkedOffEdge` immediately followed by `fellOffWorld` on the very first
    /// tick — the beat aborted before he took a step, every time.
    var surfaceTolerance: CGFloat = 2.5
    /// Bill's collision box, in points at `characterScale == 1`. Narrower
    /// than his widest walk-cycle silhouette on purpose: a collision box the
    /// size of his flailing limbs makes him refuse to fit through gaps he
    /// visually clears easily.
    var bodyWidth: CGFloat = 64
    var bodyHeight: CGFloat = 122
}

/// What the simulation is doing right now. The roaming controller maps each
/// of these onto a `BillState` (and therefore onto real sprite art).
enum RoamMotion: Equatable {
    case resting
    case walking(dx: CGFloat)
    case crouching
    case launching
    case rising
    case falling
    case ledgeGrab
    case climbing(dy: CGFloat)
    case hanging
    case landing(hard: Bool)
}

/// One-shot things that happened during a `step` — the controller turns these
/// into animation requests and bark lines.
enum RoamEvent: Equatable {
    case landed(hard: Bool, fromHeight: CGFloat)
    case grabbedLedge
    case bonkedHead
    case walkedOffEdge
    case reachedGoal
    case fellOffWorld
    /// A window moved into him and knocked him flying.
    case shoved
    /// Landed on a window's traffic-light zone with prank intent (see
    /// `RoamingController`'s `.trafficLight` goal) — the owner should play
    /// the press beat and then actually press the minimize button.
    case minimizePrankArrived(window: CGRect)
}

/// A solid the simulation can collide with, reduced to just its geometry.
struct RoamSolid: Equatable {
    var rect: CGRect
    /// `true` for the screen floor/walls, which must never be climbed or
    /// hung from — only stood on.
    var isWorldBounds: Bool = false
}

@MainActor
final class GravitySimulator {
    private(set) var feet: CGPoint = .zero
    private(set) var velocity: CGVector = .zero
    private(set) var motion: RoamMotion = .resting
    private(set) var isGrounded = false

    var physics = RoamPhysics()
    /// Multiplies every length so the simulation stays proportional to
    /// `AppPreferences.characterScale`.
    var scale: CGFloat = 1

    /// Solids in front-to-back order, plus the world bounds. Rebuilt by the
    /// controller at the start of each beat, never per tick.
    var solids: [RoamSolid] = []
    /// The screen rect Bill currently belongs to, already inset for the Dock
    /// and menu bar (`NSScreen.visibleFrame`).
    var worldBounds: CGRect = .zero

    private var timeSinceGrounded: TimeInterval = 0
    private var fallStartY: CGFloat = 0
    private var pendingEvents: [RoamEvent] = []
    private var grabbedSolid: CGRect?

    private var halfWidth: CGFloat { physics.bodyWidth * scale / 2 }
    private var height: CGFloat { physics.bodyHeight * scale }

    // MARK: - Placement

    func place(feetAt point: CGPoint, grounded: Bool) {
        feet = point
        // Snap exactly onto the surface being stood on, so the landing test
        // and the grounded test cannot disagree by a rounding error.
        if grounded {
            let surfaces = solids.map(\.rect.maxY) + [worldBounds.minY]
            if let nearest = surfaces.min(by: { abs($0 - point.y) < abs($1 - point.y) }),
               abs(nearest - point.y) <= physics.surfaceTolerance * scale {
                feet.y = nearest
            }
        }
        velocity = .zero
        isGrounded = grounded
        motion = grounded ? .resting : .falling
        timeSinceGrounded = 0
        fallStartY = point.y
        grabbedSolid = nil
    }

    // MARK: - Commands

    func walk(direction: CGFloat, running: Bool = false) {
        guard isGrounded else { return }
        let speed = (running ? physics.runSpeed : physics.walkSpeed) * scale
        velocity.dx = direction >= 0 ? speed : -speed
        motion = .walking(dx: velocity.dx)
    }

    func stop() {
        velocity.dx = 0
        if isGrounded { motion = .resting }
    }

    /// Solves the ballistic arc from Bill's feet to `target` and, if the arc
    /// is within the launch envelope, commits to it.
    ///
    /// The maths, so it is auditable rather than magic: with `g` the gravity
    /// magnitude and `h` the peak height above the start,
    /// `vy0 = sqrt(2gh)`, `t_up = vy0 / g`, the fall from the peak down to the
    /// target takes `t_down = sqrt(2 * (h - dy) / g)`, and the horizontal
    /// speed needed to cover `dx` over the whole flight is
    /// `vx = dx / (t_up + t_down)`.
    @discardableResult
    func jump(to target: CGPoint) -> Bool {
        guard isGrounded || timeSinceGrounded <= physics.coyoteTime else { return false }
        guard let solution = solveJump(from: feet, to: target) else { return false }
        velocity = solution
        isGrounded = false
        motion = .launching
        fallStartY = feet.y
        grabbedSolid = nil
        return true
    }

    /// Traces the solved arc and reports whether anything is in the way.
    ///
    /// Without this the planner happily solved a mathematically valid arc that
    /// ran straight through the underside of the very window it was aiming at:
    /// observed live as `LAUNCH to (1060,982)` immediately followed by
    /// `bonkedHead at (1486,219)` and a fall back to the floor. The arc was
    /// correct; the route was not. Windows are solid, so reaching a ledge you
    /// are standing underneath means going around, not through.
    func isArcClear(from start: CGPoint, velocity v: CGVector, to target: CGPoint) -> Bool {
        let g = physics.gravity * scale
        let dt = CGFloat(Self.timestep)
        let hw = halfWidth
        let h = height

        // Anything he is already overlapping is something he is standing in
        // front of, not an obstacle. Only solids entered from outside can
        // block the arc.
        let startBox = CGRect(x: start.x - hw, y: start.y, width: hw * 2, height: h)
        let obstacles = solids.filter { !$0.isWorldBounds && !$0.rect.intersects(startBox) }

        var p = start
        var vy = v.dy
        var head = p.y + h
        for _ in 0..<Self.maxSolverSteps {
            let previousHead = head
            vy -= g * dt
            p.x += v.dx * dt
            p.y += vy * dt
            head = p.y + h
            if vy <= 0, p.y <= target.y + 1 { return true }
            if p.y >= worldBounds.maxY { return false }
            for solid in obstacles {
                let r = solid.rect
                guard p.x + hw > r.minX, p.x - hw < r.maxX else { continue }
                // Rising into an underside is the only thing that stops a jump
                // — mirrors `resolveRising`, so the prediction matches what the
                // integrator will actually do.
                if previousHead <= r.minY, head >= r.minY { return false }
            }
        }
        return false
    }

    /// The highest a single leap can climb, given the launch envelope. Above
    /// this, the only way up is to catch the window's side and climb it —
    /// which is exactly what `RoamingController` falls back to.
    var maxReachableRise: CGFloat {
        let peak = (physics.maxLaunchSpeedY * physics.maxLaunchSpeedY) / (2 * physics.gravity)
        return (peak - physics.apexClearance) * scale
    }

    /// `nil` when the arc is not physically reachable within the launch
    /// envelope — the caller should walk closer, climb, or pick another goal
    /// rather than attempting an impossible leap.
    func solveJump(from start: CGPoint, to target: CGPoint) -> CGVector? {
        let g = physics.gravity * scale
        let dx = target.x - start.x
        let dy = target.y - start.y
        let peak = max(dy, 0) + physics.apexClearance * scale
        guard peak > 0 else { return nil }

        let vy0 = (2 * g * peak).squareRoot()
        guard vy0 <= physics.maxLaunchSpeedY * scale else { return nil }

        // Horizontal speed is derived from the *discrete* flight time, not
        // the closed-form one.
        //
        // `step(dt:)` integrates semi-implicit Euler — it applies gravity and
        // *then* moves — so the arc it actually traces is slightly steeper
        // than the continuous solution `t = vy0/g + sqrt(2(peak-dy)/g)`
        // predicts. Using the continuous time made every single jump land
        // short, by ~1.5pt on a small hop and ~12pt on a long leap, always in
        // the same direction. Rather than paper over it with mid-air steering,
        // run the exact same integrator forward here to count the ticks the
        // arc will really take, then divide the horizontal distance by that.
        // Residual error is then bounded by one tick of horizontal travel.
        let dt = CGFloat(Self.timestep)
        var vy = vy0
        var y: CGFloat = 0
        var flight: CGFloat?
        for step in 1...Self.maxSolverSteps {
            let previousY = y
            vy -= g * dt
            y += vy * dt
            if vy <= 0, previousY >= dy, y <= dy {
                flight = CGFloat(step) * dt
                break
            }
        }
        guard let t = flight, t > 0.01 else { return nil }

        let vx = dx / t
        guard abs(vx) <= physics.maxLaunchSpeedX * scale else { return nil }
        return CGVector(dx: vx, dy: vy0)
    }

    /// The fixed timestep the simulation runs at. `RoamingController` drives
    /// its tick from this same constant so the solver and the integrator can
    /// never drift out of agreement.
    static let timestep: TimeInterval = 1.0 / 60.0
    /// ~8s of flight. A solve that has not landed by then is not a jump.
    private static let maxSolverSteps = 500

    func climb(direction: CGFloat) {
        guard grabbedSolid != nil else { return }
        velocity = CGVector(dx: 0, dy: direction * physics.climbSpeed * scale)
        motion = .climbing(dy: velocity.dy)
    }

    /// Knocks Bill off his feet with an impulse — a window sweeping into him.
    func shove(_ impulse: CGVector) {
        grabbedSolid = nil
        isGrounded = false
        velocity = impulse
        motion = impulse.dy > 0 ? .rising : .falling
        fallStartY = feet.y
        timeSinceGrounded = 0
    }

    /// Carries Bill along with a surface that moved under him.
    func ride(dx: CGFloat) {
        feet.x += dx
    }

    /// Let go of a wall or overhang and fall.
    func release() {
        grabbedSolid = nil
        velocity = .zero
        isGrounded = false
        motion = .falling
        fallStartY = feet.y
    }

    /// Frees him only when he's actually clinging to something. `release()`
    /// alone is unsafe to call blindly — it un-grounds a resting Bill and
    /// starts him falling — so beat boundaries use this instead.
    func releaseIfHanging() {
        guard grabbedSolid != nil else { return }
        release()
    }

    /// The never-stuck guarantee: clinging to nothing (the climb command
    /// never came), or airborne with ~zero velocity (an edge case the
    /// planners didn't cover, e.g. geometry shifting mid-grab near a screen
    /// edge), for this long means no planner is coming to rescue him on
    /// this beat — drop out of it and let gravity re-take him. Normal
    /// hangs last well under a second (the climb step is planned the very
    /// tick after the grab), so six is unreachably conservative.
    private var stuckSeconds: TimeInterval = 0
    private static let stuckThreshold: TimeInterval = 6

    private func watchdog(dt: TimeInterval) {
        let airborne = !isGrounded
        let frozen = abs(velocity.dx) < 1 && abs(velocity.dy) < 1
        let clinging = grabbedSolid != nil
        if clinging || (airborne && frozen) {
            stuckSeconds += dt
            if stuckSeconds > Self.stuckThreshold {
                stuckSeconds = 0
                release()
                pendingEvents.append(.walkedOffEdge)
            }
        } else {
            stuckSeconds = 0
        }
    }

    // MARK: - Integration

    /// Advances the simulation and returns everything notable that happened.
    /// Uses swept collision against the previous position rather than a
    /// point test at the new one, so a fast fall can never tunnel straight
    /// through a thin ledge between two frames.
    func step(dt: TimeInterval) -> [RoamEvent] {
        pendingEvents.removeAll(keepingCapacity: true)
        let d = CGFloat(dt)
        watchdog(dt: dt)

        if grabbedSolid != nil {
            stepClimbing(d)
            return pendingEvents
        }

        if isGrounded {
            timeSinceGrounded = 0
        } else {
            timeSinceGrounded += dt
            velocity.dy -= physics.gravity * scale * d
            velocity.dy = max(velocity.dy, -physics.terminalVelocity * scale)
        }

        let previous = feet
        var next = CGPoint(x: feet.x + velocity.dx * d, y: feet.y + velocity.dy * d)

        next.x = resolveHorizontal(from: previous, to: next)

        if velocity.dy <= 0 {
            resolveFalling(from: previous, to: &next)
        } else {
            resolveRising(from: previous, to: &next)
        }

        feet = next
        clampToWorld()
        updateMotion()
        return pendingEvents
    }

    private func stepClimbing(_ d: CGFloat) {
        guard let solid = grabbedSolid else { return }
        feet.y += velocity.dy * d
        // Reaching the top of the wall is a successful climb-up: step onto
        // the ledge and let go.
        if feet.y + height >= solid.maxY {
            feet.y = solid.maxY
            grabbedSolid = nil
            isGrounded = true
            velocity = .zero
            motion = .landing(hard: false)
            pendingEvents.append(.landed(hard: false, fromHeight: 0))
            return
        }
        // Climbing below the bottom of the wall means letting go into a drop.
        if feet.y <= solid.minY - height * 0.4 {
            release()
            return
        }
        if velocity.dy == 0 { motion = .hanging }
    }

    /// Catches a window's side on the way past it.
    ///
    /// Walls deliberately do **not** block a grounded Bill. He is drawn in a
    /// floating-level panel, i.e. visually *in front of* every window, so a
    /// window whose lower half happens to be beside him is not something he
    /// should walk into — from the user's point of view he would stop dead in
    /// the middle of empty desktop for no visible reason. Worse, most windows
    /// extend down to near the Dock, so on the ground floor he is "inside"
    /// several of them at once and could barely move at all. Observed live:
    /// every jump target was rejected as blocked because the arc started
    /// inside the window it was leaving.
    ///
    /// So a side is only ever a *grab*, never a barrier: it matters when he is
    /// airborne and descending past it, which is exactly the ledge-catch the
    /// solid-rect model exists for.
    private func resolveHorizontal(from previous: CGPoint, to next: CGPoint) -> CGFloat {
        guard next.x != previous.x, !isGrounded, velocity.dy < 0 else { return next.x }
        let top = previous.y + height
        for solid in solids where !solid.isWorldBounds {
            let r = solid.rect
            guard previous.y < r.maxY, top > r.minY else { continue }
            let movingRight = next.x > previous.x
            let leadingBefore = movingRight ? previous.x + halfWidth : previous.x - halfWidth
            let leadingAfter = movingRight ? next.x + halfWidth : next.x - halfWidth
            let wall = movingRight ? r.minX : r.maxX
            let crossed = movingRight ? (leadingBefore <= wall && leadingAfter >= wall)
                                      : (leadingBefore >= wall && leadingAfter <= wall)
            guard crossed else { continue }
            grabbedSolid = r
            velocity = .zero
            motion = .ledgeGrab
            pendingEvents.append(.grabbedLedge)
            return movingRight ? wall - halfWidth : wall + halfWidth
        }
        return next.x
    }

    /// Swept downward collision: lands on the highest ledge crossed between
    /// the previous and next feet positions.
    private func resolveFalling(from previous: CGPoint, to next: inout CGPoint) {
        var landingY: CGFloat?
        for solid in solids {
            let r = solid.rect
            guard next.x + halfWidth > r.minX, next.x - halfWidth < r.maxX else { continue }
            let ledge = r.maxY
            let slack = physics.surfaceTolerance * scale
            guard previous.y >= ledge - slack, next.y <= ledge else { continue }
            if landingY == nil || ledge > landingY! { landingY = ledge }
        }
        let floor = worldBounds.minY
        if next.x + halfWidth > worldBounds.minX, next.x - halfWidth < worldBounds.maxX,
           previous.y >= floor - physics.surfaceTolerance * scale, next.y <= floor {
            if landingY == nil || floor > landingY! { landingY = floor }
        }

        guard let y = landingY else {
            if isGrounded {
                isGrounded = false
                fallStartY = previous.y
                pendingEvents.append(.walkedOffEdge)
            }
            return
        }

        let impact = abs(velocity.dy)
        let dropped = max(0, fallStartY - y)
        next.y = y
        velocity.dy = 0
        if !isGrounded {
            isGrounded = true
            let hard = impact >= physics.hardLandingSpeed * scale
            motion = .landing(hard: hard)
            pendingEvents.append(.landed(hard: hard, fromHeight: dropped))
        }
    }

    /// Swept upward collision against the underside of windows.
    private func resolveRising(from previous: CGPoint, to next: inout CGPoint) {
        let headBefore = previous.y + height
        let headAfter = next.y + height
        for solid in solids where !solid.isWorldBounds {
            let r = solid.rect
            guard next.x + halfWidth > r.minX, next.x - halfWidth < r.maxX else { continue }
            // `headBefore <= r.minY` already means he was fully underneath it,
            // so a window he is merely standing in front of can never bonk him.
            guard headBefore <= r.minY, headAfter >= r.minY else { continue }
            next.y = r.minY - height
            velocity.dy = 0
            pendingEvents.append(.bonkedHead)
            return
        }
        // The ceiling constrains his FEET, not his head.
        //
        // Clamping the head to `visibleFrame.maxY` made every high window
        // unreachable: standing on a ledge at y=982 puts his hat at 1128,
        // above the 1074 working-area top, so the arc was rejected as hitting
        // the ceiling before it ever got there. Bill's window is explicitly
        // allowed to hang off the screen edges (see `BillPanel`, which
        // overrides `constrainFrameRect`), and his hat poking above the menu
        // bar is exactly the look that already permits. What must stay on
        // screen is the part he stands on.
        if next.y >= worldBounds.maxY {
            next.y = worldBounds.maxY
            velocity.dy = 0
            pendingEvents.append(.bonkedHead)
        }
    }

    private func clampToWorld() {
        if feet.x - halfWidth < worldBounds.minX {
            feet.x = worldBounds.minX + halfWidth
            if velocity.dx < 0 { velocity.dx = 0 }
        }
        if feet.x + halfWidth > worldBounds.maxX {
            feet.x = worldBounds.maxX - halfWidth
            if velocity.dx > 0 { velocity.dx = 0 }
        }
        // A window closing under Bill mid-frame, or a display change, can
        // strand him below the world. Recover rather than fall forever.
        if feet.y < worldBounds.minY - height {
            feet.y = worldBounds.minY
            velocity = .zero
            isGrounded = true
            pendingEvents.append(.fellOffWorld)
        }
    }

    private func updateMotion() {
        guard grabbedSolid == nil else { return }
        if case .landing = motion { return }
        if isGrounded {
            motion = velocity.dx == 0 ? .resting : .walking(dx: velocity.dx)
        } else {
            motion = velocity.dy > 0 ? .rising : .falling
        }
    }
}
