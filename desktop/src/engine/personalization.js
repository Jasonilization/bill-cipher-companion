// Port of Personalization/PersonalizationEngine.swift — Bill studies the apps
// on this machine and has ChatGPT write lines about each one, in batches that
// go live the moment they land.
const { EventEmitter } = require('events');
const platform = require('../platform');
const { personalized } = require('../core/stores');

const APPS_PER_BATCH = 8;
const MAX_APPS = 40;
const TRANSITION_APP_COUNT = 6;
const PER_REQUEST_TIMEOUT = 120 * 1000;
const MAX_LINE_LENGTH = 160;
const BUCKETS = ['morning', 'midday', 'afternoon', 'night'];

const machine = process.platform === 'win32' ? 'a Windows PC' : process.platform === 'linux' ? 'a Linux desktop' : 'a computer';
const freshMarker = () => `BILL-${100000 + Math.floor(Math.random() * 900000)}`;

function personaPreamble(marker, weather, extraInstructions) {
  let preamble = `${marker}\n`
    + 'You write dialogue for BILL CIPHER, the triangular dream demon from '
    + `Gravity Falls, living as a desktop companion on ${machine}. Voice: `
    + 'theatrical, ALL CAPS, menacing-but-fond of this user, deal-pitching '
    + 'energy. Reference actual Gravity Falls lore where it genuinely fits '
    + '— the Mystery Shack, Pine Tree, Shooting Star, Soos, the journals, '
    + 'Ford, Stan, Gideon, the gnomes, Blendin, Time Baby, Weirdmageddon, '
    + 'the Zodiac wheel, the bunker, Summerween, the Manotaurs, the '
    + 'Multi-Bear. Each line must contain a specific canon nod or in-joke, '
    + 'not just the show\'s name. Lines must be under 90 characters, in '
    + 'English, and work standalone with no numbering or quotes. Respond '
    + 'with ONLY the lines, one per line, in the exact formats given, and '
    + `begin your reply with ${marker} on its own line.`;
  if (weather) {
    preamble += `\nToday outside the user's window: ${weather}. `
      + 'Reference today\'s weather in a few of the lines where it genuinely fits — not all of them.';
  }
  const extra = String(extraInstructions || '').trim();
  if (extra) preamble += `\nAdditional persona notes from the user — honor them: ${extra}`;
  return preamble;
}

function appBatchPrompt(apps, marker, weather, extra) {
  return `${personaPreamble(marker, weather, extra)}\n`
    + 'For EACH app below, write FOUR lines about the user opening that '
    + 'app — one for MORNING, one for MIDDAY, one for AFTERNOON, one for '
    + 'NIGHT (the line should make sense at that time) — plus ONE short '
    + 'description of what the app is, in Bill\'s voice, under 70 '
    + 'characters. Format each EXACTLY, one per line:\n'
    + 'APP|<APP_ID>|<MORNING|MIDDAY|AFTERNOON|NIGHT>|<line>\n'
    + 'DESC|<APP_ID>|<description>\n\n'
    + `Apps:\n${apps.map((a) => `- ${a.name} (${a.id})`).join('\n')}`;
}

function transitionPrompt(pairs, marker, weather, extra) {
  return `${personaPreamble(marker, weather, extra)}\n`
    + 'For EACH ordered pair below, write ONE line about the user '
    + 'switching from the first app to the second. Format each EXACTLY, '
    + 'one per line:\n'
    + 'TRANS|<FROM_APP_ID>|<TO_APP_ID>|<line>\n\n'
    + `Pairs:\n${pairs.map((p) => `- ${p.from.name} to ${p.to.name} (${p.from.id} to ${p.to.id})`).join('\n')}`;
}

/**
 * Everything installed, plus anything Bill has watched you use that has no
 * launcher entry of its own (store apps, sites he tracks inside a browser) —
 * most-used first.
 */
