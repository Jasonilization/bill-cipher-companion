// Port of Awareness/{WindowTitleReader,ScreenTextReader,AwarenessMonitor}.swift.
//
// Both tiers are opt-in, exactly as on the Mac. The difference is only in what
// the OS asks for: reading a window title needs no special permission on
// Windows or X11, and OCR uses the engine already on the machine.
const fs = require('fs');
const platform = require('../platform');
const { identify } = require('../core/apps');

// ------------------------------------------------------- window-title rules
const TITLE_RULES = [
  { appHints: ['classroom'], titleHints: ['to-do', 'todo', 'to do', 'assigned'], key: 'insight.classroomTodo' },
  { appHints: ['classroom'], titleHints: ['missing', 'overdue'], key: 'insight.classroomMissing' },
  { appHints: ['classroom'], titleHints: ['done', 'graded', 'turned in'], key: 'insight.classroomDone' },
  { appHints: ['slides'], titleHints: ['untitled'], key: 'insight.slidesUntitled' },
  { appHints: ['docs', 'document'], titleHints: ['untitled'], key: 'insight.docsUntitled' },
  { appHints: ['duolingo'], titleHints: ['practice', 'lesson', 'unit'], key: 'insight.duolingoLesson' },
  { appHints: ['github'], titleHints: ['pull request', '· pull'], key: 'insight.githubPR' },
  { appHints: ['github'], titleHints: ['issue'], key: 'insight.githubIssue' },
  { appHints: ['youtube'], titleHints: ['shorts'], key: 'insight.youtubeShorts' },
];

/** WindowTitleInsight.insight — first matching rule wins. */
function titleInsight(appName, title) {
  const app = String(appName || '').toLowerCase();
  const text = String(title || '').toLowerCase();
  for (const rule of TITLE_RULES) {
    if (!rule.appHints.some((hint) => app.includes(hint) || text.includes(hint))) continue;
    if (!rule.titleHints.some((hint) => text.includes(hint))) continue;
    return { key: rule.key, substitutions: { title } };
  }
  return null;
}

// ----------------------------------------------------------- OCR insights
function firstNumberNear(keyword, text) {
  const at = text.indexOf(keyword);
  if (at < 0) return null;
  const before = text.slice(Math.max(0, at - 12), at).match(/\d+/g);
  if (before) return Number(before[before.length - 1]);
  const after = text.slice(at + keyword.length, at + keyword.length + 8).match(/\d+/);
  return after ? Number(after[0]) : null;
}

/** ScreenTextInsight.insight — "you have 3 missing" is not something a title ever says. */
function screenTextInsight(appName, text) {
  const app = String(appName || '').toLowerCase();
  const body = String(text || '').toLowerCase();
  if (!app.includes('classroom')) return null;
  const missing = firstNumberNear('missing', body);
  if (missing > 0) return { key: 'insight.classroomMissingCount', substitutions: { count: String(missing) } };
  if (body.includes('no work due') || body.includes('nice work') || body.includes("you're all caught up")) return { key: 'insight.classroomClear', substitutions: {} };
  const assigned = firstNumberNear('assigned', body);
  if (assigned > 0) return { key: 'insight.classroomAssignedCount', substitutions: { count: String(assigned) } };
  if (body.includes('due today')) return { key: 'insight.classroomDueToday', substitutions: {} };
  return null;
}

const INTERESTING = ['classroom', 'slides', 'docs', 'duolingo', 'gmail'];
const PER_APP_COOLDOWN = 20 * 60 * 1000;

class ScreenTextReader {
  constructor() { this.lastCapture = new Map(); }

  static isInteresting(label) {
    const name = String(label || '').toLowerCase();
    return INTERESTING.some((hint) => name.includes(hint));
  }

  /** Captures one window and reads its text on-device. `label` is the app name plus its title. */
  async readWindow({ windowId, appId, label, force = false }) {
    if (!platform.ocrStatus.available) return null;
    if (!force && !ScreenTextReader.isInteresting(label)) return null;
    const last = this.lastCapture.get(appId);
    if (!force && last && Date.now() - last < PER_APP_COOLDOWN) return null;
    this.lastCapture.set(appId, Date.now());
    const capture = await platform.captureWindow(windowId);
    if (!capture) return null;
    try {
      if (capture.size.width <= 200 || capture.size.height <= 150) return null;
      return await platform.ocr(capture.file);
    } finally {
      fs.promises.unlink(capture.file).catch(() => {});
    }
  }
}

