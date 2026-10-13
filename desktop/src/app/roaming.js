// Port of Roaming/{WindowTopology,RoamingController}.swift.
//
// Turns the gravity simulation and the real window layout into behaviour:
// picks somewhere to go, walks/jumps/climbs there, drives the matching sprite
// state and moves Bill's window each tick.
//
// Cost at rest is zero: the tick timer only exists while a beat is in flight.
const platform = require('../platform');
const geometry = require('./geometry');
const P = require('../core/physics');
const { isRoamingMotion } = require('../core/states');

// ------------------------------------------------------------ window topology
const MIN_PLATFORM = { w: 180, h: 100 };
const MAX_SCREEN_COVERAGE = 0.995;
const CACHE_LIFETIME = 1500;

const topology = {
  cached: [],
  cachedAt: 0,
  invalidate() { this.cachedAt = 0; },

  /** Every solid window, front-to-back, in Y-up space. `fresh` bypasses the cache. */
  platforms(fresh = false) {
    if (!fresh && Date.now() - this.cachedAt < CACHE_LIFETIME) return this.cached;
    this.cached = this.build();
    this.cachedAt = Date.now();
    return this.cached;
  },

  build() {
    const screens = geometry.allScreens();
    const result = [];
    platform.listWindows().forEach((win, depth) => {
      const rect = geometry.toUp(win.rect);
      // Smaller than this is a tooltip, badge or popover — landing on it looks broken.
      if (rect.w < MIN_PLATFORM.w || rect.h < MIN_PLATFORM.h) return;
      const host = screens.find((s) => P.intersects(s.frame, rect));
      if (!host) return;
      // A maximised window's top edge is the screen's; jumping "onto" it is jumping at the ceiling.
      if (rect.w >= host.visible.w * MAX_SCREEN_COVERAGE && rect.h >= host.visible.h * MAX_SCREEN_COVERAGE) return;
      result.push({ rect, pid: win.pid, id: win.id, depth });
    });
    return result;
  },

  /** The window Bill should stand on to "go to" an app: that exact window, else the app's frontmost. */
  platformFor({ windowId, pid }) {
    const all = this.platforms();
    return all.find((p) => p.id === windowId) || all.find((p) => p.pid === pid) || null;
  },
};

// ---------------------------------------------------------------- behaviour
const BEAT_TIMEOUT = 14 * 1000;
const REST_INTERVAL = [3, 9];
const ARRIVAL_TOLERANCE = 8;
const WINDOW_GOAL_CHANCE = 0.85;
const DELIBERATE_DROP_CHANCE = 0.45;
const MAX_REPLANS = 4;
const CONTACT_INTERVAL = 0.18;
const SHOVE_GAIN = 7.5;
const MAX_SHOVE_SPEED = 900;
const MIN_SHOVE_DELTA = 3;
const SHOVE_COOLDOWN = 900;
const MINIMIZE_PRANK_CHANCE = 0.10;
const MINIMIZE_PRANK_COOLDOWN = 25 * 60 * 1000;
// Where the minimize button's centre sits, measured in from the window's top-right corner.
const MINIMIZE_BUTTON_INSET = process.platform === 'win32' ? 115 : 78;

/** Feet sit this far above the window's bottom edge, and the centreline this far from its left, at scale 1. */
const FEET_INSET_Y = 4.55;
const CENTER_INSET_X = 130;

const DEBUG = process.env.BILL_ROAM_DEBUG === '1';
const log = (...m) => { if (DEBUG) console.log('[roam]', ...m); };
const randomIn = (lo, hi) => lo + Math.random() * (hi - lo);
const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
const coin = () => Math.random() < 0.5;
const shuffled = (list) => list.map((v) => [Math.random(), v]).sort((a, b) => a[0] - b[0]).map((p) => p[1]);
const sameRect = (a, b) => a.x === b.x && a.y === b.y && a.w === b.w && a.h === b.h;

