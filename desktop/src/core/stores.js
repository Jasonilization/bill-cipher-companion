// Persistence: preferences (AppPreferences.swift), memory (MemoryStore.swift),
// animation coverage (AnimationCoverage.swift), personalized dialogue
// (PersonalizedDialogueStore.swift) and the refresh log (DialogueRefreshLog.swift).
// All are small JSON files in the per-user data directory, written atomically
// and coalesced so a burst of changes costs one write.
const fs = require('fs');
const path = require('path');
const { EventEmitter } = require('events');
const { normalizePool, emptyPool, poolIsEmpty, library } = require('./dialogue');
const { NOT_SHOWCASEABLE, ALL_STATES } = require('./states');

let dataDir = null;
const allFiles = [];

function setDataDir(dir) { dataDir = dir; fs.mkdirSync(dir, { recursive: true }); }

class JsonFile {
  constructor(name, delayMs) {
    this.name = name; this.delayMs = delayMs; this.timer = null; this.getData = null;
    allFiles.push(this);
  }
  get file() { return path.join(dataDir, this.name); }
  read() {
    try { return JSON.parse(fs.readFileSync(this.file, 'utf8')); } catch { return null; }
  }
  schedule(getData) {
    this.getData = getData;
    if (this.timer) return;
    this.timer = setTimeout(() => this.flush(), this.delayMs);
  }
  flush() {
    if (this.timer) { clearTimeout(this.timer); this.timer = null; }
    if (!this.getData) return;
    try {
      const tmp = `${this.file}.tmp`;
      fs.writeFileSync(tmp, JSON.stringify(this.getData()));
      fs.renameSync(tmp, this.file);
    } catch (e) { console.error('save failed', this.name, e.message); }
  }
}
function flushAll() { for (const f of allFiles) f.flush(); }

const dayKey = (d = new Date()) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
const pick = (arr) => arr[Math.floor(Math.random() * arr.length)];

// ---------------------------------------------------------------- Preferences
const PREF_DEFAULTS = {
  roaming: true, minimizeMischief: true, disabledCategories: [], windowAwareness: false, screenOCR: false,
  characterScale: 1.0, speakingFrequency: 1.0, bubbleAccentColorHex: 'fac726', bubbleTextScale: 1.0,
  chatBubbleMaxWidth: 600, ambientAnimationSpacing: 1.0, customAnimationMap: {}, promptRefreshesPerDay: 3,
  promptExtraInstructions: '', weatherEnabled: true, weatherAnnounceMinutes: 60, perAppAnimations: {},
  darkModeChrome: false, launchAtLogin: false, selectedSettingsSection: 'Appearance',
  didOfferPersonalizationSetup: false, studyModeEndsAt: 0, hotkey: 'Control+Alt+Space',
  // Troll: he plays with your windows and your cursor. Helpful: he keeps his hands to himself and offers to fix things.
  mode: 'troll', windowPranks: true, cursorPranks: true, helpOffers: true, solveHotkey: 'Control+Alt+S', brawlHotkey: 'Control+Alt+F',
};
const PREF_CHOICES = { mode: ['troll', 'helpful'] };
const PREF_RANGES = {
  characterScale: [0.5, 2.0], speakingFrequency: [0.25, 2.5], bubbleTextScale: [0.6, 2.4],
  chatBubbleMaxWidth: [320, 900], ambientAnimationSpacing: [0.25, 4.0], promptRefreshesPerDay: [1, 6],
  weatherAnnounceMinutes: [0, 240],
};

