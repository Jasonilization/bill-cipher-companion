// Port of Roaming/GravitySimulator.swift — pure platformer physics.
//
// Coordinates are the Mac app's: origin bottom-left, Y up, in points
// (device-independent pixels here) and points per second. The window layer
// flips to the top-left space Windows and X11 use, so this file is a
// line-for-line port and behaves identically.

const rect = (x, y, w, h) => ({ x, y, w, h });
const minX = (r) => r.x; const maxX = (r) => r.x + r.w;
const minY = (r) => r.y; const maxY = (r) => r.y + r.h;
const midX = (r) => r.x + r.w / 2;
const intersects = (a, b) => a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h;
function intersection(a, b) {
  const x = Math.max(a.x, b.x); const y = Math.max(a.y, b.y);
  const w = Math.min(maxX(a), maxX(b)) - x; const h = Math.min(maxY(a), maxY(b)) - y;
  return w > 0 && h > 0 ? rect(x, y, w, h) : null;
}

const PHYSICS = {
  gravity: 2000, walkSpeed: 72, runSpeed: 155, climbSpeed: 95, terminalVelocity: 1500,
  maxLaunchSpeedX: 520, maxLaunchSpeedY: 1900, apexClearance: 46, coyoteTime: 0.09,
  ledgeGrabReach: 14, hardLandingSpeed: 780, surfaceTolerance: 2.5, bodyWidth: 64, bodyHeight: 122,
};

const TIMESTEP = 1 / 60;
const MAX_SOLVER_STEPS = 500;
const STUCK_THRESHOLD = 6;

class GravitySimulator {
  constructor() {
    this.feet = { x: 0, y: 0 };
    this.velocity = { dx: 0, dy: 0 };
    this.motion = { kind: 'resting' };
    this.isGrounded = false;
    this.physics = { ...PHYSICS };
    this.scale = 1;
    this.solids = [];            // [{ rect, isWorldBounds }] front-to-back
    this.worldBounds = rect(0, 0, 0, 0);
    this.timeSinceGrounded = 0;
    this.fallStartY = 0;
    this.pendingEvents = [];
    this.grabbedSolid = null;
    this.stuckSeconds = 0;
  }

  get halfWidth() { return (this.physics.bodyWidth * this.scale) / 2; }
  get height() { return this.physics.bodyHeight * this.scale; }

  place(point, grounded) {
    this.feet = { x: point.x, y: point.y };
    if (grounded) {
      const surfaces = this.solids.map((s) => maxY(s.rect)).concat([minY(this.worldBounds)]);
      let nearest = surfaces[0];
      for (const s of surfaces) if (Math.abs(s - point.y) < Math.abs(nearest - point.y)) nearest = s;
      if (Math.abs(nearest - point.y) <= this.physics.surfaceTolerance * this.scale) this.feet.y = nearest;
    }
    this.velocity = { dx: 0, dy: 0 };
    this.isGrounded = grounded;
    this.motion = { kind: grounded ? 'resting' : 'falling' };
    this.timeSinceGrounded = 0;
    this.fallStartY = point.y;
    this.grabbedSolid = null;
  }

  walk(direction, running = false) {
    if (!this.isGrounded) return;
    const speed = (running ? this.physics.runSpeed : this.physics.walkSpeed) * this.scale;
    this.velocity.dx = direction >= 0 ? speed : -speed;
    this.motion = { kind: 'walking', dx: this.velocity.dx };
  }

  stop() {
    this.velocity.dx = 0;
    if (this.isGrounded) this.motion = { kind: 'resting' };
  }

  jump(target) {
    if (!(this.isGrounded || this.timeSinceGrounded <= this.physics.coyoteTime)) return false;
    const solution = this.solveJump(this.feet, target);
    if (!solution) return false;
    this.velocity = solution;
    this.isGrounded = false;
    this.motion = { kind: 'launching' };
    this.fallStartY = this.feet.y;
    this.grabbedSolid = null;
    return true;
  }

  /** Traces the solved arc and reports whether a window's underside is in the way. */
  isArcClear(start, v, target) {
    const g = this.physics.gravity * this.scale;
    const dt = TIMESTEP; const hw = this.halfWidth; const h = this.height;
    const startBox = rect(start.x - hw, start.y, hw * 2, h);
    const obstacles = this.solids.filter((s) => !s.isWorldBounds && !intersects(s.rect, startBox));
    const p = { x: start.x, y: start.y };
    let vy = v.dy; let head = p.y + h;
    for (let i = 0; i < MAX_SOLVER_STEPS; i++) {
      const previousHead = head;
      vy -= g * dt;
      p.x += v.dx * dt;
      p.y += vy * dt;
      head = p.y + h;
      if (vy <= 0 && p.y <= target.y + 1) return true;
      if (p.y >= maxY(this.worldBounds)) return false;
      for (const solid of obstacles) {
        const r = solid.rect;
        if (!(p.x + hw > minX(r) && p.x - hw < maxX(r))) continue;
        if (previousHead <= minY(r) && head >= minY(r)) return false;
      }
    }
    return false;
  }