class RoamingController {
  /** `bill` is the character window: { frame, setOrigin(x, y), setFacing(dir) }. */
  constructor({ bill, characterEngine, prefs }) {
    this.sim = new P.GravitySimulator();
    this.bill = bill;
    this.engine = characterEngine;
    this.prefs = prefs;
    this.onEvent = null;

    this.tick = null; this.restTimer = null; this.contactTimer = null;
    this.goal = null;
    this.step = { kind: 'done' };
    this.lastAppliedState = null;
    this.facing = 1;
    this.isSuspended = false;
    this.beatStartedAt = 0;
    this.replanCount = 0; this.strollLegs = 0; this.strollLegTarget = 3;
    this.previousRects = new Map();
    this.lastShoveAt = 0;
    this.pendingDropX = null;
    this.pendingPrankWindow = null;
    this.lastMinimizePrankAt = 0;
    this.lastTickAt = 0; this.accumulator = 0;
  }

  get scale() { return this.prefs.get('characterScale'); }
  get isTicking() { return this.tick !== null; }
  emit(event) { if (this.onEvent) this.onEvent(event); }

  // -------------------------------------------------------------- lifecycle
  start() {
    this.scheduleNextBeat();
    clearInterval(this.contactTimer);
    this.contactTimer = setInterval(() => this.checkContacts(), CONTACT_INTERVAL * 1000);
  }

  stop() {
    this.stopTicking();
    clearInterval(this.contactTimer); this.contactTimer = null;
    clearTimeout(this.restTimer); this.restTimer = null;
    this.step = { kind: 'done' };
    this.goal = null;
  }

  /** While the user is dragging Bill, or chat is open, the simulation must not fight for the window. */
  suspend() {
    this.isSuspended = true;
    this.stopTicking();
    clearTimeout(this.restTimer); this.restTimer = null;
    this.step = { kind: 'done' };
    this.goal = null;
  }

  resume() {
    if (!this.isSuspended) return;
    this.isSuspended = false;
    this.scheduleNextBeat();
    // Let go in mid-air, he should start falling on the same frame.
    this.dropIfUnsupported();
  }

  dropIfUnsupported() {
    if (this.isSuspended || !this.prefs.get('roaming') || this.isTicking) return;
    const screen = this.screenForBill();
    this.buildWorld(screen);
    const feet = this.feetPosition();
    const tolerance = this.sim.physics.surfaceTolerance * this.scale;
    const supported = Math.abs(feet.y - screen.visible.y) <= tolerance
      || this.sim.solids.some((s) => Math.abs(feet.y - P.maxY(s.rect)) <= tolerance);
    if (supported) return;
    this.beginFalling(feet);
  }

  beginFalling(feet) {
    this.sim.place(feet, false);
    this.goal = null;
    this.step = { kind: 'airborne' };
    this.beatStartedAt = Date.now();
    clearTimeout(this.restTimer);
    this.startTicking();
  }

  invalidateTopology() { topology.invalidate(); }

  // -------------------------------------------------------- public commands
  /** Sends Bill to stand on an app's window — how he "goes to" what he is about to react to. */
  goToApp(app) {
    if (this.isSuspended || !this.prefs.get('roaming')) return false;
    const target = topology.platformFor(app);
    if (!target) return false;
    clearTimeout(this.restTimer);
    this.beginBeat({ kind: 'platform', rect: target.rect });
    return true;
  }

  /** The debug menu's "Trigger Wander Now": bypasses the rest timer and the idle gate. */
  triggerNow() {
    clearTimeout(this.restTimer);
    this.isSuspended = false;
    this.beginBeat(null, true);
  }

  // -------------------------------------------------------- beat scheduling
  scheduleNextBeat() {
    clearTimeout(this.restTimer);
    if (this.isSuspended) return;
    this.restTimer = setTimeout(() => this.beginBeat(null), randomIn(...REST_INTERVAL) * 1000);
  }

