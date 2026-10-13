// What Bill does to the screen on his own, depending on his mood.
//
// Troll mode: he snatches the mouse pointer when it lingers on him and runs
// off with it, and shakes the window he has just landed on. (Pressing a
// background window's minimize button lives in roaming.js.) Everything he
// moves goes back exactly where it was; "Undo Bill's Mischief" restores what
// he minimized.
//
// Helpful mode: no pranks. When the window you are working in looks like it
// is showing an error, he walks over and offers to read it; a poke accepts.
const platform = require('../platform');
const geometry = require('./geometry');
const { pick } = require('../core/modeLines');

const POLL = 250;
const HOVER_BEFORE_SNATCH = 1100;
const SNATCH_COOLDOWN = 90 * 1000;
const SNATCH_CHANCE = 0.6;
const SNATCH_RUN = [220, 380];
const SNATCH_SPEED = 520; // px per second
const SHAKE_CHANCE = 0.3;
const SHAKE_COOLDOWN = 3 * 60 * 1000;
const SHAKE_MS = 750;
const SHAKE_PX = 10;
const OFFER_COOLDOWN = 6 * 60 * 1000;
const OFFER_WINDOW = 20 * 1000;
const TROUBLE = /\b(?:error|exception|failed|failure|crash(?:ed)?|not responding|cannot|can't|unable to|access (?:is )?denied|fatal|traceback|timed out|not found|404|stopped working)\b/i;

const randomIn = (lo, hi) => lo + Math.random() * (hi - lo);
const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));

class ScreenPlay {
  constructor({ engine, roaming, bill, prefs, monitor, chatBubble, studyMode, helper, snip, enabled = true }) {
    Object.assign(this, { engine, roaming, bill, prefs, monitor, chatBubble, studyMode, helper, snip, enabled });
    this.timer = null;
    this.hoverSince = 0;
    this.lastSnatchAt = 0;
    this.snatch = null;
    this.lastShakeAt = 0;
    this.shake = null;
    this.offer = null;
    this.lastOfferAt = 0;
    this.offeredTitles = new Set();
    /** Windows he pressed the minimize button of, newest last. */
    this.minimized = [];
  }

  get mode() { return this.prefs.get('mode'); }
  get isTroll() { return this.mode === 'troll'; }

  start() {
    if (!this.enabled) return;
    clearInterval(this.timer);
    this.timer = setInterval(() => this.poll(), POLL);
  }

  stop() {
    clearInterval(this.timer); this.timer = null;
    this.endSnatch(false);
    this.endShake();
  }

  /** Not while the user is busy with him, in a chat, studying, or watching something full-screen. */
  mayAct() {
    if (!this.enabled || this.bill.isDragging || this.bill.menuOpen || this.chatBubble.isVisible) return false;
    if (this.studyMode.isActive || this.snip.isOpen || this.helper.busy || this.snatch || this.shake) return false;
    if (platform.isMouseDown()) return false;
    const current = this.monitor.current;
    if (current && current.windowId !== undefined && platform.isFullscreen(current.windowId)) return false;
    return true;
  }

  poll() {
    if (this.isTroll) this.watchCursor(); else this.watchForTrouble();
    if (this.offer && Date.now() > this.offer.until) this.offer = null;
  }

  // ----------------------------------------------------------- cursor snatch
  watchCursor() {
    if (this.snatch) return;
    const over = geometry.contains(this.bill.hitRegion(), geometry.cursor());
    if (!over || !this.prefs.get('cursorPranks') || !platform.canMoveCursor()) { this.hoverSince = 0; return; }
    if (!this.hoverSince) { this.hoverSince = Date.now(); return; }
    if (Date.now() - this.hoverSince < HOVER_BEFORE_SNATCH) return;
    this.hoverSince = 0;
    if (Date.now() - this.lastSnatchAt < SNATCH_COOLDOWN || !this.mayAct() || this.roaming.isTicking) return;
    this.lastSnatchAt = Date.now();
    if (Math.random() < SNATCH_CHANCE) this.beginSnatch();
  }

  /** Where he holds the pointer: at the end of his arm, about chest height. */
  holdPoint() {
    const body = this.bill.bodyRect();
    return { x: body.x + body.w / 2, y: body.y + body.h * 0.45 };
  }

  putCursor(pointUp) {
    return platform.setCursor({ x: pointUp.x, y: geometry.primaryHeight() - pointUp.y });
  }

  beginSnatch() {
    const frame = this.bill.frame;
    const visible = this.bill.screen().visible;
    const room = { left: frame.x - visible.x, right: visible.x + visible.w - (frame.x + frame.w) };
    const direction = room.right >= room.left ? 1 : -1;
    const distance = Math.min(randomIn(...SNATCH_RUN), Math.max(0, direction > 0 ? room.right : room.left));
    if (distance < 60 || !this.putCursor(this.holdPoint())) return;

    this.roaming.suspend();
    this.engine.request('hookCane', true);
    this.engine.bark(pick('cursorSnatch'), 'always');
    this.snatch = { fromX: frame.x, y: frame.y, direction, distance, startedAt: Date.now() + 450, running: false, timer: null };
    this.snatch.timer = setInterval(() => this.stepSnatch(), 16);
  }