  get maxReachableRise() {
    const peak = (this.physics.maxLaunchSpeedY * this.physics.maxLaunchSpeedY) / (2 * this.physics.gravity);
    return (peak - this.physics.apexClearance) * this.scale;
  }

  /** null when the arc is outside the launch envelope. Uses the same discrete integrator as step(). */
  solveJump(start, target) {
    const g = this.physics.gravity * this.scale;
    const dx = target.x - start.x; const dy = target.y - start.y;
    const peak = Math.max(dy, 0) + this.physics.apexClearance * this.scale;
    if (!(peak > 0)) return null;
    const vy0 = Math.sqrt(2 * g * peak);
    if (vy0 > this.physics.maxLaunchSpeedY * this.scale) return null;
    const dt = TIMESTEP;
    let vy = vy0; let y = 0; let flight = null;
    for (let step = 1; step <= MAX_SOLVER_STEPS; step++) {
      const previousY = y;
      vy -= g * dt;
      y += vy * dt;
      if (vy <= 0 && previousY >= dy && y <= dy) { flight = step * dt; break; }
    }
    if (flight === null || flight <= 0.01) return null;
    const vx = dx / flight;
    if (Math.abs(vx) > this.physics.maxLaunchSpeedX * this.scale) return null;
    return { dx: vx, dy: vy0 };
  }

  climb(direction) {
    if (!this.grabbedSolid) return;
    this.velocity = { dx: 0, dy: direction * this.physics.climbSpeed * this.scale };
    this.motion = { kind: 'climbing', dy: this.velocity.dy };
  }

  shove(impulse) {
    this.grabbedSolid = null;
    this.isGrounded = false;
    this.velocity = { dx: impulse.dx, dy: impulse.dy };
    this.motion = { kind: impulse.dy > 0 ? 'rising' : 'falling' };
    this.fallStartY = this.feet.y;
    this.timeSinceGrounded = 0;
  }

  ride(dx) { this.feet.x += dx; }

  release() {
    this.grabbedSolid = null;
    this.velocity = { dx: 0, dy: 0 };
    this.isGrounded = false;
    this.motion = { kind: 'falling' };
    this.fallStartY = this.feet.y;
  }

  releaseIfHanging() { if (this.grabbedSolid) this.release(); }

  watchdog(dt) {
    const airborne = !this.isGrounded;
    const frozen = Math.abs(this.velocity.dx) < 1 && Math.abs(this.velocity.dy) < 1;
    if (this.grabbedSolid || (airborne && frozen)) {
      this.stuckSeconds += dt;
      if (this.stuckSeconds > STUCK_THRESHOLD) {
        this.stuckSeconds = 0;
        this.release();
        this.pendingEvents.push({ kind: 'walkedOffEdge' });
      }
    } else this.stuckSeconds = 0;
  }

  step(dt) {
    this.pendingEvents = [];
    this.watchdog(dt);
    if (this.grabbedSolid) { this.stepClimbing(dt); return this.pendingEvents; }

    if (this.isGrounded) this.timeSinceGrounded = 0;
    else {
      this.timeSinceGrounded += dt;
      this.velocity.dy -= this.physics.gravity * this.scale * dt;
      this.velocity.dy = Math.max(this.velocity.dy, -this.physics.terminalVelocity * this.scale);
    }

    const previous = { x: this.feet.x, y: this.feet.y };
    const next = { x: this.feet.x + this.velocity.dx * dt, y: this.feet.y + this.velocity.dy * dt };
    next.x = this.resolveHorizontal(previous, next);
    if (this.velocity.dy <= 0) this.resolveFalling(previous, next);
    else this.resolveRising(previous, next);

    this.feet = next;
    this.clampToWorld();
    this.updateMotion();
    return this.pendingEvents;
  }

  stepClimbing(d) {
    const solid = this.grabbedSolid;
    this.feet.y += this.velocity.dy * d;
    if (this.feet.y + this.height >= maxY(solid)) {
      this.feet.y = maxY(solid);
      this.grabbedSolid = null;
      this.isGrounded = true;
      this.velocity = { dx: 0, dy: 0 };
      this.motion = { kind: 'landing', hard: false };
      this.pendingEvents.push({ kind: 'landed', hard: false, fromHeight: 0 });
      return;
    }
    if (this.feet.y <= minY(solid) - this.height * 0.4) { this.release(); return; }
    if (this.velocity.dy === 0) this.motion = { kind: 'hanging' };
  }

