// Port of CharacterEngine/HabitNagger.swift — "you haven't done any homework /
// learning / anything fun today". Checked on the half-hour chime, late in the
// day only, at most twice, and never before there is enough activity to judge.
const { dayKey, pick } = require('../core/stores');

const EARLIEST_HOUR = 15;
const LATEST_HOUR = 23;
const MAX_PER_DAY = 2;
const MINIMUM_GAP = 3 * 60 * 60 * 1000;
const MINIMUM_ACTIVITY = 12;

class HabitNagger {
  constructor(memory) {
    this.memory = memory;
    this.onNag = null;
    this.nagsToday = 0;
    this.nagDay = '';
    this.lastNagKey = null;
    this.lastNagAt = 0;
  }

  considerNagging(now = new Date()) {
    this.rolloverIfNeeded(now);
    const hour = now.getHours();
    if (hour < EARLIEST_HOUR || hour > LATEST_HOUR) return;
    if (this.nagsToday >= MAX_PER_DAY) return;
    if (this.lastNagAt && now.getTime() - this.lastNagAt < MINIMUM_GAP) return;
    if (this.memory.totalActivationsToday() < MINIMUM_ACTIVITY) return;
    const key = this.chooseNag();
    if (!key) return;
    this.nagsToday += 1;
    this.lastNagAt = now.getTime();
    this.lastNagKey = key;
    if (this.onNag) this.onNag(key);
  }

  chooseNag() {
    let candidates = [];
    // "Productivity" is where docs/slides/notes/school apps live — the closest
    // honest proxy for "did any schoolwork happen".
    if (this.memory.countOn('productivity') === 0) candidates.push('nag.homework');
    if (this.memory.countOn('productivity') > 0 && this.memory.countOn('creative') === 0) candidates.push('nag.education');
    // All work and no chaos.
    if (this.memory.countOn('gaming') === 0 && this.memory.countOn('music') === 0) candidates.push('nag.fun');
    if (!candidates.length) return null;
    if (candidates.length > 1 && this.lastNagKey) candidates = candidates.filter((k) => k !== this.lastNagKey);
    return pick(candidates);
  }

  rolloverIfNeeded(now) {
    const today = dayKey(now);
    if (this.nagDay === today) return;
    this.nagDay = today;
    this.nagsToday = 0;
    this.lastNagKey = null;
    this.lastNagAt = 0;
  }
}

module.exports = { HabitNagger };
