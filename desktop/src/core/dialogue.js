// Port of Dialogue/{TimeOfDay,DialoguePool,DialogueLibrary,DialogueKey}.swift.
const fs = require('fs');

const BUCKETS = ['morning', 'midday', 'afternoon', 'night'];

function timeOfDay(date = new Date()) {
  const h = date.getHours();
  if (h >= 5 && h <= 10) return 'morning';
  if (h >= 11 && h <= 14) return 'midday';
  if (h >= 15 && h <= 20) return 'afternoon';
  return 'night';
}
const isDeadOfNight = (date = new Date()) => date.getHours() >= 1 && date.getHours() <= 4;

function emptyPool() { return { any: [], morning: [], midday: [], afternoon: [], night: [] }; }
function normalizePool(raw) {
  const p = emptyPool();
  if (raw) for (const b of ['any', ...BUCKETS]) if (Array.isArray(raw[b])) p[b] = raw[b].filter((l) => typeof l === 'string');
  return p;
}
const poolLineCount = (p) => p.any.length + BUCKETS.reduce((n, b) => n + p[b].length, 0);
const poolIsEmpty = (p) => poolLineCount(p) === 0;

/** A time bucket stands alone once it has 3+ lines; otherwise it is blended with `any`. */
function poolLines(pool, tod) {
  const bucket = pool[tod] || [];
  if (bucket.length >= 3) return bucket;
  if (bucket.length === 0) return pool.any;
  return bucket.concat(pool.any);
}

/** Case-insensitive dedupe merge, keeping only the newest `cap` lines per bucket. */
function mergePool(target, incoming, cap) {
  for (const b of ['any', ...BUCKETS]) {
    const seen = new Set(target[b].map((l) => l.toLowerCase()));
    for (const line of incoming[b] || []) {
      if (seen.has(line.toLowerCase())) continue;
      seen.add(line.toLowerCase());
      target[b].push(line);
    }
    if (target[b].length > cap) target[b] = target[b].slice(-cap);
  }
  return target;
}

// Every helper returns a *ladder*: the most specific key first, falling back
// to the general one, for `firstLine` to walk.
const Key = {
  battery: (n) => [`battery.${n}`, 'battery.step'],
  charge: (n) => (n >= 100 ? ['charge.full', 'charge.step'] : [`charge.${n}`, 'charge.step']),
  volume: (n) => [`volume.${n}`],
  clock: (h, m, tod = timeOfDay()) => [`clock.${String(h).padStart(2, '0')}${String(m).padStart(2, '0')}`, `clock.${tod}`],
  transition: (from, to) => [`transition.${from}->${to}`, 'transition.generic'],
  refocus: (n) => (n >= 1 && n <= 3 ? [`refocus.${n}`] : null),
  studyBlocked: (offence) => [`study.blocked${Math.min(3, Math.max(1, offence))}`],
};

class DialogueLibrary {
  constructor() {
    this.authored = {};
    this.generated = {};
    this.personalized = {};
    this.lastLine = {};
  }

  load(file) {
    try {
      const raw = JSON.parse(fs.readFileSync(file, 'utf8'));
      for (const key of Object.keys(raw)) this.authored[key] = normalizePool(raw[key]);
    } catch (e) {
      console.error('dialogue: could not load', file, e.message);
    }
  }

  setGenerated(pools) {
    this.generated = {};
    for (const k of Object.keys(pools || {})) this.generated[k] = normalizePool(pools[k]);
  }

  setPersonalized(pools) {
    this.personalized = {};
    for (const k of Object.keys(pools || {})) this.personalized[k] = normalizePool(pools[k]);
  }

  has(key) {
    return [this.personalized, this.authored, this.generated].some((s) => s[key] && !poolIsEmpty(s[key]));
  }

  candidates(key, tod) {
    // Personalized lines win their key outright.
    const personal = this.personalized[key];
    if (personal && !poolIsEmpty(personal)) return poolLines(personal, tod);
    const authored = this.authored[key] ? poolLines(this.authored[key], tod) : [];
    const generated = this.generated[key] ? poolLines(this.generated[key], tod) : [];
    if (!authored.length) return generated;
    if (generated.length && Math.random() < 0.3) return generated;
    return authored;
  }

  /** A line for `key`, with `{token}` substitutions applied; never the same line twice running. */
  line(key, substitutions = {}) {
    let lines = this.candidates(key, timeOfDay());
    if (!lines || !lines.length) return null;
    if (lines.length > 1) {
      const filtered = lines.filter((l) => l !== this.lastLine[key]);
      if (filtered.length) lines = filtered;
    }
    const chosen = lines[Math.floor(Math.random() * lines.length)];
    this.lastLine[key] = chosen;
    return substitute(chosen, substitutions);
  }

  /** The first key in `keys` that produces a line. */
  firstLine(keys, substitutions = {}) {
    for (const key of keys) {
      const l = this.line(key, substitutions);
      if (l) return l;
    }
    return null;
  }

  allKeys() {
    return [...new Set([...Object.keys(this.authored), ...Object.keys(this.generated), ...Object.keys(this.personalized)])].sort();
  }

  sourceCounts(key) {
    const count = (s) => (s[key] ? poolLineCount(s[key]) : 0);
    return { authored: count(this.authored), generated: count(this.generated), personalized: count(this.personalized) };
  }

  /** Every line in a pool, tagged with where it came from and when it applies. */
  poolDetail(key) {
    const out = [];
    for (const [source, store] of [['authored', this.authored], ['generated', this.generated], ['personalized', this.personalized]]) {
      const pool = store[key];
      if (!pool) continue;
      for (const b of ['any', ...BUCKETS]) for (const text of pool[b]) out.push({ source, time: b, text });
    }
    return out;
  }

  totalLines() {
    return this.allKeys().reduce((n, key) => {
      const c = this.sourceCounts(key);
      return n + c.authored + c.generated + c.personalized;
    }, 0);
  }
}

function substitute(text, substitutions) {
  let out = text;
  for (const [token, value] of Object.entries(substitutions || {})) out = out.split(`{${token}}`).join(String(value));
  return out;
}

module.exports = {
  BUCKETS, Key, DialogueLibrary, timeOfDay, isDeadOfNight, emptyPool, normalizePool, mergePool,
  poolLineCount, poolIsEmpty, substitute,
  library: new DialogueLibrary(),
};