  beginBeat(explicitGoal, forced = false) {
    if (!this.prefs.get('roaming')) { log('BAIL roaming disabled'); this.scheduleNextBeat(); return; }
    // Only start from genuine rest — never yank Bill out of a reaction or a chat.
    if (!explicitGoal && !forced) {
      const current = this.engine.stateMachine.currentState;
      if (current !== 'idle' && !isRoamingMotion(current)) {
        log(`BAIL state=${current} (not idle/roaming)`);
        this.scheduleNextBeat();
        return;
      }
    }
    const screen = this.screenForBill();
    this.buildWorld(screen);
    this.syncSimFromWindow(screen);
    log(`begin feet=(${Math.round(this.sim.feet.x)},${Math.round(this.sim.feet.y)}) grounded=${this.sim.isGrounded} solids=${this.sim.solids.length}`);

    const chosen = explicitGoal || this.pickGoal(screen);
    if (!chosen) { log('BAIL no goal'); this.scheduleNextBeat(); return; }
    log('goal', chosen.kind, chosen.rect ? `top=${Math.round(P.maxY(chosen.rect))} x=${Math.round(chosen.rect.x)}...${Math.round(P.maxX(chosen.rect))}` : chosen.x !== undefined ? `x=${Math.round(chosen.x)}` : '');
    this.goal = chosen;
    this.replanCount = 0;
    this.strollLegs = 0;
    this.strollLegTarget = 2 + Math.floor(Math.random() * 3);
    this.beatStartedAt = Date.now();
    this.planNextStep();
    this.startTicking();
  }

  // ------------------------------------------------------------------ world
  /** Always the screen Bill is actually on — never "the screen the user is working on". */
  screenForBill() { return geometry.screenAt(this.feetPosition()); }

  buildWorld(screen) {
    const visible = screen.visible;
    this.sim.scale = this.scale;
    this.sim.worldBounds = visible;
    this.sim.solids = [];
    for (const p of topology.platforms()) {
      // Clamp every solid into the walkable world, then drop any whose top
      // still sits flush with the ceiling: nothing up there is worth standing
      // on, grabbing or colliding with.
      const rect = P.intersection(p.rect, visible);
      if (!rect || rect.h <= 8 || P.maxY(rect) >= P.maxY(visible) - 8) continue;
      this.sim.solids.push({ rect, isWorldBounds: false });
    }
  }

  pickGoal(screen) {
    const visible = screen.visible;
    const sim = this.sim;

    const prank = this.pickMinimizePrankTarget(visible);
    if (prank) return { kind: 'trafficLight', rect: prank.rect, windowId: prank.id };

    const reachable = sim.solids.map((s) => s.rect).filter((rect) => {
      if (P.maxY(rect) >= P.maxY(visible) - 8) return false;
      // Reachable by a direct leap onto the top edge, or by catching the side and climbing.
      const landing = this.landingPoint(rect);
      const v = sim.solveJump(sim.feet, landing);
      if (v && sim.isArcClear(sim.feet, v, landing)) return true;
      return this.sideGrabTarget(rect) !== null;
    });

    const isElevated = sim.feet.y > visible.y + 40;
    // Up high, a deliberate drop competes with climbing further.
    if (isElevated && Math.random() < DELIBERATE_DROP_CHANCE) return { kind: 'dropOff' };
    if (reachable.length && Math.random() < WINDOW_GOAL_CHANCE) {
      return { kind: 'platform', rect: reachable[Math.floor(Math.random() * reachable.length)] };
    }
    if (isElevated && Math.random() < 0.4) {
      return { kind: 'ground', x: randomIn(visible.x + 80, Math.max(visible.x + 80, P.maxX(visible) - 80)) };
    }
    const span = randomIn(160, 460) * (coin() ? 1 : -1);
    return { kind: 'stroll', x: clamp(sim.feet.x + span, visible.x + 40, P.maxX(visible) - 40) };
  }

  // --------------------------------------------------------------- planning
  /** How far past a ledge's end his feet must be before none of him is over it. */
  dropClearance() { return this.sim.halfWidth + 12 + ARRIVAL_TOLERANCE + 6; }

  minimizeButton(rect) {
    return { x: P.maxX(rect) - MINIMIZE_BUTTON_INSET, y: P.maxY(rect) };
  }