  stepSnatch() {
    const s = this.snatch;
    if (!s) return;
    // The moment the user actually uses the mouse, it is theirs again.
    if (platform.isMouseDown() || this.bill.isDragging) { this.endSnatch(false); return; }
    const elapsed = Date.now() - s.startedAt;
    if (elapsed < 0) { this.putCursor(this.holdPoint()); return; }
    if (!s.running) {
      s.running = true;
      this.engine.request('running', true);
      // The sheet art faces left: -1 mirrors him to face right.
      this.bill.setFacing(s.direction > 0 ? -1 : 1);
    }
    const travelled = Math.min(s.distance, elapsed / 1000 * SNATCH_SPEED);
    this.bill.setOrigin(s.fromX + s.direction * travelled, s.y);
    this.putCursor(this.holdPoint());
    if (travelled >= s.distance) this.endSnatch(true);
  }

  endSnatch(finished) {
    const s = this.snatch;
    if (!s) return;
    clearInterval(s.timer);
    this.snatch = null;
    this.bill.setFacing(1);
    this.engine.request(finished ? 'smug' : 'surprised', true);
    if (finished) this.engine.bark(pick('cursorDrop'), 'always');
    // Resuming drops him if the run carried him off the window he stood on.
    this.roaming.resume();
  }

  // ------------------------------------------------------------ window shake
  /** Called when a roaming beat lands him on something. */
  landed() {
    if (!this.isTroll || !this.prefs.get('windowPranks')) return;
    if (Date.now() - this.lastShakeAt < SHAKE_COOLDOWN || Math.random() >= SHAKE_CHANCE) return;
    // Let the landing finish reading before he starts stomping.
    setTimeout(() => this.beginShake(), 700);
  }

  beginShake() {
    if (!this.isTroll || !this.mayAct() || this.roaming.isTicking) return;
    const under = this.roaming.currentPlatform();
    if (!under) return;
    const state = platform.windowState(under.id);
    if (!state || state.minimized || state.maximized) return;
    // A window that refuses to move (an elevated app, a tiled one) is left alone.
    if (!platform.moveWindow(under.id, state.origin.x, state.origin.y)) return;
    this.lastShakeAt = Date.now();
    this.engine.request('dancing', true);
    this.engine.bark(pick('windowShake'), 'always');
    this.shake = { id: under.id, origin: state.origin, scale: state.scale || 1, startedAt: Date.now(), timer: null };
    this.shake.timer = setInterval(() => this.stepShake(), 16);
  }

  stepShake() {
    const s = this.shake;
    if (!s) return;
    const t = Date.now() - s.startedAt;
    if (t >= SHAKE_MS || platform.isMouseDown()) { this.endShake(); return; }
    const dx = Math.round(SHAKE_PX * s.scale * Math.sin(t / 1000 * Math.PI * 2 * 9) * (1 - t / SHAKE_MS));
    platform.moveWindow(s.id, s.origin.x + dx, s.origin.y);
  }

  endShake() {
    const s = this.shake;
    if (!s) return;
    clearInterval(s.timer);
    this.shake = null;
    // Exactly where it was.
    platform.moveWindow(s.id, s.origin.x, s.origin.y);
    this.roaming.invalidateTopology();
  }

  // -------------------------------------------------------------- mischief log
  noteMinimized(windowId) {
    if (windowId === undefined || windowId === null) return;
    this.minimized.push(windowId);
    if (this.minimized.length > 12) this.minimized.shift();
  }

  /** Puts back everything he has minimized. Returns how many windows that was. */
  undoMischief({ quiet = false } = {}) {
    this.endSnatch(false);
    this.endShake();
    const ids = this.minimized;
    this.minimized = [];
    let restored = 0;
    for (const id of ids) if (platform.restore(id)) restored += 1;
    this.roaming.invalidateTopology();
    if (!quiet) {
      this.engine.request(restored ? 'huffy' : 'smug', true);
      this.engine.bark(pick(restored ? 'undo' : 'undoNothing'), 'always');
    }
    return restored;
  }

  // ------------------------------------------------------------ helpful offers
  watchForTrouble() {
    if (!this.prefs.get('helpOffers') || this.offer || !platform.canReadScreen) return;
    if (Date.now() - this.lastOfferAt < OFFER_COOLDOWN) return;
    const current = this.monitor.current;
    if (!current || current.windowId === undefined) return;
    const title = String(platform.windowTitle(current.windowId) || current.title || '');
    if (!title || !TROUBLE.test(title) || this.offeredTitles.has(title) || !this.mayAct()) return;
    this.offeredTitles.add(title);
    if (this.offeredTitles.size > 200) this.offeredTitles.clear();
    this.lastOfferAt = Date.now();
    this.offer = { target: { ...current }, until: Date.now() + OFFER_WINDOW };
    this.roaming.goToApp({ windowId: current.windowId, pid: current.pid });
    setTimeout(() => {
      if (!this.offer) return;
      this.engine.request('presenting', true);
      this.engine.bark(pick('offer'), 'always');
    }, 1200);
  }

  /** A poke while an offer stands takes him up on it. */
  acceptOffer() {
    const offer = this.offer;
    if (!offer || Date.now() > offer.until) { this.offer = null; return false; }
    this.offer = null;
    this.helper.helpWithWindow(offer.target);
    return true;
  }

  /** Switching mood: pranks in flight stop, offers lapse, and Helpful Bill tidies up after Troll Bill. */
  modeChanged() {
    this.offer = null;
    this.hoverSince = 0;
    this.endSnatch(false);
    this.endShake();
    if (!this.isTroll) this.undoMischief({ quiet: true });
  }
}

module.exports = { ScreenPlay, TROUBLE, clamp };
