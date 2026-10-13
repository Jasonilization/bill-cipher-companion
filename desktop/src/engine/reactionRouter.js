// Port of CharacterEngine/ReactionRouter.swift — the one place system events
// and character behaviour meet.
//
// Two rules hold across every path here:
//  - Animations never repeat back-to-back: every reaction picks its state
//    through the coverage tracker from a *pool* of plausible animations.
//  - Bill only speaks about things that actually happened: every line is
//    attached to a real event and looked up in the dialogue library, which
//    selects a time-of-day-appropriate variant.
const { library, Key } = require('../core/dialogue');
const { personalized } = require('../core/stores');
const { specialState } = require('../core/apps');
const { ALL_STATES } = require('../core/states');
const { titleInsight, screenTextInsight, ScreenTextReader } = require('./awareness');

const BOUNCE_WINDOW = 4 * 1000;
const MAX_REFOCUS_LINES = 3;
const WEATHER_BARK_COOLDOWN = 10 * 60 * 1000;
const INCOGNITO_COOLDOWN = 10 * 60 * 1000;
const UNCATEGORIZED_FREQUENT_THRESHOLD = 3;

const BATTERY_DRAINING = ['stressed', 'dreading', 'huffy', 'grumpEyes', 'watched', 'annoyed', 'confused'];
// `charging` must stay in this pool — this event is its only real-world trigger.
const BATTERY_CHARGING = ['charging', 'charged', 'celebrating', 'happy', 'powerSurge', 'transferring'];
const VOLUME = ['dancing', 'grooving', 'happy', 'flinching', 'surprised', 'caneFlourish', 'kinship'];
const NETWORK_DOWN = ['confused', 'glitchForm', 'spooked', 'dazed', 'glitching', 'ambushed'];
const NETWORK_UP = ['celebrating', 'happy', 'charged', 'zipAround', 'fractaling'];
const CLOCK = ['presenting', 'dispatching', 'watched', 'smug', 'zodiacVision', 'caneTwist', 'hookCane', 'focused', 'scanning', 'conjuring'];
const INSIGHT = ['watched', 'scanning', 'presenting', 'dreading', 'guilty', 'smug', 'focused'];
const NAG = ['dreading', 'guilty', 'grumpEyes', 'annoyed', 'huffy', 'stressed', 'cultLeader'];
const WEATHER = ['watched', 'scanning', 'smug', 'caneTwist', 'presenting', 'zodiacVision', 'conjuring'];

const INCOGNITO_PATTERNS = ['incognito', 'private browsing', 'inprivate', 'private window', 'private tab', 'new private'];

const CATEGORY_REACTIONS = {
  coding: [['coding', 'pushingCode', 'focused', 'thinking'], 'coding'],
  gaming: [['gaming', 'browsingStore', 'celebrating', 'trickster'], 'gaming'],
  creative: [['sculpting', 'kinship', 'presenting', 'conjuring'], 'creative'],
  music: [['dancing', 'grooving', 'happy'], 'music'],
  browsing: [['scanning', 'watched', 'confused'], 'browsing'],
  finder: [['scanning', 'confused', 'focused'], 'finder'],
  communication: [['talking', 'dispatching', 'kinship'], 'communication'],
  productivity: [['focused', 'presenting', 'dreading', 'sculpting'], 'productivity'],
  aiChat: [['smug', 'glitching', 'watched'], 'aiChat'],
  tinkering: [['channeling', 'summoning', 'scanning', 'transferring'], 'tinkering'],
};