  /**
   * The prank: leap onto a background window's minimize button and actually
   * press it. Never the frontmost window (minimizing what the user is typing
   * in would be hostile, not playful), behind a long cooldown and a chance roll.
   */
  pickMinimizePrankTarget(visible) {
    if (!this.prefs.get('minimizeMischief') || this.prefs.get('mode') !== 'troll') return null;
    if (Date.now() - this.lastMinimizePrankAt <= MINIMIZE_PRANK_COOLDOWN) return null;
    if (Math.random() >= MINIMIZE_PRANK_CHANCE) return null;
    const sim = this.sim;
    const candidates = topology.platforms(true).slice(1).filter((p) => p.rect.w >= 260
      && P.maxY(p.rect) < P.maxY(visible) - 8
      && P.maxY(p.rect) > sim.feet.y + 60);
    for (const candidate of shuffled(candidates)) {
      const button = this.minimizeButton(candidate.rect);
      const v = sim.solveJump(sim.feet, button);
      if (v && sim.isArcClear(sim.feet, v, button)) {
        this.lastMinimizePrankAt = Date.now();
        return candidate;
      }
    }
    return null;
  }

  planNextStep() {
    const goal = this.goal;
    const sim = this.sim;
    if (!goal) { this.step = { kind: 'done' }; return; }
    const settle = (seconds) => { this.step = { kind: 'settle', until: Date.now() + seconds * 1000 }; };
    const crouch = (target) => { this.step = { kind: 'crouch', until: Date.now() + 160, target }; };

    switch (goal.kind) {
      case 'stroll':
        this.step = { kind: 'approach', x: goal.x, running: Math.abs(goal.x - sim.feet.x) > 240 };
        break;

      case 'dropOff': {
        // Head for whichever end of this ledge is nearer, stopping just past
        // it so the next tick has nothing underfoot.
        const ledge = this.currentLedge();
        if (!ledge) { settle(0.3); return; }
        const leftGap = sim.feet.x - ledge.x;
        const rightGap = P.maxX(ledge) - sim.feet.x;
        // An end that is flush with the screen edge has nothing beyond it to fall into.
        const world = sim.worldBounds;
        const room = this.dropClearance();
        const canLeft = ledge.x - room > world.x;
        const canRight = P.maxX(ledge) + room < P.maxX(world);
        if (!canLeft && !canRight) { settle(0.3); return; }
        const direction = canLeft && (leftGap < rightGap || !canRight) ? -1 : 1;
        const edgeX = direction < 0 ? ledge.x - 12 : P.maxX(ledge) + 12;
        goal.direction = direction;
        goal.committed = false;
        this.pendingDropX = edgeX;
        this.step = { kind: 'approach', x: edgeX, running: false };
        break;
      }

      case 'ground':
        // Look over the edge, then walk off it.
        this.step = { kind: 'peek', until: Date.now() + 550 };
        this.pendingDropX = goal.x;
        break;

      case 'platform': {
        const rect = goal.rect;
        const landing = this.landingPoint(rect);
        // Already there, or the "jump" would barely move him.
        if (Math.abs(sim.feet.y - landing.y) < 24 && Math.abs(sim.feet.x - landing.x) < 60) { settle(0.3); return; }
        const v = sim.solveJump(sim.feet, landing);
        if (v && sim.isArcClear(sim.feet, v, landing)) { crouch(landing); return; }
        // The top edge is out of leap range — a tall window. Aim at the side
        // instead: a descending wall contact becomes a ledge grab, and the
        // grab then climbs the rest of the way.
        const grab = this.sideGrabTarget(rect);
        if (grab) { crouch(grab); return; }
        // Too far to leap from here — close the horizontal gap, then re-plan.
        const approachX = P.midX(rect) < sim.feet.x ? P.maxX(rect) + 30 : rect.x - 30;
        this.step = { kind: 'approach', x: approachX, running: true };
        break;
      }

      case 'trafficLight': {
        // Land *exactly* on the button — the accuracy is the joke.
        const button = this.minimizeButton(goal.rect);
        const target = { rect: goal.rect, id: goal.windowId };
        if (Math.abs(sim.feet.y - button.y) < 24 && Math.abs(sim.feet.x - button.x) < 24) {
          this.pendingPrankWindow = null;
          this.emit({ kind: 'minimizePrankArrived', window: target });
          settle(0.5);
          return;
        }
        const v = sim.solveJump(sim.feet, button);
        if (v && sim.isArcClear(sim.feet, v, button)) {
          this.pendingPrankWindow = target;
          crouch(button);
        } else {
          // No precise direct leap from here: skip it rather than degrade it into a plain climb.
          this.pendingPrankWindow = null;
          settle(0.3);
        }
        break;
      }

      default:
        this.step = { kind: 'done' };
    }
  }

