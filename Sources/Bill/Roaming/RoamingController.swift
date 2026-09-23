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
        /// Walk to the nearest edge of the current surface, look over it, and
        /// step off on purpose.
        case dropOff
        /// Onto a window's traffic-light zone with prank intent: land on
        /// the minimize button, play the press beat, and actually press it.
        /// Rarest goal by far (see `minimizePrankChance`).
        case trafficLight(rect: CGRect)
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
    /// Short on purpose. Bill is meant to be *living* on the desktop, not
    /// posing on it, so beats follow each other closely.
    private static let restInterval: ClosedRange<TimeInterval> = 3...9
    /// Below this the goal is close enough that walking to it reads as
    /// fidgeting rather than travelling.
    private static let arrivalTolerance: CGFloat = 8
    /// Chance a beat targets a real window rather than strolling on the
    /// current surface. Kept high — climbing the desktop is the whole point.
    /// Raised from 0.62. Climbing the desktop is the entire point of the
    /// feature, and with only a couple of windows typically reachable a lower
    /// number made jumps genuinely rare to witness.
    private static let windowGoalChance = 0.85
    /// While already up on a window, the chance a beat is a deliberate drop
    /// rather than more climbing. Falling on purpose is half the fun of having
    /// gravity, and without this he only ever came down by accidentally
    /// walking off an edge.
    private static let deliberateDropChance = 0.45

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
        startContactWatch()
    }

    private func startContactWatch() {
        contactTimer?.invalidate()
        let t = Timer(timeInterval: Self.contactInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkContacts() }
        }
        RunLoop.main.add(t, forMode: .common)
        contactTimer = t
    }

    /// Notices windows moving into Bill (and surfaces moving under him).
    private func checkContacts() {
        guard let panel, !isSuspended, preferences.isRoamingEnabled else { return }
        guard let screen = screenForBill() else { return }
        let scale = preferences.characterScale
        let feet = feetPosition(panel: panel)
        let hw = sim.physics.bodyWidth * scale / 2
        let body = CGRect(x: feet.x - hw, y: feet.y, width: hw * 2, height: sim.physics.bodyHeight * scale)

        let platforms = WindowTopology.platforms(excludingWindowNumber: panel.windowNumber, fresh: true)
        var rects: [Int: CGRect] = [:]
        var shove: CGVector?
        var rideDX: CGFloat = 0

        for p in platforms {
            rects[p.windowNumber] = p.rect
            guard let old = previousRects[p.windowNumber], old != p.rect else { continue }
            let dx = p.rect.minX - old.minX
            let dy = p.rect.minY - old.minY

            // Standing on this ledge and it slid sideways: go with it.
            if abs(feet.y - p.rect.maxY) < 3, feet.x > p.rect.minX, feet.x < p.rect.maxX, abs(dx) >= 1 {
                rideDX += dx
                continue
            }

            // Swept into him: it did not overlap before, and does now.
            guard !old.intersects(body), p.rect.intersects(body) else { continue }
            guard abs(dx) >= Self.minShoveDelta || abs(dy) >= Self.minShoveDelta else { continue }

            // Push along the direction the window travelled, biased to send
            // him out sideways rather than straight down through the floor.
            let vx = max(-Self.maxShoveSpeed, min(Self.maxShoveSpeed, dx * Self.shoveGain / CGFloat(Self.contactInterval)))
            let vy = max(0, dy * Self.shoveGain / CGFloat(Self.contactInterval))
            shove = CGVector(dx: vx == 0 ? (feet.x < p.rect.midX ? -260 : 260) : vx,
                             dy: max(vy, 300 * scale))
        }
        previousRects = rects

        if rideDX != 0, tick == nil {
            panel.setFrameOrigin(NSPoint(x: panel.frame.minX + rideDX, y: panel.frame.minY))
        }

        // Standing on nothing?
        //
        // The simulation only re-evaluates support during a beat, so anything
        // that removes the surface *between* beats left Bill hanging in mid-air
        // until the next one — up to fifteen seconds later. Closing the window
        // he was perched on, moving it, switching Spaces, or simply dropping
        // him mid-drag all do exactly that. Since this watcher already has
        // fresh geometry in hand, it is the natural place to notice.
        if tick == nil, shove == nil {
            let floor = screen.visibleFrame.minY
            let tolerance = sim.physics.surfaceTolerance * scale
            let supported = abs(feet.y - floor) <= tolerance || platforms.contains { p in
                abs(feet.y - p.rect.maxY) <= tolerance && feet.x > p.rect.minX - hw && feet.x < p.rect.maxX + hw
            }
            if !supported, feet.y > floor + tolerance {
                log("UNSUPPORTED at (\(Int(feet.x)),\(Int(feet.y))) — falling")
                buildWorld(on: screen, panel: panel)
                sim.place(feetAt: feet, grounded: false)
                goal = nil
                step = .airborne
                beatStartedAt = Date()
                restTimer?.invalidate()
                startTicking()
                return
            }
        }

        guard let impulse = shove, Date().timeIntervalSince(lastShoveAt) > Self.shoveCooldown else { return }
        lastShoveAt = Date()
        log("SHOVED by window  impulse=(\(Int(impulse.dx)),\(Int(impulse.dy)))")

        // Re-seed the simulation from where he actually is, then launch him.
        buildWorld(on: screen, panel: panel)
        sim.place(feetAt: feet, grounded: false)
        sim.shove(impulse)
        goal = nil
        step = .airborne
        beatStartedAt = Date()
        restTimer?.invalidate()
        characterEngine.request(.surprised, force: true)
        onEvent?(.shoved)
        startTicking()
    }

    func stop() {
        tick?.invalidate(); tick = nil
        contactTimer?.invalidate(); contactTimer = nil
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
        // Don't wait for the next contact tick: if he was let go in mid-air he
        // should start falling on the same frame, not up to a fifth of a
        // second later.
        dropIfUnsupported()
    }

    /// Starts a fall immediately if nothing is under Bill's feet.
    ///
    /// Called the instant a drag ends, so releasing him over empty desktop
    /// reads as dropping him rather than as him hovering until the simulation
    /// next happens to look.
    func dropIfUnsupported() {
        guard let panel, !isSuspended, preferences.isRoamingEnabled, tick == nil else { return }
        guard let screen = screenForBill() else { return }
        buildWorld(on: screen, panel: panel)
        let feet = feetPosition(panel: panel)
        let tolerance = sim.physics.surfaceTolerance * preferences.characterScale
        let supported = abs(feet.y - screen.visibleFrame.minY) <= tolerance
            || sim.solids.contains { abs(feet.y - $0.rect.maxY) <= tolerance }
        guard !supported else { return }
        sim.place(feetAt: feet, grounded: false)
        goal = nil
        step = .airborne
        beatStartedAt = Date()
        restTimer?.invalidate()
        startTicking()
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

    /// Set `BILL_ROAM_DEBUG=1` to trace every beat decision to stdout.
    static let debug = ProcessInfo.processInfo.environment["BILL_ROAM_DEBUG"] == "1"
    private func log(_ m: @autoclosure () -> String) {
        if Self.debug { print("[roam] \(m())") }
    }

    private func beginBeat(goal explicitGoal: Goal?) {
        guard let panel else { return }
        guard preferences.isRoamingEnabled else { log("BAIL roaming disabled"); scheduleNextBeat(); return }
        // Only start from genuine rest — never yank Bill out of a reaction,
        // a rare Easter egg, or a chat exchange.
        if explicitGoal == nil {
            let current = characterEngine.stateMachine.currentState
            guard current == .idle || current.isRoamingMotion else {
                log("BAIL state=\(current) (not idle/roaming)")
                scheduleNextBeat(); return
            }
        }
        guard let screen = screenForBill() else { log("BAIL no screen"); scheduleNextBeat(); return }

        buildWorld(on: screen, panel: panel)
        syncSimFromPanel(panel: panel, screen: screen)
        log("begin feet=(\(Int(sim.feet.x)),\(Int(sim.feet.y))) grounded=\(sim.isGrounded) solids=\(sim.solids.count) visible=\(screen.visibleFrame)")

        guard let chosen = explicitGoal ?? pickGoal(on: screen, panel: panel) else {
            log("BAIL no goal")
            scheduleNextBeat(); return
        }
        switch chosen {
        case .stroll(let x):    log("goal STROLL to x=\(Int(x))")
        case .dropOff:          log("goal DROP OFF from y=\(Int(sim.feet.y))")
        case .dropOff:
            // Head for whichever end of this ledge is nearer, stopping just
            // past it so the next tick has nothing underfoot.
            guard let ledge = currentLedge() else {
                step = .settle(until: Date().addingTimeInterval(0.3))
                return
            }
            let leftGap = sim.feet.x - ledge.minX
            let rightGap = ledge.maxX - sim.feet.x
            let edgeX = leftGap < rightGap ? ledge.minX - 12 : ledge.maxX + 12
            pendingDropX = edgeX
            step = .approach(x: edgeX, running: false)

        case .ground(let x):    log("goal GROUND to x=\(Int(x))")
        case .platform(let r):  log("goal PLATFORM top=\(Int(r.maxY)) x=\(Int(r.minX))...\(Int(r.maxX))")
        case .trafficLight(let r): log("goal TRAFFIC LIGHT top=\(Int(r.maxY)) x=\(Int(r.minX)) (prank)")
        }
        goal = chosen
        replanCount = 0
        strollLegs = 0
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
            .compactMap { platform -> RoamSolid? in
                // Clamp every solid into the *walkable* world (the screen's
                // visible frame, which excludes the menu-bar strip). A
                // window whose top edge reaches into that strip — a
                // fullscreen-adjacent app, a "maximize" that keeps the bar —
                // was previously solid above the ceiling: the side-grab
                // could catch it, Bill would climb toward a top edge the
                // ceiling clamp refuses to let him reach, and he ping-ponged
                // in a grab-clamp-fall loop right under the menu bar — the
                // "stuck on the menu" report. After the clamp, no solid
                // exists above the ceiling at all: the climb tops out
                // exactly at the walkable top edge.
                let rect = platform.rect.intersection(visible)
                guard !rect.isEmpty, rect.height > 4 else { return nil }
                return RoamSolid(rect: rect)
            }
    }

    private func pickGoal(on screen: NSScreen, panel: NSPanel) -> Goal? {
        let visible = screen.visibleFrame

        // The prank: leap onto a non-frontmost window's minimize button and
        // actually press it. Gated hard — enabled in Settings, Accessibility
        // granted, a real cooldown so it stays a surprise rather than a
        // menace, and only a window the frontmost user isn't typing in.
        if let target = pickMinimizePrankTarget(visible: visible, panel: panel) {
            return .trafficLight(rect: target)
        }

        let reachable = sim.solids
            .map(\.rect)
            .filter { rect in
                // He cannot stand where his feet would be at (or above) the
                // top of the working area — the ceiling clamp puts him there
                // and the arc can never complete. A maximised-height window
                // would otherwise be picked repeatedly and abandoned after
                // five failed re-plans, wasting the whole beat.
                guard rect.maxY < visible.maxY - 8 else { return false }
                // Reachable by a direct leap onto the top edge, or by
                // catching the side and climbing.
                let landing = landingPoint(on: rect)
                if let v = sim.solveJump(from: sim.feet, to: landing),
                   sim.isArcClear(from: sim.feet, velocity: v, to: landing) { return true }
                return sideGrabTarget(for: rect) != nil
            }

        let isElevated = sim.feet.y > visible.minY + 40

        // Up high, a deliberate drop competes with climbing further.
        if isElevated, Double.random(in: 0..<1) < Self.deliberateDropChance {
            return .dropOff
        }
        if !reachable.isEmpty, Double.random(in: 0..<1) < Self.windowGoalChance {
            return .platform(rect: reachable.randomElement()!)
        }
        if isElevated, Double.random(in: 0..<1) < 0.4 {
            return .ground(x: CGFloat.random(in: visible.minX + 80...visible.maxX - 80))
        }
        let span = CGFloat.random(in: 160...460) * (Bool.random() ? 1 : -1)
        let x = min(max(sim.feet.x + span, visible.minX + 40), visible.maxX - 40)
        return .stroll(x: x)
    }

    // MARK: - Planning

    /// The window rect Bill aims his minimize prank at, or `nil` when the
    /// beat isn't a prank. Held so the landing can hand the right window to
    /// the press path even after several airborne ticks.
    private var pendingPrankWindow: CGRect?
    private var lastMinimizePrankAt: Date?
    /// How rare the prank is: one chance roll per beat behind a cooldown of
    /// several minutes. Rare enough to be a delightful surprise, frequent
    /// enough to actually be witnessed.
    private static let minimizePrankChance = 0.10
    private static let minimizePrankCooldown: TimeInterval = 25 * 60
    /// Where the yellow light sits inside a standard traffic-light cluster,
    /// from the window's left edge.
    private static let trafficLightInsetX: CGFloat = 40

    /// Candidate windows for the prank: never the frontmost (minimizing
    /// what the user is actively typing in would be hostile, not playful),
    /// never one whose top is pinned at the ceiling, and only one a direct,
    /// *clear* leap can land precisely on the button.
    private func pickMinimizePrankTarget(visible: CGRect, panel: NSPanel) -> CGRect? {
        guard
            preferences.isMinimizeMischiefEnabled,
            WindowTitleReader.isTrusted,
            Date().timeIntervalSince(lastMinimizePrankAt ?? .distantPast) > Self.minimizePrankCooldown,
            Double.random(in: 0..<1) < Self.minimizePrankChance
        else { return nil }

        // `platforms` is front-to-back; `dropFirst` skips the frontmost —
        // minimizing the window the user is actively typing in would be
        // hostile, not playful.
        let candidates = WindowTopology
            .platforms(excludingWindowNumber: panel.windowNumber, fresh: true)
            .dropFirst()
            .map(\.rect)
            .filter { rect in
                rect.width >= 260
                    && rect.maxY < visible.maxY - 8
                    && rect.maxY > sim.feet.y + 60
            }
        for rect in candidates.shuffled() {
            let button = CGPoint(x: rect.minX + Self.trafficLightInsetX, y: rect.maxY)
            if let v = sim.solveJump(from: sim.feet, to: button),
               sim.isArcClear(from: sim.feet, velocity: v, to: button) {
                lastMinimizePrankAt = Date()
                return rect
            }
        }
        return nil
    }

    private func planNextStep() {
        guard let goal else { step = .done; return }
        switch goal {
        case .stroll(let x):
            step = .approach(x: x, running: abs(x - sim.feet.x) > 240)

        case .dropOff:
            // Head for whichever end of this ledge is nearer, stopping just
            // past it so the next tick has nothing underfoot.
            guard let ledge = currentLedge() else {
                step = .settle(until: Date().addingTimeInterval(0.3))
                return
            }
            let leftGap = sim.feet.x - ledge.minX
            let rightGap = ledge.maxX - sim.feet.x
            let edgeX = leftGap < rightGap ? ledge.minX - 12 : ledge.maxX + 12
            pendingDropX = edgeX
            step = .approach(x: edgeX, running: false)

        case .ground(let x):
            // Walk to the nearest edge of the current surface and drop off.
            step = .peek(until: Date().addingTimeInterval(0.55))
            pendingDropX = x

        case .platform(let rect):
            let landing = landingPoint(on: rect)
            // Already there, or the "jump" would barely move him — either way
            // there is nothing worth watching. (Seen live: a LAUNCH with
            // v=(0,514) that landed exactly where it started.)
            if abs(sim.feet.y - landing.y) < 24, abs(sim.feet.x - landing.x) < 60 {
                step = .settle(until: Date().addingTimeInterval(0.3))
                return
            }
            if let v = sim.solveJump(from: sim.feet, to: landing),
               sim.isArcClear(from: sim.feet, velocity: v, to: landing) {
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

        case .trafficLight(let rect):
            // Land *exactly* on the yellow light — the accuracy is the
            // joke. Falls back to the plain platform plan if the window
            // moved away mid-approach.
            let button = CGPoint(x: rect.minX + Self.trafficLightInsetX, y: rect.maxY)
            if abs(sim.feet.y - button.y) < 24, abs(sim.feet.x - button.x) < 24 {
                // Already standing on the light — go straight to the beat.
                pendingPrankWindow = rect
                onEvent?(.minimizePrankArrived(window: rect))
                step = .settle(until: Date().addingTimeInterval(0.5))
                return
            }
            if let v = sim.solveJump(from: sim.feet, to: button),
               sim.isArcClear(from: sim.feet, velocity: v, to: button) {
                pendingPrankWindow = rect
                step = .crouch(until: Date().addingTimeInterval(0.16), target: button)
            } else {
                // The prank needs a precise direct leap; from here there
                // isn't one, so this window gets skipped entirely rather
                // than degraded into a plain climb.
                pendingPrankWindow = nil
                step = .settle(until: Date().addingTimeInterval(0.3))
            }
        }
    }

    /// A point just inside the near wall of `rect`, as high up it as one leap
    /// can manage, aimed so Bill is already descending when he makes contact
    /// (only a descending contact becomes a grab, never a walk-into).
    private func sideGrabTarget(for rect: CGRect) -> CGPoint? {
        // A wall is only caught by crossing it *inward* while descending (see
        // `GravitySimulator.resolveHorizontal`). That means Bill has to start
        // outside the window on the side he is aiming at.
        //
        // This used to pick the wall from `feet.x < rect.midX`, which is a
        // different question entirely: standing *inside* a wide window's
        // x-range, it happily aimed at the far side of the wall he was already
        // past, so the arc crossed outward, no grab ever fired, and he sailed
        // off the edge and fell. Observed as `LAUNCH to (53,429)` from x=321
        // landing back on the floor at x=16.
        let hw = sim.physics.bodyWidth * sim.scale / 2
        let wallX: CGFloat
        let aimX: CGFloat
        if sim.feet.x <= rect.minX - hw {
            wallX = rect.minX
            aimX = wallX + 8                 // cross the left wall going right
        } else if sim.feet.x >= rect.maxX + hw {
            wallX = rect.maxX
            aimX = wallX - 8                 // cross the right wall going left
        } else {
            // Already under/inside its span — there is no wall to catch from
            // here. Walking out is handled by the approach fallback.
            return nil
        }
        // As high up the wall as one leap manages, but clear of both ends.
        let ceiling = sim.feet.y + sim.maxReachableRise * 0.9
        let y = min(rect.maxY - 40, ceiling)
        guard y > rect.minY + 24, y > sim.feet.y + 40 else { return nil }
        let target = CGPoint(x: aimX, y: y)
        guard let v = sim.solveJump(from: sim.feet, to: target),
              sim.isArcClear(from: sim.feet, velocity: v, to: target) else { return nil }
        _ = wallX
        return target
    }

    /// The surface Bill is currently standing on, if it is a window rather
    /// than the screen floor.
    private func currentLedge() -> CGRect? {
        sim.solids
            .map(\.rect)
            .first { abs($0.maxY - sim.feet.y) < 3 && sim.feet.x >= $0.minX - 40 && sim.feet.x <= $0.maxX + 40 }
    }

    /// The closest landing spot on a ledge, rather than its centre.
    ///
    /// Aiming at `rect.midX` made wide windows unreachable for no good reason:
    /// a window spanning x=84...1007 was measured as 1117pt away from Bill at
    /// x=1663, well past the horizontal launch envelope, when its near edge was
    /// only 656pt away. Two of the four windows on screen were rejected purely
    /// because of this. He lands on the near end and can walk along afterwards.
    private func landingPoint(on rect: CGRect) -> CGPoint {
        let inset = min(40, rect.width / 3)
        let x = min(max(sim.feet.x, rect.minX + inset), rect.maxX - inset)
        return CGPoint(x: x, y: rect.maxY)
    }

    /// Guards against re-planning the same unreachable goal every tick.
    ///
    /// `.approach` re-plans on arrival, and if the platform still cannot be
    /// solved from the new position the planner hands back the *same* approach
    /// point — so the beat span until `beatTimeout` doing nothing visible.
    private var replanCount = 0
    private var strollLegs = 0
    private static let maxReplans = 4

    // MARK: - Contact with moving windows
    //
    // Windows are solid, so a window that *moves into Bill* should knock him
    // out of the way rather than passing through him. That needs geometry
    // sampled often enough to catch the motion, which the 1.5s topology cache
    // deliberately does not provide — so this keeps its own fresh, small poll.

    private var contactTimer: Timer?
    private var previousRects: [Int: CGRect] = [:]
    /// ~5.5Hz. Fast enough that a dragged window visibly shoves him, slow
    /// enough to stay a rounding error next to the render loop.
    private static let contactInterval: TimeInterval = 0.18
    /// How hard a shove throws him, per point of window movement.
    private static let shoveGain: CGFloat = 7.5
    private static let maxShoveSpeed: CGFloat = 900
    /// Below this a window "move" is a resize jitter, not a shove.
    private static let minShoveDelta: CGFloat = 3
    private var lastShoveAt = Date.distantPast
    private static let shoveCooldown: TimeInterval = 0.9

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
        log("end feet=(\(Int(sim.feet.x)),\(Int(sim.feet.y))) grounded=\(sim.isGrounded)")
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
            log("event \(event) at (\(Int(sim.feet.x)),\(Int(sim.feet.y)))")
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
                    // Reached the lip of a deliberate drop: lean out and look
                    // down before committing, then let gravity do the rest.
                    if case .dropOff = goal {
                        step = .peek(until: Date().addingTimeInterval(0.7))
                        return
                    }
                    // Re-plan: either we have arrived, or we walked close
                    // enough that the jump is now solvable.
                    if case .stroll = goal {
                        // Chain another leg rather than stopping dead at the
                        // first target — one short hop reads as a twitch, a
                        // few in sequence read as pacing around.
                        strollLegs += 1
                        if strollLegs < Int.random(in: 2...4),
                           let screen = screenForBill() {
                            let visible = screen.visibleFrame
                            let span = CGFloat.random(in: 120...380) * (Bool.random() ? 1 : -1)
                            let nextX = min(max(sim.feet.x + span, visible.minX + 40), visible.maxX - 40)
                            goal = .stroll(x: nextX)
                            step = .approach(x: nextX, running: abs(span) > 300)
                        } else {
                            step = .settle(until: Date().addingTimeInterval(0.4))
                        }
                    } else {
                        replanCount += 1
                        if replanCount > Self.maxReplans {
                            log("giving up on goal after \(replanCount) replans")
                            step = .settle(until: Date().addingTimeInterval(0.3))
                        } else {
                            planNextStep()
                        }
                    }
                }
                return
            }
            sim.walk(direction: delta, running: running)

        case .crouch(let until, let target):
            sim.stop()
            if Date() >= until { step = .launch(target: target) }

        case .launch(let target):
            if sim.jump(to: target) {
                log("LAUNCH to (\(Int(target.x)),\(Int(target.y))) v=(\(Int(sim.velocity.dx)),\(Int(sim.velocity.dy)))")
                step = .airborne
            } else {
                log("launch FAILED (target moved or unreachable) - replanning")
                // The window moved or closed between planning and launching.
                planNextStep()
            }

        case .airborne:
            break

        case .peek(let until):
            sim.stop()
            applyState(.edgePeek)
            guard Date() >= until else { return }
            if case .dropOff = goal {
                // Commit. Releasing sets him falling from exactly here.
                sim.release()
                step = .airborne
                pendingDropX = nil
                log("DROP from (\(Int(sim.feet.x)),\(Int(sim.feet.y)))")
                return
            }
            if let x = pendingDropX {
                step = .approach(x: x, running: false)
                pendingDropX = nil
            } else {
                step = .settle(until: Date().addingTimeInterval(0.3))
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
                if let prankWindow = pendingPrankWindow {
                    // The landing is the prank: he is standing on the yellow
                    // light. Hand the beat to the press sequence.
                    pendingPrankWindow = nil
                    onEvent?(.minimizePrankArrived(window: prankWindow))
                    step = .settle(until: Date().addingTimeInterval(0.5))
                } else {
                    step = .settle(until: Date().addingTimeInterval(0.45))
                }
            }
        case .grabbedLedge:
            step = .climb(direction: 1)
        case .minimizePrankArrived:
            // Fired outward only — the sim itself has nothing to do here.
            break
        case .walkedOffEdge:
            step = .airborne
        case .bonkedHead:
            break
        case .shoved:
            // The contact watcher has already put him in flight; the beat just
            // needs to let gravity finish the job.
            step = .airborne
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