class ReactionRouter {
  constructor({ characterEngine, prefs, memory }) {
    this.engine = characterEngine;
    this.prefs = prefs;
    this.memory = memory;
    this.screenReader = new ScreenTextReader();
    /** Sends Bill to physically stand on an app's window. */
    this.goToApp = null;
    this.habitNagger = null;
    /** Study Mode gets first refusal on every activation; returns true if it handled it. */
    this.studyModeInterceptor = null;
    /** Name of whatever app is frontmost right now, for insight lines. */
    this.frontmostName = null;

    // Per-session focus state — deliberately in memory, not persisted: a
    // relaunch should not silently owe you three refocus lines from yesterday.
    this.seenThisSession = new Set();
    this.refocusCount = new Map();
    this.previousFocusTag = null;
    this.previousAppId = null;
    this.lastActivationAt = new Map();
    this.lastWeatherBarkAt = 0;
    this.lastIncognitoTriggerAt = 0;
    this.idleStartedAt = null;
  }

  handle(event) {
    switch (event.type) {
      case 'appActivated':
        this.frontmostName = event.app.name;
        this.memory.recordAppOpen(event.app.id, event.app.name, event.app.category);
        this.handleAppActivated(event.app);
        break;
      case 'batteryLow':
        this.memory.noteLowBattery();
        this.play(BATTERY_DRAINING, ['batteryLow'], {}, 'always');
        break;
      case 'batteryLevel': this.handleBatteryLevel(event.percent, event.isCharging); break;
      case 'batteryCharging':
        this.memory.noteCharging();
        this.play(BATTERY_CHARGING, ['batteryCharging']);
        break;
      case 'batteryUnplugged': this.engine.request('idle'); break;
      case 'networkLost': this.play(NETWORK_DOWN, ['networkLost'], {}, 'always'); break;
      case 'networkRestored': this.play(NETWORK_UP, ['networkRestored']); break;
      case 'networkQualityChanged': this.handleNetworkQuality(event.quality); break;
      case 'cpuHot':
        this.engine.request('heatingUp');
        this.speak(['cpuHot']);
        break;
      case 'cpuNormal': this.engine.request('idle'); break;
      case 'userIdle':
        this.idleStartedAt = Date.now();
        this.speak(['gettingSleepy']);
        this.engine.request('sleeping');
        break;
      case 'userReturned': this.handleUserReturned(); break;
      case 'volumeMark': this.play(VOLUME, Key.volume(event.percent)); break;
      case 'volumeMuteChanged': this.play(VOLUME, [event.isMuted ? 'volume.mute' : 'volume.unmute']); break;
      case 'halfHour':
        this.handleHalfHour(event.hour, event.minute);
        // Piggy-backed on the chime rather than given its own timer.
        if (this.habitNagger) this.habitNagger.considerNagging();
        break;
      case 'timeOfDayChanged': break; // the dialogue pools swap themselves
      case 'weatherChanged': this.handleWeatherReport(event.snapshot, event.reason); break;
      default: break;
    }
  }

  // ---------------------------------------------------------------- weather
  handleWeatherReport(snapshot, reason) {
    const loud = reason === 'firstPull' || reason === 'forcedTest';
    if (!loud && Date.now() - this.lastWeatherBarkAt < WEATHER_BARK_COOLDOWN) return;
    this.lastWeatherBarkAt = Date.now();
    const temp = String(Math.round(snapshot.temperatureC));
    this.play(WEATHER, [`weather.${snapshot.condition}`], { temp }, loud ? 'always' : 'normal');
  }

  // -------------------------------------------------------------- incognito
  /** The ONLY trigger for the red shooting cloud — no random rotation or showcase ever fires it. */
  checkIncognitoBrowsing(title, appName) {
    if (Date.now() - this.lastIncognitoTriggerAt <= INCOGNITO_COOLDOWN) return false;
    const lower = title.toLowerCase();
    if (!INCOGNITO_PATTERNS.some((p) => lower.includes(p))) return false;
    this.lastIncognitoTriggerAt = Date.now();
    this.engine.request('rampaging', true);
    this.speak(['incognito.search'], { app: appName }, 'always');
    return true;
  }

