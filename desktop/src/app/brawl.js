// The brawl: a key spawns extra Bills, and they fight each other until one is
// left standing. They are click-through copies with their own animation
// state; the real Bill only watches and heckles.
const { StateMachine } = require('../engine/stateMachine');
const { BillWindow } = require('./billWindow');
const geometry = require('./geometry');

const MAX_FIGHTERS = 6;
const TICK = 33;
const RUN_SPEED = 300;          // px per second
const REACH = 95;               // how close a swing needs to be
const SWING_MS = 650;
const SWING_COOLDOWN = [500, 1300];
const HIT_POINTS = 4;
const KNOCKBACK = [110, 190];
const KNOCK_MS = 520;
const KNOCK_HEIGHT = 70;
const ATTACKS = ['caneFlourish', 'shadowHands', 'rampaging', 'hookCane', 'powerSurge'];
const HURTS = ['flinching', 'tumbling', 'surprised', 'dazed'];

const HECKLES = [
  'FIGHT! FIGHT! FIGHT!', 'MY MONEY\'S ON THE TRIANGLE.', 'THERE CAN ONLY BE ONE ME!',
  'OOH, THAT ONE HAD TO HURT.', 'I\'VE NEVER LOOKED BETTER. OR WORSE.',
];
const WINNER_LINES = ['AND THE WINNER IS... ME! OBVIOUSLY.', 'ONE BILL TO RULE THEM ALL.', 'I ALWAYS WIN. EVEN AGAINST MYSELF.'];

const randomIn = (lo, hi) => lo + Math.random() * (hi - lo);
const pick = (list) => list[Math.floor(Math.random() * list.length)];
const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));

class Brawl {
  constructor({ engine, bill, prefs, spritesDir }) {
    Object.assign(this, { engine, bill, prefs, spritesDir });
    this.fighters = [];
    this.timer = null;
    this.lastTick = 0;
    this.lastHeckle = 0;
  }

  get isOn() { return this.fighters.length > 0; }

  /** The key: the first press starts a fight with two, each press after adds one. */
  spawn() {
    const count = this.fighters.length === 0 ? 2 : 1;
    for (let i = 0; i < count; i++) this.addFighter();
    if (!this.timer && this.fighters.length) {
      this.lastTick = Date.now();
      this.timer = setInterval(() => this.tick(), TICK);
      this.engine.request('celebrating', true);
      this.engine.bark(pick(HECKLES), 'always');
    }
  }

  addFighter() {
    if (this.fighters.length >= MAX_FIGHTERS) return;
    const visible = this.bill.screen().visible;
    const machine = new StateMachine();
    const window = new BillWindow({ stateMachine: machine, prefs: this.prefs, spritesDir: this.spritesDir });
    // A copy never takes the mouse: no dragging, no poking, no menu.
    window.pollCursor = () => {};
    window.create();
    clearInterval(window.raiseTimer);
    const width = window.size.w;
    const x = randomIn(visible.x + 20, Math.max(visible.x + 20, visible.x + visible.w - width - 20));
    const fighter = {
      window, machine, x, floor: visible.y, bounds: visible, width,
      hp: HIT_POINTS, state: 'run', until: 0, nextSwingAt: Date.now() + randomIn(300, 900),
      knock: null, facing: 1, anim: null, out: false,
    };
    window.setOrigin(x, fighter.floor);
    this.fighters.push(fighter);
  }

  animate(fighter, state) {
    if (fighter.anim === state) return;
    fighter.anim = state;
    fighter.machine.request(state, true);
  }

  face(fighter, dx) {
    // The sheet art faces left: -1 mirrors him to face right.
    const want = dx > 0 ? -1 : 1;
    if (want === fighter.facing) return;
    fighter.facing = want;
    fighter.window.setFacing(want);
  }

  tick() {
    const now = Date.now();
    const dt = Math.min(0.1, (now - this.lastTick) / 1000);
    this.lastTick = now;
    const alive = this.fighters.filter((f) => !f.out);

    for (const f of alive) {
      let y = f.floor;
      if (f.state === 'knocked') {
        const t = (now - f.knock.startedAt) / KNOCK_MS;
        if (t >= 1) {
          f.x = f.knock.toX;
          if (f.hp <= 0) { this.knockOut(f); continue; }
          f.state = 'run'; f.anim = null;
        } else {
          f.x = f.knock.fromX + (f.knock.toX - f.knock.fromX) * t;
          y = f.floor + KNOCK_HEIGHT * 4 * t * (1 - t);
        }
      } else if (f.state === 'swing') {
        if (now >= f.until) { f.state = 'run'; f.anim = null; f.nextSwingAt = now + randomIn(...SWING_COOLDOWN); }
      } else if (alive.length > 1) {
        const foe = alive.filter((o) => o !== f).sort((a, b) => Math.abs(a.x - f.x) - Math.abs(b.x - f.x))[0];
        const dx = foe.x - f.x;
        this.face(f, dx);
        if (Math.abs(dx) > REACH) {
          f.x += Math.sign(dx) * RUN_SPEED * dt;
          this.animate(f, 'running');
        } else if (now >= f.nextSwingAt && foe.state !== 'knocked') {
          f.state = 'swing'; f.until = now + SWING_MS;
          this.animate(f, pick(ATTACKS));
          this.hit(foe, Math.sign(dx) || 1, now);
        } else {
          this.animate(f, 'idle');
        }
      }
      f.x = clamp(f.x, f.bounds.x - 40, f.bounds.x + f.bounds.w - f.width + 40);
      f.window.setOrigin(f.x, y);
    }

    if (now - this.lastHeckle > 7000 && alive.length > 1) {
      this.lastHeckle = now;
      this.engine.bark(pick(HECKLES));
    }

    const standing = this.fighters.filter((f) => !f.out);
    if (standing.length === 1 && standing[0].state !== 'won' && this.fighters.length > 1) this.crown(standing[0]);
    if (!this.fighters.length) this.stopTicking();
  }

  hit(target, direction, now) {
    target.hp -= 1;
    const toX = clamp(target.x + direction * randomIn(...KNOCKBACK), target.bounds.x - 40, target.bounds.x + target.bounds.w - target.width + 40);
    target.state = 'knocked';
    target.knock = { fromX: target.x, toX, startedAt: now };
    target.anim = null;
    this.animate(target, target.hp <= 0 ? 'meltdown' : pick(HURTS));
  }

  knockOut(fighter) {
    fighter.out = true;
    fighter.window.setOrigin(fighter.x, fighter.floor);
    this.animate(fighter, 'dazed');
    setTimeout(() => this.remove(fighter), 1400);
  }

  crown(fighter) {
    fighter.state = 'won';
    fighter.window.setOrigin(fighter.x, fighter.floor);
    this.animate(fighter, 'celebrating');
    this.engine.request('smug', true);
    this.engine.bark(pick(WINNER_LINES), 'always');
    setTimeout(() => { if (fighter.state === 'won') this.remove(fighter); }, 3500);
  }

  remove(fighter) {
    const index = this.fighters.indexOf(fighter);
    if (index < 0) return;
    this.fighters.splice(index, 1);
    fighter.machine.dispose();
    fighter.machine.removeAllListeners();
    fighter.window.dispose();
    if (!this.fighters.length) this.stopTicking();
  }

  stopTicking() { clearInterval(this.timer); this.timer = null; }

  /** Sends every copy away at once. */
  clear() {
    for (const fighter of [...this.fighters]) this.remove(fighter);
    this.stopTicking();
  }

  dispose() { this.clear(); }
}

module.exports = { Brawl };
