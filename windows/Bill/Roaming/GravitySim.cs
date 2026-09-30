using System;
using System.Collections.Generic;

namespace Bill.Roaming;

/// <summary>
/// Port of the Mac side's `GravitySimulator` — a value-semantics platformer
/// simulation with an explicit `Step(dt)`, deliberately free of any
/// windowing framework so the physics can be reasoned about in isolation.
/// Everything is in *logical* screen coordinates: bottom-left origin,
/// Y up, measured in pixels and pixels-per-second — the Win32/WPF layer
/// converts at its boundaries, never in here.
/// </summary>
public sealed class GravitySim
{
    // --- Tunables, transcribed verbatim from RoamPhysics (scale 1). ---
    public const float Gravity = 2000;
    public const float WalkSpeed = 72;
    public const float RunSpeed = 155;
    public const float ClimbSpeed = 95;
    public const float TerminalVelocity = 1500;
    public const float MaxLaunchSpeedX = 520;
    public const float MaxLaunchSpeedY = 1900;
    public const float ApexClearance = 46;
    public const double CoyoteTime = 0.09;
    public const float LedgeGrabReach = 14;
    public const float HardLandingSpeed = 780;
    public const float SurfaceTolerance = 2.5f;
    public const float BodyWidth = 64;
    public const float BodyHeight = 122;

    public const double Timestep = 1.0 / 60.0;
    private const int MaxSolverSteps = 500;

    /// What the simulation is doing right now; the roaming controller maps
    /// these onto sprite clips.
    public enum Motion
    {
        Resting, Walking, Crouching, Launching, Rising, Falling,
        LedgeGrab, Climbing, Hanging, Landing,
    }

    /// One-shot things that happened during a `Step`.
    public enum RoamEvent
    {
        LandedSoft, LandedHard, GrabbedLedge, BonkedHead,
        WalkedOffEdge, ReachedGoal, FellOffWorld, Shoved,
    }

    /// A solid, reduced to geometry; the world bounds are never grabbed.
    public readonly struct Solid
    {
        public Solid(float minX, float minY, float maxX, float maxY, bool isWorldBounds = false)
        {
            MinX = minX; MinY = minY; MaxX = maxX; MaxY = maxY;
            IsWorldBounds = isWorldBounds;
        }
        public float MinX { get; }
        public float MinY { get; }
        public float MaxX { get; }
        public float MaxY { get; }
        public bool IsWorldBounds { get; }
    }

    public struct Vec2
    {
        public float X, Y;
        public Vec2(float x, float y) { X = x; Y = y; }
    }

    public float FeetX { get; private set; }
    public float FeetY { get; private set; }
    public Vec2 Velocity { get; private set; }
    public Motion CurrentMotion { get; private set; } = Motion.Resting;
    public bool IsGrounded { get; private set; }

    /// Multiplies every length so the simulation stays proportional to the
    /// on-screen sprite scale (2x on the Windows side).
    public float Scale { get; set; } = 1f;

    /// Solids plus the world bounds; rebuilt by the controller per beat.
    public List<Solid> Solids { get; } = new();
    /// The walkable rect (work area), bottom-left origin Y-up.
    public float WorldMinX { get; set; }
    public float WorldMinY { get; set; }
    public float WorldMaxX { get; set; }
    public float WorldMaxY { get; set; }

    private double _timeSinceGrounded;
    private float _fallStartY;
    private readonly List<RoamEvent> _pending = new();
    private Solid? _grabbedSolid;
    private double _stuckSeconds;
    private const double StuckThreshold = 6.0;

    private float HalfWidth => BodyWidth * Scale / 2;
    private float Height => BodyHeight * Scale;

    // --- Placement ---

    public void Place(float x, float y, bool grounded)
    {
        FeetX = x;
        FeetY = y;
        if (grounded)
        {
            // Snap exactly onto the nearest surface so the landing and
            // grounded tests can never disagree by a rounding error.
            var best = WorldMinY;
            var bestDist = Math.Abs(y - WorldMinY);
            foreach (var s in Solids)
            {
                var d = Math.Abs(s.MaxY - y);
                if (d < bestDist) { bestDist = d; best = s.MaxY; }
            }
            if (bestDist <= SurfaceTolerance * Scale) FeetY = best;
        }
        Velocity = new Vec2(0, 0);
        IsGrounded = grounded;
        CurrentMotion = grounded ? Motion.Resting : Motion.Falling;
        _timeSinceGrounded = 0;
        _fallStartY = y;
        _grabbedSolid = null;
    }