  // --------------------------------------------------------- app activation
  handleAppActivated(app) {
    // A blocked app is confronted, not commented on.
    if (this.studyModeInterceptor && this.studyModeInterceptor(app) === true) return;

    // Collapse duplicate activations and rapid alt-tab bounces.
    const last = this.lastActivationAt.get(app.id);
    this.lastActivationAt.set(app.id, Date.now());
    if (last && Date.now() - last < BOUNCE_WINDOW) return;

    const tag = this.focusTag(app);
    if (this.seenThisSession.has(app.id)) {
      this.handleRefocus(app);
    } else {
      this.seenThisSession.add(app.id);
      this.handleFirstOpen(app, tag);
    }
    this.previousFocusTag = tag;
    this.previousAppId = app.id;
    this.observeWindowTitle(app);
  }

  /** Looks at *what* you have open, not just which app. Fully optional and never blocks. */
  observeWindowTitle(app) {
    if (!this.prefs.get('windowAwareness') || !app.title) return;
    // A browser's own name is what the line should mention, not the site's.
    const appName = app.browserName || app.name;
    if (this.checkIncognitoBrowsing(app.title, appName)) return;
    (async () => {
      let resolved = titleInsight(app.name, app.title);
      // The title gets the section; OCR gets the numbers. Only when explicitly
      // enabled, for a handful of apps, on a 20-minute per-app cooldown.
      if (this.prefs.get('screenOCR')) {
        const label = `${app.name} ${app.title}`;
        const text = await this.screenReader.readWindow({ windowId: app.windowId, appId: app.id, label });
        const deeper = text && screenTextInsight(label, text);
        if (deeper) resolved = deeper;
      }
      if (!resolved) return;
      // Behind the app's own line, so it reads "oh, Classroom" then "...the to-do list, specifically".
      this.play(INSIGHT, [resolved.key], { ...resolved.substitutions, app: app.name });
    })().catch(() => {});
  }

  /** The first activation of an app in a session always reacts, with no cooldown of any kind. */
  handleFirstOpen(app, tag) {
    const { id, name, category } = app;
    if (category && this.prefs.get('disabledCategories').includes(category)) return;

    // A transition line first, when we came from somewhere interesting:
    // this user's own app pair, then the authored tag-pair/generic ladder.
    const from = this.previousFocusTag;
    if (from && from !== tag) {
      const pairLine = this.previousAppId
        ? library.firstLine([personalized.transitionKey(this.previousAppId, id)], { app: name })
        : null;
      const line = pairLine || library.firstLine(Key.transition(from, tag), { app: name });
      if (line) this.engine.bark(line);
    }

    // Then the app's own reaction: the user's explicit per-app assignment
    // first, then the special-state and category buckets.
    const special = specialState(id, name);
    const assigned = this.prefs.get('perAppAnimations')[id];
    if (assigned && ALL_STATES.includes(assigned)) {
      if (this.goToApp) this.goToApp(app);
      this.engine.request(assigned, true);
      if (special) this.speak([personalized.appKey(id), special], { app: name });
      else this.speak(['appLaunchGeneric'], { app: name });
      return;
    }
    if (special) {
      if (this.goToApp) this.goToApp(app);
      this.engine.request(special, true);
      this.speak([personalized.appKey(id), special], { app: name });
      return;
    }
    if (!category) { this.handleUncategorizedApp(app); return; }
    const [states, key] = CATEGORY_REACTIONS[category];
    this.play(states, [personalized.appKey(id), key], { app: name });
  }

  /** Returning to an already-seen app gets a "back again?" line, three times, then silence. */
  handleRefocus(app) {
    const count = (this.refocusCount.get(app.id) || 0) + 1;
    this.refocusCount.set(app.id, count);
    const keys = Key.refocus(count);
    if (count > MAX_REFOCUS_LINES || !keys) return;
    // Escalating: mildly amused, then pointed, then done with it.
    const states = count === 1 ? ['watched', 'smug', 'presenting']
      : count === 2 ? ['grumpEyes', 'huffy', 'annoyed']
        : ['dreading', 'guilty', 'stressed'];
    this.play(states, [personalized.appKey(app.id), ...keys], { app: app.name });
  }