  /**
   * A point just inside the near wall of `rect`, as high up it as one leap
   * manages, aimed so Bill is already descending when he makes contact (only
   * a descending contact becomes a grab).
   */
  sideGrabTarget(rect) {
    const sim = this.sim;
    const hw = sim.halfWidth;
    let aimX;
    if (sim.feet.x <= rect.x - hw) aimX = rect.x + 8;                 // cross the left wall going right
    else if (sim.feet.x >= P.maxX(rect) + hw) aimX = P.maxX(rect) - 8; // cross the right wall going left
    else return null;                                                  // under/inside its span: no wall to catch
    const ceiling = sim.feet.y + sim.maxReachableRise * 0.9;
    const y = Math.min(P.maxY(rect) - 40, ceiling);
    if (!(y > rect.y + 24 && y > sim.feet.y + 40)) return null;
    const target = { x: aimX, y };
    const v = sim.solveJump(sim.feet, target);
    if (!v || !sim.isArcClear(sim.feet, v, target)) return null;
    return target;
  }

  /** The window surface Bill is standing on, if it is not the screen floor. */
  currentLedge() {
    const feet = this.sim.feet;
    const solid = this.sim.solids.find((s) => Math.abs(P.maxY(s.rect) - feet.y) < 3 && feet.x >= s.rect.x - 40 && feet.x <= P.maxX(s.rect) + 40);
    return solid ? solid.rect : null;
  }

  /** The window he is standing on right now ({ rect, id, pid }), or null on the floor or in the air. */
  currentPlatform() {
    const feet = this.feetPosition();
    return topology.platforms().find((p) => Math.abs(P.maxY(p.rect) - feet.y) < 4 && feet.x >= p.rect.x && feet.x <= P.maxX(p.rect)) || null;
  }

  /** The closest landing spot on a ledge, rather than its centre. */
  landingPoint(rect) {
    const inset = Math.min(40, rect.w / 3);
    return { x: clamp(this.sim.feet.x, rect.x + inset, P.maxX(rect) - inset), y: P.maxY(rect) };
  }

