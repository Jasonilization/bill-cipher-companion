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

    /// Let go of a wall or overhang and fall.
    func release() {
        grabbedSolid = nil
        velocity = .zero
        isGrounded = false
        motion = .falling
        fallStartY = feet.y
    }

    // MARK: - Integration

    /// Advances the simulation and returns everything notable that happened.
    /// Uses swept collision against the previous position rather than a
    /// point test at the new one, so a fast fall can never tunnel straight
    /// through a thin ledge between two frames.
    func step(dt: TimeInterval) -> [RoamEvent] {
        pendingEvents.removeAll(keepingCapacity: true)
        let d = CGFloat(dt)

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

    /// Blocks horizontal movement into a solid's side, and converts a
    /// wall-contact while falling into a ledge grab.
    private func resolveHorizontal(from previous: CGPoint, to next: CGPoint) -> CGFloat {
        guard next.x != previous.x else { return next.x }
        let top = previous.y + height
        for solid in solids where !solid.isWorldBounds {
            let r = solid.rect
            // Only walls we vertically overlap can block us.
            guard previous.y < r.maxY, top > r.minY else { continue }
            let movingRight = next.x > previous.x
            let leadingBefore = movingRight ? previous.x + halfWidth : previous.x - halfWidth
            let leadingAfter = movingRight ? next.x + halfWidth : next.x - halfWidth
            let wall = movingRight ? r.minX : r.maxX
            let crossed = movingRight ? (leadingBefore <= wall && leadingAfter >= wall)
                                      : (leadingBefore >= wall && leadingAfter <= wall)
            guard crossed else { continue }

            // Falling into a wall catches it; walking into one just stops.
            if !isGrounded, velocity.dy < 0 {
                grabbedSolid = r
                velocity = .zero
                motion = .ledgeGrab
                pendingEvents.append(.grabbedLedge)
            }
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
            guard previous.y >= ledge - 0.5, next.y <= ledge else { continue }
            if landingY == nil || ledge > landingY! { landingY = ledge }
        }
        let floor = worldBounds.minY
        if next.x + halfWidth > worldBounds.minX, next.x - halfWidth < worldBounds.maxX,
           previous.y >= floor - 0.5, next.y <= floor {
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
            guard headBefore <= r.minY, headAfter >= r.minY else { continue }
            next.y = r.minY - height
            velocity.dy = 0
            pendingEvents.append(.bonkedHead)
            return
        }
        if headAfter >= worldBounds.maxY {
            next.y = worldBounds.maxY - height
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