async function enumerateApps(memory) {
  const seen = new Set(); const result = [];
  const add = (app) => {
    // The reply format is pipe-separated, so an id containing one could never round-trip.
    if (!app || !app.id || !app.name || app.id.includes('|') || seen.has(app.id)) return;
    seen.add(app.id);
    result.push({ id: app.id, name: app.name });
  };
  let installed = [];
  try { installed = await platform.installedApps(); } catch { installed = []; }
  installed.forEach(add);
  memory.knownApps().forEach(add);
  result.sort((a, b) => {
    const delta = memory.openCount(b.id) - memory.openCount(a.id);
    return delta !== 0 ? delta : a.name.localeCompare(b.name);
  });
  return result.slice(0, MAX_APPS);
}

function pairsAmong(apps) {
  const result = [];
  for (const from of apps) for (const to of apps) if (to.id !== from.id) result.push({ from, to });
  return result;
}

class PersonalizationEngine extends EventEmitter {
  constructor(memory) {
    super();
    this.memory = memory;
    this.model = {
      phase: 'intro', failure: null, finishedApps: 0, statusText: '', progress: 0,
      appCount: 0, batchIndex: 0, batchCount: 0, detectedApps: [], studiedApps: {},
    };
    this.send = null;
    this.presentLogin = null;
    this.onRunFinished = null;
    this.weatherBlurbProvider = null;
    this.extraInstructionsProvider = null;

    this.apps = []; this.batches = []; this.transitionPairs = [];
    this.marker = ''; this.pendingBatch = [];
    this.phase = 'appBatches';
    this.timeout = null;
    this.isRunning = false;
  }

  get isActive() { return this.isRunning; }
  update(changes) { Object.assign(this.model, changes); this.emit('change', this.model); }

  async previewDetectedApps() {
    if (this.isRunning) return;
    const apps = await enumerateApps(this.memory);
    if (this.isRunning) return;
    this.update({ detectedApps: apps.map((a) => a.name) });
  }

  async begin() {
    if (this.isRunning) return;
    this.isRunning = true;
    this.apps = await enumerateApps(this.memory);
    this.batches = [];
    for (let i = 0; i < this.apps.length; i += APPS_PER_BATCH) this.batches.push(this.apps.slice(i, i + APPS_PER_BATCH));
    this.transitionPairs = pairsAmong(this.apps.slice(0, TRANSITION_APP_COUNT));
    this.update({
      appCount: this.apps.length, batchCount: this.batches.length + (this.transitionPairs.length ? 1 : 0),
      batchIndex: 0, progress: 0, detectedApps: this.apps.map((a) => a.name), studiedApps: {},
    });
    if (!this.batches.length) { this.finish(); return; }
    this.update({ phase: 'generating', failure: null });
    this.phase = 'appBatches';
    this.requestNext();
  }

  cancel() {
    clearTimeout(this.timeout); this.timeout = null;
    const wasRunning = this.isRunning;
    this.isRunning = false;
    this.phase = 'done';
    this.update({ phase: 'failed', failure: 'Cancelled.' });
    if (wasRunning && this.onRunFinished) this.onRunFinished();
  }

  /** One reply from the page. A reply without this request's marker is someone else's. */
  handleResponse(raw) {
    clearTimeout(this.timeout); this.timeout = null;
    try {
      let text = String(raw || '').trim();
      if (!text || !text.startsWith(this.marker)) return;
      text = text.slice(this.marker.length).trim();
      if (this.phase === 'appBatches') this.parseAppBatch(text);
      else if (this.phase === 'transitions') this.parseTransitions(text);
    } finally {
      if (this.isRunning) this.requestNext();
    }
  }

