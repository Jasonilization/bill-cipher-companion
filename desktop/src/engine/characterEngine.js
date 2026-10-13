// Port of CharacterEngine/CharacterEngine.swift — Bill's behaviour brain:
// idle-variety beats, rare Easter eggs, fan-service lines and the daily
// showcase that makes sure the whole animation library is actually seen.
const { StateMachine } = require('./stateMachine');
const { CLIPS, singlePassDuration } = require('../core/clips');
const { RARE_EASTER_EGGS } = require('../core/states');
const { coverage, pick } = require('../core/stores');
const { library } = require('../core/dialogue');
const BarkLines = require('../core/barklines');

const RARE_EVENT_CHANCE = 0.10;
const RARE_EVENT_COOLDOWN = 3 * 60;
const COMMON_TIER_CHANCE = 0.55;
const SELDOM_TIER_CHANCE = 0.05;
const FAN_SERVICE_CHANCE = 0.06;
const CIPHER_CHANCE = 0.30;

const IDLE_COMMON = [
  'talking', 'thinking', 'happy', 'smug', 'confused', 'dazed', 'poked', 'surprised', 'coding', 'focused',
  'caneFlourish', 'caneTwist', 'celebrating', 'grumpEyes',
];
const IDLE_UNCOMMON = [
  'annoyed', 'channeling', 'gaming', 'guilty', 'dreading', 'grooving', 'dispatching', 'ambushed', 'stressed',
  'watched', 'flinching', 'huffy', 'pushingCode', 'browsingStore', 'dancing', 'sculpting', 'kinship',
  'fractaling', 'presenting', 'trickster', 'darkWorld', 'hollowed', 'cultLeader', 'spooked', 'scanning',
  'sneaking', 'glitching', 'charged', 'transferring', 'summoning', 'hookCane', 'conjuring', 'tumbling',
  'dashTarget',
];
// Meltdown and shadow hands only — rampaging (the red shooting cloud) is
// deliberately not in any random rotation.
const IDLE_SELDOM = ['meltdown', 'shadowHands'];

const randomIn = (lo, hi) => lo + Math.random() * (hi - lo);

class CharacterEngine {
  constructor() {
    this.stateMachine = new StateMachine();
    this.coverage = coverage;
    this.isRunning = false;
    this.idleBeatTimer = null;
    this.catchUpTimer = null;
    this.lastRareEventAt = 0;
    this.lastIdleState = null;
    this.pendingBeatExtension = null;
    /** Probability that an ordinary contextual line is spoken; also quickens the idle beat. */
    this.speakingFrequencyMultiplier = 1.0;
    /** Multiplies the spacing between ambient idle beats. */
    this.ambientAnimationSpacingMultiplier = 1.0;
  }

  start() {
    if (this.isRunning) return;
    this.isRunning = true;
    this.stateMachine.request('idle');
    this.stateMachine.on('clipStarted', (state) => this.coverage.record(state));
    this.scheduleNextIdleBeat();
    this.scheduleNextCatchUp();
  }

  stop() {
    this.isRunning = false;
    clearTimeout(this.idleBeatTimer);
    clearTimeout(this.catchUpTimer);
    this.stateMachine.dispose();
  }

  /** Entry point for reactions: chat bridge, system monitor, debug menu. */
  request(state, force = false) { this.stateMachine.request(state, force); }

  /** `importance` is 'normal' (subject to the speaking-frequency slider) or 'always'. */
  bark(text, importance = 'normal') {
    if (!text) return;
    if (importance === 'normal' && !this.shouldSpeak()) return;
    this.stateMachine.showBark(text);
  }

  shouldSpeak() {
    return Math.random() < Math.min(1, Math.max(0, this.speakingFrequencyMultiplier));
  }

  scheduleNextIdleBeat() {
    clearTimeout(this.idleBeatTimer);
    const hold = this.pendingBeatExtension || 0;
    this.pendingBeatExtension = null;
    const delay = Math.max(randomIn(4, 9) * this.ambientAnimationSpacingMultiplier / Math.max(0.5, this.speakingFrequencyMultiplier), hold);
    this.idleBeatTimer = setTimeout(() => this.fireIdleBeat(), delay * 1000);
  }

  fireIdleBeat() {
    if (!this.isRunning) return;
    try {
      if (this.stateMachine.currentState !== 'idle') return;
      if (this.rollFanServiceBark()) return;
      if (this.rollRareEvent()) return;
      const roll = Math.random();
      if (roll < COMMON_TIER_CHANCE) this.playIdle(IDLE_COMMON);
      else if (roll < COMMON_TIER_CHANCE + SELDOM_TIER_CHANCE) this.playIdle(IDLE_SELDOM);
      else this.playIdle(IDLE_UNCOMMON);
    } finally {
      this.scheduleNextIdleBeat();
    }
  }

  playIdle(states) {
    const candidates = states.filter((s) => s !== this.lastIdleState);
    const state = pick(candidates.length ? candidates : states);
    if (!state) return;
    this.lastIdleState = state;
    this.stateMachine.request(state, true);
    this.holdBeat(state);
  }

  /** Extends the next beat so the clip that just started is guaranteed to finish (plus a gap). */
  holdBeat(state) {
    this.pendingBeatExtension = Math.max(this.pendingBeatExtension || 0, singlePassDuration(CLIPS[state]) + 0.8);
  }

  /** Occasionally the idle beat is a *line*, not a move: a deal offer, or a Journal-3 style cipher. */
  rollFanServiceBark() {
    if (Math.random() >= FAN_SERVICE_CHANCE) return false;
    const line = library.line(Math.random() < CIPHER_CHANCE ? 'cipher.message' : 'deal.offer');
    if (!line) return false;
    this.bark(line, 'always');
    this.pendingBeatExtension = Math.max(this.pendingBeatExtension || 0, 2.5);
    return true;
  }

  rollRareEvent() {
    if (Date.now() - this.lastRareEventAt < RARE_EVENT_COOLDOWN * 1000) return false;
    if (Math.random() >= RARE_EVENT_CHANCE) return false;
    const event = this.coverage.pick(RARE_EASTER_EGGS);
    if (!event) return false;
    this.lastRareEventAt = Date.now();
    this.stateMachine.request(event, true);
    this.holdBeat(event);
    this.bark(BarkLines.random(BarkLines.rareEvent(event)));
    return true;
  }

  // ------------------------------------------------- daily animation catch-up
  scheduleNextCatchUp() {
    clearTimeout(this.catchUpTimer);
    if (!this.isRunning) return;
    const delay = this.coverage.nextCatchUpDelay();
    if (delay === null || delay === undefined) {
      // Nothing owed. Midnight refills the backlog, so look again later.
      this.catchUpTimer = setTimeout(() => this.scheduleNextCatchUp(), 30 * 60 * 1000);
      return;
    }
    this.catchUpTimer = setTimeout(() => this.fireCatchUp(), delay * 1000);
  }

  fireCatchUp() {
    try {
      if (!this.isRunning) return;
      // Only ever from genuine rest — never interrupt a reaction, a chat or a roaming beat.
      if (this.stateMachine.currentState !== 'idle') return;
      const state = this.coverage.pick(this.coverage.unseenToday());
      if (!state) return;
      this.stateMachine.request(state, true);
      const line = BarkLines.showcaseLine(state);
      if (line) this.bark(line);
    } finally {
      this.scheduleNextCatchUp();
    }
  }
}

module.exports = { CharacterEngine };
