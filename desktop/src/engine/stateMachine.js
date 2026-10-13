// Port of Animation/BillStateMachine.swift.
//
// The Mac class drives SKActions directly. Here the *timing* lives in the main
// process (so behaviour never depends on a renderer being awake) and the
// renderer is told what to draw: 'clip' (play this), 'settle' (ease to rest).
const { EventEmitter } = require('events');
const { CLIPS, IDLE_VARIANTS, FX, singlePassDuration } = require('../core/clips');
const { priority, isContinuous, maxHoldDuration } = require('../core/states');

const MINIMUM_BARK_DISPLAY = 1.9;
const MAX_QUEUED_BARKS = 3;

class StateMachine extends EventEmitter {
  constructor() {
    super();
    this.currentState = 'idle';
    this.pendingWork = null;
    this.holdWork = null;
    this.barkQueue = [];
    this.isBarkShowing = false;
    this.barkDismissWork = null;
    this.isClipActive = false;
    this.isBarkActive = false;
  }

  /**
   * Request a state change. Continuous states keep running until something
   * interrupts them; one-shot beats settle back to idle on their own.
   */
  request(state, force = false) {
    if (state === 'idle') { this.settleToIdle(); return; }
    if (!CLIPS[state]) return;
    if (!force && priority(state) < priority(this.currentState)) return;
    if (state === this.currentState) return;
    this.play(state);
  }

  /** A short idle-only flourish that doesn't change `currentState`. */
  playIdleVariant(name) {
    if (this.currentState !== 'idle' || !IDLE_VARIANTS[name]) return;
    this.runClip(IDLE_VARIANTS[name], () => this.startAmbientIdle());
  }

  startAmbientIdle() {
    this.runClip(CLIPS.idle, null);
    // Ambient idle is the one clip that does not need the full frame rate.
    this.isClipActive = false;
    this.emit('activity', this.isBarkActive);
  }

  play(state) {
    this.currentState = state;
    this.emit('clipStarted', state);
    this.emit('state', state);
    const clip = CLIPS[state];
    clearTimeout(this.holdWork);
    this.holdWork = null;
    if (isContinuous(state)) {
      this.runClip(clip, null, FX[state] || null);
      // A continuous *reaction* releases itself so it cannot block roaming and idle forever.
      const hold = maxHoldDuration(state);
      if (hold !== null) {
        this.holdWork = setTimeout(() => { if (this.currentState === state) this.settleToIdle(); }, hold * 1000);
      }
    } else {
      this.runClip(clip, () => this.settleToIdle(), FX[state] || null);
    }
  }

  /** `fx === undefined` leaves whatever effect is showing alone. */
  runClip(clip, completion, fx) {
    clearTimeout(this.pendingWork);
    this.pendingWork = null;
    this.isClipActive = true;
    this.emit('activity', true);
    this.emit('clip', { clip, fx });
    if (!completion || clip.loop !== 'once') return;
    this.pendingWork = setTimeout(completion, singlePassDuration(clip) * 1000);
  }

  /** Stops whatever is playing and eases back to the rest pose, then resumes the idle bob. */
  settleToIdle() {
    clearTimeout(this.holdWork);
    this.holdWork = null;
    clearTimeout(this.pendingWork);
    const changed = this.currentState !== 'idle';
    this.currentState = 'idle';
    if (changed) this.emit('state', 'idle');
    this.isClipActive = true;
    this.emit('activity', true);
    this.emit('settle');
    this.pendingWork = setTimeout(() => this.startAmbientIdle(), 300);
  }

  // ------------------------------------------------------------------ barks
  /** Queued, not stomped: every line is guaranteed its time on screen. */
  showBark(text) {
    const trimmed = String(text || '').trim();
    if (!trimmed) return;
    this.barkQueue.push(trimmed);
    // The newest lines win: they describe what just happened.
    if (this.barkQueue.length > MAX_QUEUED_BARKS) this.barkQueue.splice(0, this.barkQueue.length - MAX_QUEUED_BARKS);
    this.drainBarkQueue();
  }

  clearBarkQueue() { this.barkQueue = []; }

  drainBarkQueue() {
    if (this.isBarkShowing || !this.barkQueue.length) return;
    const text = this.barkQueue.shift();
    this.isBarkShowing = true;
    this.isBarkActive = true;
    this.emit('activity', true);
    this.emit('bark', text);
    const displayDuration = Math.max(MINIMUM_BARK_DISPLAY, Math.min(6.0, text.length * 0.045));
    clearTimeout(this.barkDismissWork);
    this.barkDismissWork = setTimeout(() => {
      this.emit('barkFadeOut');
      this.isBarkShowing = false;
      if (this.barkQueue.length) { this.drainBarkQueue(); return; }
      this.isBarkActive = false;
      this.emit('activity', this.isClipActive);
    }, (0.2 + displayDuration) * 1000);
  }

  debugDump() {
    return `currentState=${this.currentState} isClipActive=${this.isClipActive} isBarkActive=${this.isBarkActive} queuedBarks=${this.barkQueue.length}`;
  }

  dispose() {
    clearTimeout(this.pendingWork); clearTimeout(this.holdWork); clearTimeout(this.barkDismissWork);
  }
}

module.exports = { StateMachine };