    // --- Commands ---

    public void Walk(float direction, bool running = false)
    {
        if (!IsGrounded) return;
        var speed = (running ? RunSpeed : WalkSpeed) * Scale;
        Velocity = new Vec2(direction >= 0 ? speed : -speed, Velocity.Y);
        CurrentMotion = Motion.Walking;
    }

    public void Stop()
    {
        Velocity = new Vec2(0, Velocity.Y);
        if (IsGrounded) CurrentMotion = Motion.Resting;
    }

    /// Solves the ballistic arc to `target` and commits to it. The math:
    /// with `g` the gravity and `h` the peak above the start,
    /// vy0 = sqrt(2gh), t_up = vy0/g, and the fall from peak to target
    /// takes t_down = sqrt(2(h-dy)/g); horizontal speed is dx over the
    /// *discrete* flight time — counted by running the exact integrator
    /// forward, because semi-implicit Euler lands slightly short of the
    /// closed-form time (the Mac side's fix, kept verbatim).
    public bool Jump(float targetX, float targetY)
    {
        if (!IsGrounded && _timeSinceGrounded > CoyoteTime) return false;
        var solution = SolveJump(FeetX, FeetY, targetX, targetY);
        if (solution == null) return false;
        Velocity = solution.Value;
        IsGrounded = false;
        CurrentMotion = Motion.Launching;
        _fallStartY = FeetY;
        _grabbedSolid = null;
        return true;
    }

    public Vec2? SolveJump(float startX, float startY, float targetX, float targetY)
    {
        var g = Gravity * Scale;
        var dx = targetX - startX;
        var dy = targetY - startY;
        var peak = Math.Max(dy, 0) + ApexClearance * Scale;
        if (peak <= 0) return null;

        var vy0 = MathF.Sqrt(2 * g * peak);
        if (vy0 > MaxLaunchSpeedY * Scale) return null;

        // Count discrete ticks the arc will really take.
        var dt = (float)Timestep;
        var vy = vy0;
        var y = 0f;
        float? flight = null;
        for (var step = 1; step <= MaxSolverSteps; step++)
        {
            var previousY = y;
            vy -= g * dt;
            y += vy * dt;
            if (vy <= 0 && previousY >= dy && y <= dy)
            {
                flight = step * dt;
                break;
            }
        }
        if (flight is not > 0.01f) return null;

        var vx = dx / flight.Value;
        if (MathF.Abs(vx) > MaxLaunchSpeedX * Scale) return null;
        return new Vec2(vx, vy0);
    }

    /// Traces the solved arc and reports whether anything is in the way —
    /// rising into an underside is the only thing that stops a jump,
    /// mirroring ResolveRising so prediction matches integration.
    public bool IsArcClear(float startX, float startY, Vec2 v, float targetX, float targetY)
    {
        var g = Gravity * Scale;
        var dt = (float)Timestep;
        var hw = HalfWidth;
        var h = Height;

        var startBoxMinY = startY;
        var startBoxMaxY = startY + h;
        var obstacles = new List<Solid>();
        foreach (var s in Solids)
        {
            if (s.IsWorldBounds) continue;
            var overlaps = startX + hw > s.MinX && startX - hw < s.MaxX
                        && startBoxMaxY > s.MinY && startBoxMinY < s.MaxY;
            if (!overlaps) obstacles.Add(s);
        }

        var px = startX;
        var py = startY;
        var vy = v.Y;
        var head = py + h;
        for (var i = 0; i < MaxSolverSteps; i++)
        {
            var previousHead = head;
            vy -= g * dt;
            px += v.X * dt;
            py += vy * dt;
            head = py + h;
            if (vy <= 0 && py <= targetY + 1) return true;
            if (py >= WorldMaxY) return false;
            foreach (var s in obstacles)
            {
                if (px + hw <= s.MinX || px - hw >= s.MaxX) continue;
                if (previousHead <= s.MinY && head >= s.MinY) return false;
            }
        }
        return false;
    }

    /// The highest a single leap can climb; above this, side-grab and climb.
    public float MaxReachableRise
    {
        get
        {
            var peak = MaxLaunchSpeedY * MaxLaunchSpeedY / (2 * Gravity);
            return (peak - ApexClearance) * Scale;
        }
    }

    public void Climb(float direction)
    {
        if (_grabbedSolid == null) return;
        Velocity = new Vec2(0, direction * ClimbSpeed * Scale);
        CurrentMotion = Motion.Climbing;
    }