  // ----------------------------------------- contact with moving windows
  /** Notices windows moving into Bill, surfaces moving under him, and surfaces vanishing. */
  checkContacts() {
    if (this.isSuspended || !this.prefs.get('roaming')) return;
    const screen = this.screenForBill();
    const scale = this.scale;
    const sim = this.sim;
    const feet = this.feetPosition();
    const hw = sim.physics.bodyWidth * scale / 2;
    const body = P.rect(feet.x - hw, feet.y, hw * 2, sim.physics.bodyHeight * scale);

    const platforms = topology.platforms(true);
    const rects = new Map();
    let shove = null;
    let rideDX = 0;

    for (const p of platforms) {
      rects.set(p.id, p.rect);
      const old = this.previousRects.get(p.id);
      if (!old || sameRect(old, p.rect)) continue;
      const dx = p.rect.x - old.x;
      const dy = p.rect.y - old.y;

      // Standing on this ledge and it slid sideways: go with it.
      if (Math.abs(feet.y - P.maxY(p.rect)) < 3 && feet.x > p.rect.x && feet.x < P.maxX(p.rect) && Math.abs(dx) >= 1) {
        rideDX += dx;
        continue;
      }
      // Swept into him: it did not overlap before, and does now.
      if (P.intersects(old, body) || !P.intersects(p.rect, body)) continue;
      if (Math.abs(dx) < MIN_SHOVE_DELTA && Math.abs(dy) < MIN_SHOVE_DELTA) continue;

      // Push along the direction the window travelled, biased to send him
      // out sideways rather than straight down through the floor.
      const vx = clamp(dx * SHOVE_GAIN / CONTACT_INTERVAL, -MAX_SHOVE_SPEED, MAX_SHOVE_SPEED);
      const vy = Math.max(0, dy * SHOVE_GAIN / CONTACT_INTERVAL);
      shove = { dx: vx === 0 ? (feet.x < P.midX(p.rect) ? -260 : 260) : vx, dy: Math.max(vy, 300 * scale) };
    }
    this.previousRects = rects;

    if (rideDX !== 0 && !this.isTicking) {
      const frame = this.bill.frame;
      this.bill.setOrigin(frame.x + rideDX, frame.y);
    }

    // Standing on nothing? Closing the window he was perched on, or moving
    // it, removes the surface between beats — this watcher has fresh geometry
    // in hand, so it is the natural place to notice.
    if (!this.isTicking && !shove) {
      const floor = screen.visible.y;
      const tolerance = sim.physics.surfaceTolerance * scale;
      const supported = Math.abs(feet.y - floor) <= tolerance
        || platforms.some((p) => Math.abs(feet.y - P.maxY(p.rect)) <= tolerance && feet.x > p.rect.x - hw && feet.x < P.maxX(p.rect) + hw);
      if (!supported && feet.y > floor + tolerance) {
        log(`UNSUPPORTED at (${Math.round(feet.x)},${Math.round(feet.y)}) — falling`);
        this.buildWorld(screen);
        this.beginFalling(feet);
        return;
      }
    }

    if (!shove || Date.now() - this.lastShoveAt <= SHOVE_COOLDOWN) return;
    this.lastShoveAt = Date.now();
    log(`SHOVED by window impulse=(${Math.round(shove.dx)},${Math.round(shove.dy)})`);

    // Re-seed the simulation from where he actually is, then launch him.
    this.buildWorld(screen);
    sim.place(feet, false);
    sim.shove(shove);
    this.goal = null;
    this.step = { kind: 'airborne' };
    this.beatStartedAt = Date.now();
    clearTimeout(this.restTimer);
    this.engine.request('surprised', true);
    this.emit({ kind: 'shoved' });
    this.startTicking();
  }

  // ---------------------------------------------------------------- ticking
  startTicking() {
    clearInterval(this.tick);
    this.lastTickAt = Date.now();
    this.accumulator = 0;
    this.tick = setInterval(() => this.onTick(), 1000 / 60);
  }

  stopTicking() { clearInterval(this.tick); this.tick = null; }

  /**
   * Fixed-timestep driver. Timers are not exact, so the simulation consumes
   * real elapsed time in whole 1/60s steps: the arc the solver predicted is
   * the arc that plays, however the timer happens to land.
   */
  onTick() {
    const now = Date.now();
    this.accumulator = Math.min(this.accumulator + (now - this.lastTickAt) / 1000, P.TIMESTEP * 5);
    this.lastTickAt = now;
    while (this.accumulator >= P.TIMESTEP && this.isTicking) {
      this.accumulator -= P.TIMESTEP;
      this.stepOnce();
    }
    this.writeBack();
  }

  endBeat() {
    log(`end feet=(${Math.round(this.sim.feet.x)},${Math.round(this.sim.feet.y)}) grounded=${this.sim.isGrounded}`);
    this.stopTicking();
    this.step = { kind: 'done' };
    this.goal = null;
    this.pendingDropX = null;
    // A beat that ends mid-grab would leave him hanging between beats, where
    // nothing ticks. Every beat boundary frees him.
    this.sim.releaseIfHanging();
    this.sim.stop();
    this.applyState('idle');
    this.resetFacing();
    this.scheduleNextBeat();
  }