  requestNext() {
    if (!this.isRunning) return;
    const weather = this.weatherBlurbProvider ? this.weatherBlurbProvider() : null;
    const extra = this.extraInstructionsProvider ? this.extraInstructionsProvider() : null;
    if (this.phase === 'appBatches') {
      if (!this.batches.length) {
        if (!this.transitionPairs.length) { this.finish(); return; }
        this.phase = 'transitions';
        this.requestNext();
        return;
      }
      this.pendingBatch = this.batches.shift();
      this.marker = freshMarker();
      this.update({
        batchIndex: this.model.batchIndex + 1,
        statusText: `Writing quips for ${this.pendingBatch.slice(0, 3).map((a) => a.name).join(', ')}…`,
      });
      if (this.send) this.send(appBatchPrompt(this.pendingBatch, this.marker, weather, extra));
      this.armTimeout();
    } else if (this.phase === 'transitions') {
      if (!this.transitionPairs.length) { this.finish(); return; }
      const pairs = this.transitionPairs;
      this.transitionPairs = [];
      this.marker = freshMarker();
      this.update({ batchIndex: this.model.batchIndex + 1, statusText: 'Writing transition lines…' });
      if (this.send) this.send(transitionPrompt(pairs, this.marker, weather, extra));
      this.armTimeout();
    }
  }

  armTimeout() {
    clearTimeout(this.timeout);
    this.timeout = setTimeout(() => {
      this.update({ statusText: 'One request went quiet — moving on.' });
      if (this.isRunning) this.requestNext();
    }, PER_REQUEST_TIMEOUT);
  }

  finish() {
    clearTimeout(this.timeout); this.timeout = null;
    this.isRunning = false;
    this.phase = 'done';
    this.update({ progress: 1, phase: 'finished', finishedApps: personalized.appCount });
    if (this.onRunFinished) this.onRunFinished();
  }

  requireLogin() {
    clearTimeout(this.timeout); this.timeout = null;
    this.isRunning = false;
    this.phase = 'done';
    this.update({ phase: 'needsLogin' });
    if (this.presentLogin) this.presentLogin();
    if (this.onRunFinished) this.onRunFinished();
  }

  parseAppBatch(text) {
    const names = new Map(this.pendingBatch.map((a) => [a.id, a.name]));
    let linesParsed = 0;
    const accepted = {};
    for (const rawLine of text.split(/\r?\n/)) {
      const fields = rawLine.split('|');
      if (fields[0] === 'APP' && fields.length === 4) {
        const [, id, bucket, line] = fields;
        if (!names.has(id) || !BUCKETS.includes(bucket.toLowerCase())) continue;
        const cleaned = line.trim();
        if (!cleaned || cleaned.length > MAX_LINE_LENGTH) continue;
        personalized.mergeAppLines(id, bucket.toLowerCase(), [cleaned]);
        linesParsed += 1;
        accepted[id] = (accepted[id] || 0) + 1;
      } else if (fields[0] === 'DESC' && fields.length === 3) {
        const [, id, description] = fields;
        if (!names.has(id)) continue;
        const cleaned = description.trim();
        if (!cleaned || cleaned.length > 100) continue;
        personalized.mergeDescription(id, cleaned);
      }
    }
    this.pendingBatch = [];
    const changes = { progress: this.model.batchIndex / Math.max(1, this.model.batchCount) };
    if (linesParsed > 0) {
      personalized.publish();
      const studied = { ...this.model.studiedApps };
      for (const [id, count] of Object.entries(accepted)) studied[names.get(id)] = (studied[names.get(id)] || 0) + count;
      Object.assign(changes, { statusText: `Studied ${linesParsed} lines' worth of apps.`, studiedApps: studied });
    }
    this.update(changes);
  }

  parseTransitions(text) {
    const ids = new Set(this.apps.map((a) => a.id));
    let parsed = 0;
    for (const rawLine of text.split(/\r?\n/)) {
      const fields = rawLine.split('|');
      if (fields.length !== 4 || fields[0] !== 'TRANS' || !ids.has(fields[1]) || !ids.has(fields[2])) continue;
      const cleaned = fields[3].trim();
      if (!cleaned || cleaned.length > MAX_LINE_LENGTH) continue;
      personalized.mergeTransition(fields[1], fields[2], [cleaned]);
      parsed += 1;
    }
    const changes = { progress: this.model.batchIndex / Math.max(1, this.model.batchCount) };
    if (parsed > 0) {
      personalized.publish();
      changes.statusText = `Learned ${parsed} switcheroo lines.`;
    }
    this.update(changes);
  }
}

module.exports = { PersonalizationEngine, enumerateApps, appBatchPrompt, transitionPrompt };