    /// Knocked off his feet by an impulse — a window sweeping into him.
    public void Shove(Vec2 impulse)
    {
        _grabbedSolid = null;
        IsGrounded = false;
        Velocity = impulse;
        CurrentMotion = impulse.Y > 0 ? Motion.Rising : Motion.Falling;
        _fallStartY = FeetY;
        _timeSinceGrounded = 0;
    }

    /// Carried along by a surface that moved under him.
    public void Ride(float dx) => FeetX += dx;

    /// Let go of a wall and fall.
    public void Release()
    {
        _grabbedSolid = null;
        Velocity = new Vec2(0, 0);
        IsGrounded = false;
        CurrentMotion = Motion.Falling;
        _fallStartY = FeetY;
    }

    /// Frees him only when actually clinging — `Release()` alone would
    /// un-ground a resting Bill (the Mac side's lesson).
    public void ReleaseIfHanging()
    {
        if (_grabbedSolid != null) Release();
    }

    // --- Integration ---

    /// Advances the simulation and returns everything notable that
    /// happened. Swept collision against the previous position so a fast
    /// fall can never tunnel through a thin ledge between frames.
    public IReadOnlyList<RoamEvent> Step(double dt)
    {
        _pending.Clear();
        var d = (float)dt;
        Watchdog(dt);

        if (_grabbedSolid != null)
        {
            StepClimbing(d);
            return _pending;
        }

        if (IsGrounded)
        {
            _timeSinceGrounded = 0;
        }
        else
        {
            _timeSinceGrounded += dt;
            var vy = Velocity.Y - Gravity * Scale * d;
            vy = MathF.Max(vy, -TerminalVelocity * Scale);
            Velocity = new Vec2(Velocity.X, vy);
        }

        var (prevX, prevY) = (FeetX, FeetY);
        var nextX = FeetX + Velocity.X * d;
        var nextY = FeetY + Velocity.Y * d;

        nextX = ResolveHorizontal(prevX, prevY, nextX);

        if (Velocity.Y <= 0)
        {
            ResolveFalling(prevX, prevY, ref nextX, ref nextY);
        }
        else
        {
            ResolveRising(prevX, prevY, ref nextX, ref nextY);
        }

        FeetX = nextX;
        FeetY = nextY;
        ClampToWorld();
        UpdateMotion();
        return _pending;
    }

    private void StepClimbing(float d)
    {
        if (_grabbedSolid == null) return;
        var solid = _grabbedSolid.Value;
        FeetY += Velocity.Y * d;
        if (FeetY + Height >= solid.MaxY)
        {
            // Reached the top of the wall: step onto the ledge, let go.
            FeetY = solid.MaxY;
            _grabbedSolid = null;
            IsGrounded = true;
            Velocity = new Vec2(0, 0);
            CurrentMotion = Motion.Landing;
            _pending.Add(RoamEvent.LandedSoft);
            return;
        }
        if (FeetY <= solid.MinY - Height * 0.4f)
        {
            Release();
            return;
        }
        if (Velocity.Y == 0) CurrentMotion = Motion.Hanging;
    }

    /// Catches a window's side on the way past it — a grab, never a barrier
    /// (the Mac side's reasoning: a wall beside a grounded Bill is a
    /// window he is visually in front of, not something he should collide
    /// with). Only an airborne *descending* crossing inward catches.
    private float ResolveHorizontal(float previousX, float previousY, float nextX)
    {
        if (nextX == previousX || IsGrounded || Velocity.Y >= 0) return nextX;

        var top = previousY + Height;
        foreach (var s in Solids)
        {
            if (s.IsWorldBounds) continue;
            if (previousY >= s.MaxY || top <= s.MinY) continue;
            var movingRight = nextX > previousX;
            var leadingBefore = movingRight ? previousX + HalfWidth : previousX - HalfWidth;
            var leadingAfter = movingRight ? nextX + HalfWidth : nextX - HalfWidth;
            var wall = movingRight ? s.MinX : s.MaxX;
            var crossed = movingRight
                ? leadingBefore <= wall && leadingAfter >= wall
                : leadingBefore >= wall && leadingAfter <= wall;
            if (!crossed) continue;
            _grabbedSolid = s;
            Velocity = new Vec2(0, 0);
            CurrentMotion = Motion.LedgeGrab;
            _pending.Add(RoamEvent.GrabbedLedge);
            return movingRight ? wall - HalfWidth : wall + HalfWidth;
        }
        return nextX;
    }