  stepOnce() {
    if (this.isSuspended) { this.endBeat(); return; }
    if (Date.now() - this.beatStartedAt > BEAT_TIMEOUT) {
      this.emit({ kind: 'reachedGoal' });
      this.endBeat();
      return;
    }
    this.driveStep();
    const events = this.sim.step(P.TIMESTEP);
    this.applyMotionState();
    for (const event of events) {
      log('event', event.kind, `at (${Math.round(this.sim.feet.x)},${Math.round(this.sim.feet.y)})`);
      this.handle(event);
      this.emit(event);
    }
    if (this.step.kind === 'done') { this.writeBack(); this.endBeat(); }
  }

  /** Issues the commands the current plan step needs, each tick. */
  driveStep() {
    const sim = this.sim;
    const step = this.step;
    const settle = (seconds) => { this.step = { kind: 'settle', until: Date.now() + seconds * 1000 }; };

    switch (step.kind) {
      case 'approach': {
        // A reaction clip that fires mid-beat pauses the walk: Bill only moves
        // while the walk (or a roam motion) is actually playing.
        const current = this.engine.stateMachine.currentState;
        if (current !== 'idle' && !isRoamingMotion(current)) { sim.stop(); return; }
        const delta = step.x - sim.feet.x;
        if (Math.abs(delta) <= ARRIVAL_TOLERANCE || !sim.isGrounded) {
          if (!sim.isGrounded) return;
          sim.stop();
          // The lip of a deliberate drop: lean out and look down before committing.
          if (this.goal && this.goal.kind === 'dropOff') {
            // Stepped off the lip and somehow still standing: nothing to fall into after all.
            if (this.goal.committed) { settle(0.3); return; }
            this.step = { kind: 'peek', until: Date.now() + 700 };
            return;
          }
          if (this.goal && this.goal.kind === 'stroll') {
            // Chain another leg rather than stopping dead: one short hop
            // reads as a twitch, a few in sequence read as pacing around.
            this.strollLegs += 1;
            if (this.strollLegs < this.strollLegTarget) {
              const visible = this.screenForBill().visible;
              const span = randomIn(120, 380) * (coin() ? 1 : -1);
              const nextX = clamp(sim.feet.x + span, visible.x + 40, P.maxX(visible) - 40);
              this.goal = { kind: 'stroll', x: nextX };
              this.step = { kind: 'approach', x: nextX, running: Math.abs(span) > 300 };
            } else settle(0.4);
          } else {
            this.replanCount += 1;
            if (this.replanCount > MAX_REPLANS) { log(`giving up on goal after ${this.replanCount} replans`); settle(0.3); }
            else this.planNextStep();
          }
          return;
        }
        sim.walk(delta, step.running);
        break;
      }

      case 'crouch':
        sim.stop();
        if (Date.now() >= step.until) this.step = { kind: 'launch', target: step.target };
        break;

      case 'launch':
        if (sim.jump(step.target)) {
          log(`LAUNCH to (${Math.round(step.target.x)},${Math.round(step.target.y)}) v=(${Math.round(sim.velocity.dx)},${Math.round(sim.velocity.dy)})`);
          this.step = { kind: 'airborne' };
        } else {
          log('launch FAILED (target moved or unreachable) - replanning');
          // The window moved or closed between planning and launching.
          this.replanCount += 1;
          if (this.replanCount > MAX_REPLANS) settle(0.3); else this.planNextStep();
        }
        break;

      case 'peek':
        sim.stop();
        this.applyState('edgePeek');
        if (Date.now() < step.until) return;
        if (this.goal && this.goal.kind === 'dropOff') {
          // Commit: step off the lip. The Mac app lets go where he stands,
          // but his body still overlaps the ledge there, so he lands straight
          // back on it and the drop never happens. Walking on until nothing
          // is underfoot is what makes him actually fall.
          this.goal.committed = true;
          this.pendingDropX = null;
          this.step = { kind: 'approach', x: sim.feet.x + (this.goal.direction || -1) * this.dropClearance(), running: false };
          log(`DROP from (${Math.round(sim.feet.x)},${Math.round(sim.feet.y)})`);
          return;
        }
        if (this.pendingDropX !== null) {
          this.step = { kind: 'approach', x: this.pendingDropX, running: false };
          this.pendingDropX = null;
        } else settle(0.3);
        break;

      case 'climb':
        sim.climb(step.direction);
        break;

      case 'settle':
        sim.stop();
        if (Date.now() >= step.until) this.step = { kind: 'done' };
        break;

      default: // airborne, done
        break;
    }
  }