// ------------------------------------------------------- periodic sampling
const REPEAT_COOLDOWN = 25 * 60 * 1000;
const INTERVAL = 5 * 60 * 1000;

class AwarenessMonitor {
  constructor(prefs) {
    this.prefs = prefs;
    this.screenReader = new ScreenTextReader();
    this.timer = null;
    this.lastEmitted = new Map();
    this.onInsight = null;
  }

  start() {
    this.stop();
    if (!this.prefs.get('windowAwareness')) return;
    this.timer = setInterval(() => this.sample().catch(() => {}), INTERVAL);
  }
  stop() { clearInterval(this.timer); this.timer = null; }
  refresh() { if (this.prefs.get('windowAwareness')) this.start(); else this.stop(); }

  frontmost() {
    const fg = platform.foreground();
    return fg && !fg.own ? identify(fg) : null;
  }

  async sample() {
    if (!this.prefs.get('windowAwareness')) return;
    const app = this.frontmost();
    if (!app) return;
    const insight = await this.inspect(app);
    if (!insight) return;
    const last = this.lastEmitted.get(insight.key);
    if (last && Date.now() - last < REPEAT_COOLDOWN) return;
    this.lastEmitted.set(insight.key, Date.now());
    if (this.onInsight) this.onInsight(insight, app);
  }

  async inspect(app) {
    let resolved = app.title ? titleInsight(app.name, app.title) : null;
    if (this.prefs.get('screenOCR')) {
      const label = `${app.name} ${app.title}`;
      const text = await this.screenReader.readWindow({ windowId: app.windowId, appId: app.id, label });
      const deeper = text && screenTextInsight(label, text);
      if (deeper) resolved = deeper;
    }
    return resolved;
  }

  /** A staged report, so "nothing happened" is traceable to the exact stage that produced nothing. */
  async diagnose() {
    const app = this.frontmost();
    if (!app) return 'No frontmost application (or one of Bill\'s own windows has focus).';
    const out = [];
    const label = `${app.name} ${app.title}`;
    out.push(`Frontmost app:  ${app.name}  (pid ${app.pid}, id ${app.id})`, '');
    out.push('① WINDOW TITLE');
    out.push(`   Setting enabled:  ${this.prefs.get('windowAwareness') ? 'yes' : 'NO — turn on in Settings'}`);
    out.push('   Permission:       not required on this platform');
    out.push(`   Title read:       ${app.title ? `"${app.title}"` : 'nil'}`);
    if (app.title) out.push(`   Matched rule:     ${(titleInsight(app.name, app.title) || {}).key || 'none — no rule covers this app/title'}`);
    out.push('', '② SCREENSHOT + OCR');
    out.push(`   Setting enabled:  ${this.prefs.get('screenOCR') ? 'yes' : 'NO — turn on in Settings'}`);
    out.push(`   OCR engine:       ${platform.ocrStatus.available ? platform.ocrStatus.detail : `NOT AVAILABLE — ${platform.ocrStatus.detail}`}`);
    out.push(`   App worth reading: ${ScreenTextReader.isInteresting(label) ? 'yes' : 'no — only Classroom/Slides/Docs/Duolingo/Gmail are read'}`);
    if (this.prefs.get('screenOCR') && platform.ocrStatus.available) {
      const t0 = Date.now();
      const text = await this.screenReader.readWindow({ windowId: app.windowId, appId: app.id, label, force: true });
      const ms = Date.now() - t0;
      if (text) {
        const lines = text.split('\n').filter(Boolean);
        out.push(`   Captured + read:  ${lines.length} text runs, ${text.length} chars (${ms}ms)`);
        out.push(`   First few runs:   ${lines.slice(0, 5).join(' ⁄ ')}`);
        out.push(`   Matched rule:     ${(screenTextInsight(label, text) || {}).key || 'none — no count/keyword rule matched'}`);
      } else {
        out.push(`   Captured + read:  nothing (${ms}ms) — window too small, or the capture failed`);
      }
    }
    const final = await this.inspect(app);
    out.push('', `RESULT: ${final ? `would say ${final.key}` : 'nothing to say about this window'}`);
    return out.join('\n');
  }
}

module.exports = { titleInsight, screenTextInsight, ScreenTextReader, AwarenessMonitor };