    /// Swept downward collision: lands on the highest ledge crossed between
    /// the previous and next positions.
    private void ResolveFalling(float previousX, float previousY, ref float nextX, ref float nextY)
    {
        float? landingY = null;
        foreach (var s in Solids)
        {
            if (nextX + HalfWidth <= s.MinX || nextX - HalfWidth >= s.MaxX) continue;
            var ledge = s.MaxY;
            var slack = SurfaceTolerance * Scale;
            if (previousY < ledge - slack || nextY > ledge) continue;
            if (landingY == null || ledge > landingY) landingY = ledge;
        }
        var floor = WorldMinY;
        if (nextX + HalfWidth > WorldMinX && nextX - HalfWidth < WorldMaxX
            && previousY >= floor - SurfaceTolerance * Scale && nextY <= floor)
        {
            if (landingY == null || floor > landingY) landingY = floor;
        }

        if (landingY == null)
        {
            if (IsGrounded)
            {
                IsGrounded = false;
                _fallStartY = previousY;
                _pending.Add(RoamEvent.WalkedOffEdge);
            }
            return;
        }

        var impact = MathF.Abs(Velocity.Y);
        var dropped = MathF.Max(0, _fallStartY - landingY.Value);
        nextY = landingY.Value;
        Velocity = new Vec2(Velocity.X, 0);
        if (!IsGrounded)
        {
            IsGrounded = true;
            var hard = impact >= HardLandingSpeed * Scale;
            CurrentMotion = Motion.Landing;
            _pending.Add(hard ? RoamEvent.LandedHard : RoamEvent.LandedSoft);
            LastDropHeight = dropped;
        }
    }

    /// Height of the most recent landing's drop, for hard-landing barks.
    public float LastDropHeight { get; private set; }

    /// Swept upward collision against the underside of windows.
    private void ResolveRising(float previousX, float previousY, ref float nextX, ref float nextY)
    {
        var headBefore = previousY + Height;
        var headAfter = nextY + Height;
        foreach (var s in Solids)
        {
            if (s.IsWorldBounds) continue;
            if (nextX + HalfWidth <= s.MinX || nextX - HalfWidth >= s.MaxX) continue;
            // Fully underneath before, reaching the underside now — a
            // window in front of him can never bonk him.
            if (headBefore > s.MinY || headAfter < s.MinY) continue;
            nextY = s.MinY - Height;
            Velocity = new Vec2(Velocity.X, 0);
            _pending.Add(RoamEvent.BonkedHead);
            return;
        }
        // The ceiling constrains his FEET, not his head — the same reasoning
        // as the Mac side: the hat may poke above the walkable top.
        if (nextY >= WorldMaxY)
        {
            nextY = WorldMaxY;
            Velocity = new Vec2(Velocity.X, 0);
            _pending.Add(RoamEvent.BonkedHead);
        }
    }

    private void ClampToWorld()
    {
        if (FeetX - HalfWidth < WorldMinX)
        {
            FeetX = WorldMinX + HalfWidth;
            if (Velocity.X < 0) Velocity = new Vec2(0, Velocity.Y);
        }
        if (FeetX + HalfWidth > WorldMaxX)
        {
            FeetX = WorldMaxX - HalfWidth;
            if (Velocity.X > 0) Velocity = new Vec2(0, Velocity.Y);
        }
        if (FeetY < WorldMinY - Height)
        {
            FeetY = WorldMinY;
            Velocity = new Vec2(0, 0);
            IsGrounded = true;
            _pending.Add(RoamEvent.FellOffWorld);
        }
    }

    private void UpdateMotion()
    {
        if (_grabbedSolid != null) return;
        if (CurrentMotion == Motion.Landing) return;
        if (IsGrounded)
        {
            CurrentMotion = Velocity.X == 0 ? Motion.Resting : Motion.Walking;
        }
        else
        {
            CurrentMotion = Velocity.Y > 0 ? Motion.Rising : Motion.Falling;
        }
    }

    /// The never-stuck guarantee, ported: clinging without climbing, or
    /// airborne with ~zero velocity, for six seconds force-releases him.
    private void Watchdog(double dt)
    {
        var airborne = !IsGrounded;
        var frozen = MathF.Abs(Velocity.X) < 1 && MathF.Abs(Velocity.Y) < 1;
        var clinging = _grabbedSolid != null;
        if (clinging || (airborne && frozen))
        {
            _stuckSeconds += dt;
            if (_stuckSeconds > StuckThreshold)
            {
                _stuckSeconds = 0;
                Release();
                _pending.Add(RoamEvent.WalkedOffEdge);
            }
        }
        else
        {
            _stuckSeconds = 0;
        }
    }
}