  /** A stable label for an app, used as the FROM/TO key in transition lookups. */
  focusTag(app) {
    return specialState(app.id, app.name) || app.category || 'other';
  }

  // ------------------------------------------------ battery / network / clock
  handleBatteryLevel(percent, isCharging) {
    const keys = isCharging ? Key.charge(percent) : Key.battery(percent);
    const states = isCharging ? BATTERY_CHARGING : BATTERY_DRAINING;
    // Low battery matters enough to say regardless of how quiet Bill is set to be.
    this.play(states, keys, { pct: String(percent) }, !isCharging && percent <= 20 ? 'always' : 'normal');
  }

  handleNetworkQuality(quality) {
    if (quality === 'poor') this.play(NETWORK_DOWN, ['network.slow'], {}, 'always');
    else if (quality === 'excellent' || quality === 'good') this.play(NETWORK_UP, ['network.fast']);
    // 'offline' is already covered by networkLost.
  }

  handleHalfHour(hour, minute) {
    // The user asked to be told the time every half hour, so this is never gated.
    this.play(CLOCK, Key.clock(hour, minute), {}, 'always');
  }

  handleUserReturned() {
    if (this.idleStartedAt) {
      this.memory.data.cumulativeIdleSeconds += (Date.now() - this.idleStartedAt) / 1000;
      this.memory.save();
    }
    this.idleStartedAt = null;
    const wasAsleep = this.engine.stateMachine.currentState === 'sleeping';
    this.engine.request('idle');
    this.speak([wasAsleep ? 'waking' : 'userReturned']);
  }

  /** An observation about what is on screen, from the awareness monitor. */
  reportInsight(insight, app) {
    const subs = { ...insight.substitutions };
    const name = (app && app.name) || this.frontmostName;
    if (name) subs.app = name;
    this.play(INSIGHT, [insight.key], subs);
  }

  /** Study Mode's announcements are always spoken — the user turned it on deliberately. */
  announceStudy(keys, states, substitutions = {}) {
    this.play(states, keys, substitutions, 'always');
  }

  /** "You haven't done any homework / learning / anything fun today." */
  nag(key) { this.play(NAG, [key], {}, 'always'); }

  // ----------------------------------------------------- uncategorized apps
  handleUncategorizedApp({ id, name }) {
    const description = this.memory.description(id) || personalized.description(id);
    if (description) {
      this.speak(['appLaunchDescribed'], { app: name, description });
      if (this.memory.openCount(id) >= UNCATEGORIZED_FREQUENT_THRESHOLD) this.engine.request('smug', true);
      return;
    }
    if (this.memory.isFirstSighting(id)) {
      this.engine.stateMachine.playIdleVariant('curious');
      this.speak(['appLaunchFirstSighting'], { app: name });
      return;
    }
    if (this.memory.openCount(id) >= UNCATEGORIZED_FREQUENT_THRESHOLD) {
      this.play(['smug', 'watched', 'grumpEyes'], ['appLaunchStillUnknown'], { app: name });
      return;
    }
    this.speak(['appLaunchGeneric'], { app: name });
  }

  // ---------------------------------------------------------------- helpers
  /**
   * Requests one of `states` (never the one that just played) and speaks the
   * first authored line among `keys`. A per-trigger override from Settings
   * wins over the pool entirely.
   */
  play(states, keys, substitutions = {}, importance = 'normal') {
    const map = this.prefs.get('customAnimationMap');
    const override = keys.map((k) => map[k]).find((s) => s && ALL_STATES.includes(s));
    if (override) this.engine.request(override, true);
    else {
      const state = this.engine.coverage.pick(states);
      if (state) this.engine.request(state, true);
    }
    this.speak(keys, substitutions, importance);
  }

  speak(keys, substitutions = {}, importance = 'normal') {
    const line = library.firstLine(keys, substitutions);
    if (line) this.engine.bark(line, importance);
  }
}

module.exports = { ReactionRouter };