class Preferences extends EventEmitter {
  constructor() {
    super();
    this.store = new JsonFile('preferences.json', 300);
    this.values = { ...PREF_DEFAULTS };
  }
  load() {
    const raw = this.store.read() || {};
    for (const key of Object.keys(PREF_DEFAULTS)) {
      if (raw[key] !== undefined && typeof raw[key] === typeof PREF_DEFAULTS[key]) this.values[key] = raw[key];
    }
    for (const key of Object.keys(PREF_RANGES)) this.values[key] = clamp(this.values[key], ...PREF_RANGES[key]);
    for (const key of Object.keys(PREF_CHOICES)) if (!PREF_CHOICES[key].includes(this.values[key])) this.values[key] = PREF_DEFAULTS[key];
  }
  get(key) { return this.values[key]; }
  all() { return { ...this.values }; }
  set(key, value) {
    if (!(key in PREF_DEFAULTS)) return;
    if (PREF_CHOICES[key] && !PREF_CHOICES[key].includes(value)) return;
    if (PREF_RANGES[key]) value = clamp(Number(value) || 0, ...PREF_RANGES[key]);
    if (key === 'promptRefreshesPerDay' || key === 'weatherAnnounceMinutes') value = Math.round(value);
    if (JSON.stringify(this.values[key]) === JSON.stringify(value)) return;
    this.values[key] = value;
    this.store.schedule(() => this.values);
    this.emit('change', key, value);
    this.emit(`change:${key}`, value);
  }
  /** Falls back to Bill's own yellow on a malformed hex, like BillPalette.bubbleAccent. */
  accentColor() {
    const hex = String(this.values.bubbleAccentColorHex || '').replace('#', '');
    return /^[0-9a-fA-F]{6}$/.test(hex) ? `#${hex}` : '#fac726';
  }
}

// --------------------------------------------------------------------- Memory
class MemoryStore extends EventEmitter {
  constructor() {
    super();
    this.store = new JsonFile('memory.json', 1000);
    this.data = this.blank();
  }
  blank() {
    return {
      facts: [], firstLaunchDate: Date.now(), appOpenCounts: {}, appDisplayNames: {}, recentActivations: [],
      categoryOpenCounts: {}, chargingEventCount: 0, lowBatteryEventCount: 0, cumulativeIdleSeconds: 0,
      generatedDialogue: [], lastDialogueRefreshDate: 0, appDescriptions: {}, generatedPools: {},
      dailyCategoryCounts: {}, firstSeenDate: {},
    };
  }
  load() {
    const raw = this.store.read();
    if (raw && typeof raw === 'object') this.data = { ...this.blank(), ...raw };
    const pools = {};
    for (const k of Object.keys(this.data.generatedPools || {})) pools[k] = normalizePool(this.data.generatedPools[k]);
    this.data.generatedPools = pools;
  }
  save() { this.store.schedule(() => this.data); this.emit('change'); }

  get generatedPools() { return this.data.generatedPools; }
  get daysKnown() { return Math.max(0, Math.floor((Date.now() - this.data.firstLaunchDate) / 86400000)); }

  recordAppOpen(id, name, category) {
    const d = this.data;
    d.appOpenCounts[id] = (d.appOpenCounts[id] || 0) + 1;
    d.appDisplayNames[id] = name;
    if (!d.firstSeenDate[id]) d.firstSeenDate[id] = Date.now();
    d.recentActivations.push({ id, category: category || null, at: Date.now() });
    if (d.recentActivations.length > 60) d.recentActivations = d.recentActivations.slice(-60);
    if (category) {
      d.categoryOpenCounts[category] = (d.categoryOpenCounts[category] || 0) + 1;
      const day = dayKey();
      d.dailyCategoryCounts[day] = d.dailyCategoryCounts[day] || {};
      d.dailyCategoryCounts[day][category] = (d.dailyCategoryCounts[day][category] || 0) + 1;
      const days = Object.keys(d.dailyCategoryCounts).sort();
      for (const old of days.slice(0, Math.max(0, days.length - 14))) delete d.dailyCategoryCounts[old];
    }
    this.save();
  }
  isFirstSighting(id) { const seen = this.data.firstSeenDate[id]; return !seen || Date.now() - seen < 5000; }
  previousAppId(excluding) {
    const list = this.data.recentActivations;
    for (let i = list.length - 1; i >= 0; i--) if (list[i].id !== excluding) return list[i].id;
    return null;
  }
  previousCategory(excludingId) {
    const list = this.data.recentActivations;
    for (let i = list.length - 1; i >= 0; i--) if (list[i].id !== excludingId) return list[i].category;
    return null;
  }
  openCount(id) { return this.data.appOpenCounts[id] || 0; }
  description(id) { return this.data.appDescriptions[id] || null; }
  setAppDescription(id, text) { this.data.appDescriptions[id] = text; this.save(); }
  undescribedFrequentApps(minOpens = 2) {
    return Object.keys(this.data.appOpenCounts)
      .filter((id) => this.data.appOpenCounts[id] >= minOpens && !this.data.appDescriptions[id] && this.data.appDisplayNames[id])
      .sort((a, b) => this.data.appOpenCounts[b] - this.data.appOpenCounts[a])
      .map((id) => ({ id, name: this.data.appDisplayNames[id] }));
  }
  knownApps() {
    return Object.keys(this.data.appDisplayNames)
      .sort((a, b) => this.openCount(b) - this.openCount(a))
      .map((id) => ({ id, name: this.data.appDisplayNames[id] }));
  }
  countOn(category, day = dayKey()) { return (this.data.dailyCategoryCounts[day] || {})[category] || 0; }
  totalActivationsToday() {
    return Object.values(this.data.dailyCategoryCounts[dayKey()] || {}).reduce((a, b) => a + b, 0);
  }
  /** "coding ×12, music ×3, charged 2×" — fed to ChatGPT as context. */
  get recentActivitySummary() {
    const parts = Object.entries(this.data.categoryOpenCounts)
      .sort((a, b) => b[1] - a[1]).slice(0, 3).map(([c, n]) => `${c} ×${n}`);
    if (this.data.chargingEventCount > 0) parts.push(`charged ${this.data.chargingEventCount}×`);
    return parts.join(', ');
  }
  noteCharging() { this.data.chargingEventCount += 1; this.save(); }
  noteLowBattery() { this.data.lowBatteryEventCount += 1; this.save(); }
  setGeneratedPools(pools) { this.data.generatedPools = pools; this.data.lastDialogueRefreshDate = Date.now(); this.save(); }
  shouldRefreshDialogue(intervalSeconds) {
    return Date.now() - (this.data.lastDialogueRefreshDate || 0) >= intervalSeconds * 1000;
  }
  markRefreshAttempt() { this.data.lastDialogueRefreshDate = Date.now(); this.save(); }
  addFact(fact) { this.data.facts.push(fact); this.data.facts = this.data.facts.slice(-50); this.save(); }
  reset() { this.data = this.blank(); this.save(); }
}

