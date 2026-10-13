// Port of StudyMode/StudyMode.swift — a thirty-minute session in which Bill
// confronts (and, on repeat offences, puts away) anything that is not
// schoolwork.
const platform = require('../platform');
const { Key } = require('../core/dialogue');

const SESSION_LENGTH = 30 * 60 * 1000;
const HALFWAY_POINT = 15 * 60 * 1000;

const BLOCKED_CATEGORIES = new Set(['coding', 'gaming', 'tinkering', 'communication']);
const BLOCKED_NAMES = [
  'blender', 'terminal', 'iterm', 'docker', 'wireshark',
  'sdr', 'satdump', 'scarab', 'pragmata',
  'gmail', 'discord', 'slack', 'telegram', 'whatsapp', 'messenger', 'signal',
  'steam', 'epicgames', 'battle.net',
  // The same idea, as these desktops name it.
  'powershell', 'command prompt', 'konsole', 'epic games',
];
const ALLOWED_NAMES = [
  'safari', 'spotify', 'notes', 'canva', 'preview', 'calculator', 'dictionary',
  'google slides', 'google docs', 'google classroom', 'classroom', 'slides', 'docs',
  'keynote', 'pages', 'numbers', 'calendar', 'reminders', 'books', 'freeform',
  'notepad', 'onenote', 'word', 'powerpoint', 'excel', 'libreoffice', 'evince', 'okular',
];

/**
 * A blocklist, not an allowlist: an app nobody has heard of is allowed.
 * Names beat categories so a specific app can be an exception either way.
 */
function isBlocked(app) {
  const name = String(app.name || '').toLowerCase();
  const id = String(app.id || '').toLowerCase();
  if (BLOCKED_NAMES.some((n) => name.includes(n))) return true;
  if (ALLOWED_NAMES.some((n) => name.includes(n))) return false;
  if (BLOCKED_NAMES.some((n) => id.includes(n))) return true;
  return !!app.category && BLOCKED_CATEGORIES.has(app.category);
}

class StudyMode {
  constructor(prefs) {
    this.prefs = prefs;
    this.onStateChanged = null;
    this.announce = null;
    this.goToApp = null;
    this.endsAt = null;
    this.halfwayFired = false;
    this.timer = null;
    this.offences = new Map();
    this.lastAllowedWindow = null;
    // A session survives a relaunch: quitting Bill is not a way out of the
    // thirty minutes you asked for.
    const stored = prefs.get('studyModeEndsAt');
    if (stored > Date.now()) {
      this.endsAt = stored;
      this.halfwayFired = stored - Date.now() < HALFWAY_POINT;
      this.scheduleTick();
    }
  }

  get isActive() { return !!this.endsAt && this.endsAt > Date.now(); }
  get remaining() { return this.endsAt ? Math.max(0, this.endsAt - Date.now()) : 0; }

  start() {
    this.endsAt = Date.now() + SESSION_LENGTH;
    this.prefs.set('studyModeEndsAt', this.endsAt);
    this.halfwayFired = false;
    this.offences.clear();
    if (this.announce) this.announce(['study.start'], ['cultLeader', 'summoning', 'focused', 'channeling'], {});
    this.scheduleTick();
    if (this.onStateChanged) this.onStateChanged();
  }

  /** Returns false when the caller still has to ask the user to confirm. */
  cancel(confirmed) {
    if (!this.isActive) return true;
    if (!confirmed) return false;
    this.finish(false);
    return true;
  }

  finish(completed) {
    clearTimeout(this.timer); this.timer = null;
    this.endsAt = null;
    this.prefs.set('studyModeEndsAt', 0);
    this.offences.clear();
    if (this.announce) {
      this.announce(
        [completed ? 'study.end' : 'study.cancelled'],
        completed ? ['celebrating', 'happy', 'dancing', 'powerSurge'] : ['dreading', 'guilty', 'grumpEyes'],
        {},
      );
    }
    if (this.onStateChanged) this.onStateChanged();
  }

  scheduleTick() {
    clearTimeout(this.timer);
    // One timer, re-armed at each milestone — not a per-second countdown.
    const next = this.halfwayFired ? this.remaining : Math.max(1000, this.remaining - HALFWAY_POINT);
    this.timer = setTimeout(() => this.tick(), Math.max(1000, next));
  }

  tick() {
    if (!this.isActive) { this.finish(true); return; }
    if (!this.halfwayFired) {
      this.halfwayFired = true;
      if (this.announce) this.announce(['study.halfway'], ['celebrating', 'presenting', 'happy', 'kinship'], {});
      this.scheduleTick();
      return;
    }
    this.finish(true);
  }

  /** First refusal on every app activation. True means "handled — say nothing else". */
  intercept(app) {
    if (!this.isActive) return false;
    if (!isBlocked(app)) { this.lastAllowedWindow = app.windowId; return false; }

    const offence = (this.offences.get(app.id) || 0) + 1;
    this.offences.set(app.id, offence);

    // Bill goes there first, so the confrontation happens at the window.
    if (this.goToApp) this.goToApp(app);
    const states = offence === 1 ? ['watched', 'grumpEyes', 'huffy']
      : offence === 2 ? ['annoyed', 'dreading', 'stressed']
        : ['meltdown', 'shadowHands', 'cultLeader', 'tumbling'];
    if (this.announce) this.announce(Key.studyBlocked(offence), states, { app: app.name });

    // First offence is a warning only.
    if (offence < 2) return true;
    // Give the bark a beat to land, so the window going away reads as Bill doing it.
    setTimeout(() => this.putAway(app), offence === 2 ? 1600 : 400);
    return true;
  }

  putAway(app) {
    if (!this.isActive) return;
    platform.minimize(app.windowId);
    // Put the user back where they were allowed to be; if there is no such
    // window, do nothing rather than yanking focus somewhere arbitrary.
    if (this.lastAllowedWindow && this.lastAllowedWindow !== app.windowId) platform.activate(this.lastAllowedWindow);
  }
}

module.exports = { StudyMode, isBlocked, SESSION_LENGTH };