  /** A window's side is only ever a grab (while descending past it), never a barrier. */
  resolveHorizontal(previous, next) {
    if (next.x === previous.x || this.isGrounded || !(this.velocity.dy < 0)) return next.x;
    const top = previous.y + this.height; const hw = this.halfWidth;
    for (const solid of this.solids) {
      if (solid.isWorldBounds) continue;
      const r = solid.rect;
      if (!(previous.y < maxY(r) && top > minY(r))) continue;
      const movingRight = next.x > previous.x;
      const leadingBefore = movingRight ? previous.x + hw : previous.x - hw;
      const leadingAfter = movingRight ? next.x + hw : next.x - hw;
      const wall = movingRight ? minX(r) : maxX(r);
      const crossed = movingRight ? (leadingBefore <= wall && leadingAfter >= wall) : (leadingBefore >= wall && leadingAfter <= wall);
      if (!crossed) continue;
      this.grabbedSolid = r;
      this.velocity = { dx: 0, dy: 0 };
      this.motion = { kind: 'ledgeGrab' };
      this.pendingEvents.push({ kind: 'grabbedLedge' });
      return movingRight ? wall - hw : wall + hw;
    }
    return next.x;
  }

  /** Swept downward collision: lands on the highest ledge crossed this tick. */
  resolveFalling(previous, next) {
    const hw = this.halfWidth; const slack = this.physics.surfaceTolerance * this.scale;
    let landingY = null;
    for (const solid of this.solids) {
      const r = solid.rect;
      if (!(next.x + hw > minX(r) && next.x - hw < maxX(r))) continue;
      const ledge = maxY(r);
      if (!(previous.y >= ledge - slack && next.y <= ledge)) continue;
      if (landingY === null || ledge > landingY) landingY = ledge;
    }
    const floor = minY(this.worldBounds);
    if (next.x + hw > minX(this.worldBounds) && next.x - hw < maxX(this.worldBounds) && previous.y >= floor - slack && next.y <= floor) {
      if (landingY === null || floor > landingY) landingY = floor;
    }
    if (landingY === null) {
      if (this.isGrounded) {
        this.isGrounded = false;
        this.fallStartY = previous.y;
        this.pendingEvents.push({ kind: 'walkedOffEdge' });
      }
      return;
    }
    const impact = Math.abs(this.velocity.dy);
    const dropped = Math.max(0, this.fallStartY - landingY);
    next.y = landingY;
    this.velocity.dy = 0;
    if (!this.isGrounded) {
      this.isGrounded = true;
      const hard = impact >= this.physics.hardLandingSpeed * this.scale;
      this.motion = { kind: 'landing', hard };
      this.pendingEvents.push({ kind: 'landed', hard, fromHeight: dropped });
    }
  }

  /** Swept upward collision against window undersides; the ceiling constrains his feet, not his hat. */
  resolveRising(previous, next) {
    const hw = this.halfWidth;
    const headBefore = previous.y + this.height; const headAfter = next.y + this.height;
    for (const solid of this.solids) {
      if (solid.isWorldBounds) continue;
      const r = solid.rect;
      if (!(next.x + hw > minX(r) && next.x - hw < maxX(r))) continue;
      if (!(headBefore <= minY(r) && headAfter >= minY(r))) continue;
      next.y = minY(r) - this.height;
      this.velocity.dy = 0;
      this.pendingEvents.push({ kind: 'bonkedHead' });
      return;
    }
    if (next.y >= maxY(this.worldBounds)) {
      next.y = maxY(this.worldBounds);
      this.velocity.dy = 0;
      this.pendingEvents.push({ kind: 'bonkedHead' });
    }
  }

  clampToWorld() {
    const hw = this.halfWidth; const wb = this.worldBounds;
    if (this.feet.x - hw < minX(wb)) { this.feet.x = minX(wb) + hw; if (this.velocity.dx < 0) this.velocity.dx = 0; }
    if (this.feet.x + hw > maxX(wb)) { this.feet.x = maxX(wb) - hw; if (this.velocity.dx > 0) this.velocity.dx = 0; }
    if (this.feet.y < minY(wb) - this.height) {
      this.feet.y = minY(wb);
      this.velocity = { dx: 0, dy: 0 };
      this.isGrounded = true;
      this.pendingEvents.push({ kind: 'fellOffWorld' });
    }
  }

  updateMotion() {
    if (this.grabbedSolid) return;
    if (this.motion.kind === 'landing') return;
    if (this.isGrounded) this.motion = this.velocity.dx === 0 ? { kind: 'resting' } : { kind: 'walking', dx: this.velocity.dx };
    else this.motion = { kind: this.velocity.dy > 0 ? 'rising' : 'falling' };
  }
}

module.exports = { GravitySimulator, TIMESTEP, rect, minX, maxX, minY, maxY, midX, intersects, intersection };