// ------------------------------------------------------------------- Coverage
// Makes sure every animation is actually seen: tracks what played today and
// prefers whatever has been shown least.
class AnimationCoverage {
  constructor() {
    this.store = new JsonFile('animation-coverage.json', 5000);
    this.data = { lastPlayed: {}, daysShown: {}, lastRolloverDay: dayKey() };
    this.lastPicked = null;
    this.shownToday = new Set();
  }
  load() {
    const raw = this.store.read();
    if (raw) this.data = { lastPlayed: raw.lastPlayed || {}, daysShown: raw.daysShown || {}, lastRolloverDay: raw.lastRolloverDay || dayKey() };
    const today = dayKey();
    for (const [state, at] of Object.entries(this.data.lastPlayed)) if (dayKey(new Date(at)) === today) this.shownToday.add(state);
    this.rollover();
  }
  rollover() {
    const today = dayKey();
    if (this.data.lastRolloverDay !== today) { this.data.lastRolloverDay = today; this.shownToday.clear(); }
  }
  record(state) {
    this.rollover();
    if (!this.shownToday.has(state)) {
      this.shownToday.add(state);
      this.data.daysShown[state] = (this.data.daysShown[state] || 0) + 1;
    }
    this.data.lastPlayed[state] = Date.now();
    this.store.schedule(() => this.data);
  }
  /** Drops the last pick, then prefers states unseen today with the fewest days shown. */
  pick(from) {
    this.rollover();
    if (!from || !from.length) return null;
    let pool = from.length > 1 ? from.filter((s) => s !== this.lastPicked) : from;
    const unseen = pool.filter((s) => !this.shownToday.has(s));
    if (unseen.length) {
      const min = Math.min(...unseen.map((s) => this.data.daysShown[s] || 0));
      pool = unseen.filter((s) => (this.data.daysShown[s] || 0) === min);
    }
    this.lastPicked = pick(pool);
    return this.lastPicked;
  }
  unseenToday() {
    this.rollover();
    return ALL_STATES.filter((s) => !NOT_SHOWCASEABLE.has(s) && !this.shownToday.has(s))
      .sort((a, b) => (this.data.daysShown[a] || 0) - (this.data.daysShown[b] || 0));
  }
  /** Seconds until the next catch-up showcase, pacing the backlog to finish by 23:00. */
  nextCatchUpDelay() {
    const remaining = this.unseenToday().length;
    if (!remaining) return null;
    const deadline = new Date(); deadline.setHours(23, 0, 0, 0);
    const left = (deadline - Date.now()) / 1000;
    if (left <= 0) return 90;
    return clamp(left / remaining, 90, 20 * 60);
  }
}