  handle(event) {
    switch (event.kind) {
      case 'landed':
        if (this.step.kind !== 'airborne') break;
        // Arrived. Give the landing a moment to read before idle takes over.
        if (this.pendingPrankWindow) {
          // The landing is the prank: he is standing on the button.
          const target = this.pendingPrankWindow;
          this.pendingPrankWindow = null;
          this.emit({ kind: 'minimizePrankArrived', window: target });
          this.step = { kind: 'settle', until: Date.now() + 500 };
        } else {
          this.step = { kind: 'settle', until: Date.now() + 450 };
        }
        break;
      case 'grabbedLedge': this.step = { kind: 'climb', direction: 1 }; break;
      case 'walkedOffEdge': this.step = { kind: 'airborne' }; break;
      case 'fellOffWorld': this.step = { kind: 'done' }; break;
      default: break; // bonkedHead
    }
  }

  // ----------------------------------------------------- animation + window
  applyMotionState() {
    const sim = this.sim;
    const motion = sim.motion;
    let state;
    switch (motion.kind) {
      case 'walking':
        state = Math.abs(motion.dx) > sim.physics.walkSpeed * sim.scale * 1.3 ? 'running' : 'walking';
        this.updateFacing(motion.dx);
        break;
      case 'launching': state = 'launching'; break;
      case 'rising': state = 'rising'; break;
      case 'falling': state = 'falling'; break;
      case 'landing': state = motion.hard ? 'landingHard' : 'landingSoft'; break;
      case 'ledgeGrab': state = 'ledgeGrabbing'; break;
      case 'climbing': state = motion.dy >= 0 ? 'climbingUp' : 'climbingDown'; break;
      case 'hanging': state = 'hangingIdle'; break;
      default: state = 'idle';
    }
    this.applyState(state);
  }

  applyState(state) {
    if (state === this.lastAppliedState) return;
    this.lastAppliedState = state;
    this.engine.request(state, true);
  }

  /** The sheet art faces left: +1 is as drawn, -1 mirrors him to face right. */
  updateFacing(dx) {
    const want = dx > 0 ? -1 : 1;
    if (want === this.facing) return;
    this.facing = want;
    this.bill.setFacing(want);
  }

  resetFacing() {
    if (this.facing === 1) return;
    this.facing = 1;
    this.bill.setFacing(1);
  }

  // ---------------------------------------------------- window <-> simulation
  feetPosition() {
    const s = this.scale;
    const frame = this.bill.frame;
    return { x: frame.x + CENTER_INSET_X * s, y: frame.y + FEET_INSET_Y * s };
  }

  syncSimFromWindow(screen) {
    const feet = this.feetPosition();
    // Grounded if he is already sitting on the floor or on a ledge.
    const onSurface = Math.abs(feet.y - screen.visible.y) < 2
      || this.sim.solids.some((s) => Math.abs(feet.y - P.maxY(s.rect)) < 2);
    this.sim.place(feet, onSurface);
  }

  writeBack() {
    const s = this.scale;
    const x = this.sim.feet.x - CENTER_INSET_X * s;
    const y = this.sim.feet.y - FEET_INSET_Y * s;
    const frame = this.bill.frame;
    if (Math.abs(x - frame.x) <= 0.01 && Math.abs(y - frame.y) <= 0.01) return;
    this.bill.setOrigin(x, y);
  }
}

module.exports = { RoamingController, topology, FEET_INSET_Y, CENTER_INSET_X };