// ------------------------------------------------------ Personalized dialogue
class PersonalizedStore {
  constructor() {
    this.store = new JsonFile('PersonalizedDialogue.json', 300);
    this.payload = { generatedAt: null, appLines: {}, appDescriptions: {}, transitions: {} };
  }
  load() {
    const raw = this.store.read();
    if (!raw) return;
    this.payload.generatedAt = raw.generatedAt || null;
    for (const id of Object.keys(raw.appLines || {})) this.payload.appLines[id] = normalizePool(raw.appLines[id]);
    this.payload.appDescriptions = raw.appDescriptions || {};
    this.payload.transitions = raw.transitions || {};
  }
  save() { this.payload.generatedAt = Date.now(); this.store.schedule(() => this.payload); }
  get appCount() { return Object.values(this.payload.appLines).filter((p) => !poolIsEmpty(p)).length; }
  get isPersonalized() { return this.appCount > 0; }
  description(id) { return this.payload.appDescriptions[id] || null; }
  appKey(id) { return `papp.${id}`; }
  transitionKey(from, to) { return `ptransapp.${from}->${to}`; }
  mergeAppLines(id, bucket, lines) {
    const pool = this.payload.appLines[id] || emptyPool();
    const target = pool[bucket] ? bucket : 'any';
    const seen = new Set(pool[target].map((l) => l.toLowerCase()));
    for (const line of lines) if (!seen.has(line.toLowerCase())) { seen.add(line.toLowerCase()); pool[target].push(line); }
    pool[target] = pool[target].slice(-3);
    this.payload.appLines[id] = pool;
    this.save();
  }
  mergeDescription(id, description) { this.payload.appDescriptions[id] = description; this.save(); }
  mergeTransition(from, to, lines) {
    const key = `${from}->${to}`;
    const existing = this.payload.transitions[key] || [];
    for (const line of lines) if (!existing.includes(line)) existing.push(line);
    this.payload.transitions[key] = existing.slice(-3);
    this.save();
  }
  dialoguePools() {
    const out = {};
    for (const [id, pool] of Object.entries(this.payload.appLines)) if (!poolIsEmpty(pool)) out[`papp.${id}`] = pool;
    for (const [pair, lines] of Object.entries(this.payload.transitions)) if (lines.length) out[`ptransapp.${pair}`] = { ...emptyPool(), any: lines };
    return out;
  }
  publish() { library.setPersonalized(this.dialoguePools()); }
}

// ---------------------------------------------------------------- Refresh log
class RefreshLog extends EventEmitter {
  constructor() {
    super();
    this.store = new JsonFile('dialogue-refresh-log.json', 500);
    this.entries = [];
  }
  load() { const raw = this.store.read(); if (Array.isArray(raw)) this.entries = raw.slice(-30); }
  touch() { this.entries = this.entries.slice(-30); this.store.schedule(() => this.entries); this.emit('change'); }
  begin(trigger, prompt) {
    const id = `${Date.now()}-${Math.floor(Math.random() * 1e6)}`;
    this.entries.push({ id, startedAt: Date.now(), finishedAt: null, trigger, prompt, rawResponse: null, linesAdded: [], descriptions: [], failureReason: null, status: 'running' });
    this.touch();
    return id;
  }
  finish(id, { rawResponse = null, linesAdded = [], descriptions = [], failureReason = null }) {
    const entry = this.entries.find((e) => e.id === id);
    if (!entry) return;
    Object.assign(entry, { finishedAt: Date.now(), rawResponse, linesAdded, descriptions, failureReason, status: failureReason ? 'failed' : 'ok' });
    this.touch();
  }
  recordImmediateFailure(trigger, reason) {
    this.entries.push({ id: `${Date.now()}-f`, startedAt: Date.now(), finishedAt: Date.now(), trigger, prompt: null, rawResponse: null, linesAdded: [], descriptions: [], failureReason: reason, status: 'failed' });
    this.touch();
  }
  clear() { this.entries = []; this.touch(); }
}

module.exports = {
  setDataDir, flushAll, dayKey, clamp, pick,
  PREF_DEFAULTS, PREF_RANGES,
  prefs: new Preferences(),
  memory: new MemoryStore(),
  coverage: new AnimationCoverage(),
  personalized: new PersonalizedStore(),
  refreshLog: new RefreshLog(),
};
