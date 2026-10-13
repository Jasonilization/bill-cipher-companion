// Bill's ordinary windows: Settings, the Quotes Manager, the personalization
// setup and the dialogue refresh log (ports of UI/Settings, UI/QuotesManager,
// UI/Personalization and the refresh-log window).
const { app, BrowserWindow, ipcMain, shell, nativeImage } = require('electron');
const platform = require('../platform');
const geometry = require('./geometry');
const { rendererFile, localWebPreferences, lockDown } = require('./windows');
const { ALL_STATES } = require('../core/states');
const { library } = require('../core/dialogue');
const { memory, refreshLog, PREF_DEFAULTS } = require('../core/stores');
const { makeBubble } = require('../core/bubble');

const ANIMATION_TRIGGERS = [
  ['batteryLow', 'Low battery'], ['batteryCharging', 'Plugged in'], ['cpuHot', 'Computer runs hot'],
  ['networkLost', 'Network drops'], ['networkRestored', 'Network returns'], ['volume.100', 'Volume maxed'],
  ['volume.mute', 'Volume muted'], ['userReturned', 'You come back'], ['grabbed', 'Bill gets grabbed'],
  ['dropped', 'Bill gets dropped'], ['poked', 'Bill gets poked'], ['coding', 'Coding'], ['gaming', 'Games'],
  ['browsing', 'Browsing'], ['music', 'Music'], ['creative', 'Creative'], ['finder', 'File manager'],
  ['communication', 'Chat & mail'], ['productivity', 'Work'], ['aiChat', 'Other AI'],
];

const TEST_TRIGGERS = [
  ['batteryLow', 'Low Battery'], ['networkLost', 'Wi-Fi Drops'], ['networkRestored', 'Wi-Fi Back'],
  ['volume.100', 'Volume Up'], ['volume.mute', 'Volume Mute'], ['poked', 'Poke'], ['chatFailed', 'Chat Error'],
  ['stillThinking', 'Thinking'], ['incognito.search', 'Incognito'], ['deal.offer', 'Deal Offer'],
  ['cipher.message', 'Cipher'], ['userReturned', 'User Returns'], ['clock.morning', 'Morning'],
  ['clock.night', 'Night'], ['weather.rain', 'Rain'], ['weather.clear', 'Clear Sky'],
];

const SPECS = {
  settings: { file: 'settings.html', title: 'Bill', width: 780, height: 580, minWidth: 600, minHeight: 500, resizable: true },
  quotes: { file: 'quotes.html', title: 'Bill — Quotes Manager', width: 760, height: 520, minWidth: 560, minHeight: 360, resizable: true },
  personalize: { file: 'personalize.html', title: 'Bill Wants to Study Your Apps', width: 440, height: 520, resizable: false },
  log: { file: 'log.html', title: 'Bill — Dialogue Refresh Log', width: 720, height: 560, minWidth: 480, minHeight: 320, resizable: true },
};

const time = (ms) => new Date(ms).toLocaleTimeString([], { hour12: false });

/** One line per recent refresh, for the strip along the bottom of the Quotes Manager. */
function recentRefreshLines() {
  return refreshLog.entries.slice(-3).reverse().map((entry) => {
    const head = `${time(entry.startedAt)} · ${entry.trigger}`;
    if (entry.failureReason) return `${head} · FAILED: ${entry.failureReason}`;
    if (entry.status === 'running') return `${head} · in flight…`;
    if (entry.linesAdded && entry.linesAdded.length) return `${head} · OK — ${entry.linesAdded[0]}`;
    if (entry.descriptions && entry.descriptions.length) return `${head} · OK — ${entry.descriptions.length} app descriptions`;
    return `${head} · nothing landed`;
  });
}

class Panels {
  /** `actions`: testTrigger(key), testWeather(), openFullChat(), signOut(), resetMemory(), refreshNow(), startPersonalization(). */
  constructor({ prefs, personalization, actions, iconPath }) {
    this.prefs = prefs;
    this.personalization = personalization;
    this.actions = actions;
    this.icon = iconPath ? nativeImage.createFromPath(iconPath) : null;
    this.windows = {};
    this.register();
  }

  open(name) {
    const existing = this.windows[name];
    if (existing && !existing.isDestroyed()) {
      if (existing.isMinimized()) existing.restore();
      existing.show(); existing.focus();
      return existing;
    }
    const spec = SPECS[name];
    const win = new BrowserWindow({
      width: spec.width, height: spec.height, minWidth: spec.minWidth, minHeight: spec.minHeight,
      resizable: spec.resizable, maximizable: spec.resizable, fullscreenable: false,
      title: spec.title, show: false, autoHideMenuBar: true,
      icon: this.icon && !this.icon.isEmpty() ? this.icon : undefined,
      webPreferences: localWebPreferences(),
    });
    lockDown(win);
    win.once('ready-to-show', () => win.show());
    win.on('closed', () => { if (this.windows[name] === win) delete this.windows[name]; });
    win.loadFile(rendererFile(spec.file));
    this.windows[name] = win;
    return win;
  }

  send(name, channel, payload) {
    const win = this.windows[name];
    if (win && !win.isDestroyed()) win.webContents.send(channel, payload);
  }

  showSettings() { this.open('settings'); }
  showQuotes() { this.open('quotes'); }
  showLog() { this.open('log'); }
  showPersonalization() {
    this.open('personalize');
    // The list of apps he can see, ready before the first click.
    this.personalization.previewDetectedApps();
  }

  /** Where the Settings window is, in Y-up space — Bill notices when he is dragged over it. */
  settingsFrame() {
    const win = this.windows.settings;
    if (!win || win.isDestroyed() || !win.isVisible() || win.isMinimized()) return null;
    return geometry.toUp(win.getBounds());
  }

  settingsState() {
    return {
      prefs: this.prefs.all(),
      version: app.getVersion(),
      platformName: process.platform === 'win32' ? 'Windows' : process.platform === 'linux' ? 'Linux' : process.platform,
      daysKnown: memory.daysKnown,
      states: ALL_STATES,
      apps: memory.knownApps().slice(0, 20),
      ocr: platform.ocrStatus,
      animationTriggers: ANIMATION_TRIGGERS,
      testTriggers: TEST_TRIGGERS,
      activeHotkey: this.actions.activeHotkey ? this.actions.activeHotkey() : null,
      activeSolveHotkey: this.actions.activeSolveHotkey ? this.actions.activeSolveHotkey() : null,
      canMoveCursor: platform.canMoveCursor(),
      canReadScreen: platform.canReadScreen,
    };
  }

  register() {
    const ours = (event) => Object.values(this.windows).some((w) => !w.isDestroyed() && w.webContents === event.sender);
    const handle = (channel, handler) => ipcMain.handle(channel, (event, ...args) => (ours(event) ? handler(...args) : null));
    const on = (channel, handler) => ipcMain.on(channel, (event, ...args) => { if (ours(event)) handler(...args); });

    // ---------------------------------------------------------------- settings
    handle('settings:state', () => this.settingsState());
    handle('settings:bubblePreview', (textScale) => {
      const bubble = makeBubble({ text: 'HELLO, PINE TREE.', tailEdge: 'above', textScale: Math.min(2.4, Math.max(0.6, Number(textScale) || 1)) });
      return { w: bubble.w, h: bubble.h, scale: bubble.scale, cells: bubble.cells };
    });
    on('settings:set', (key, value) => {
      if (!(key in PREF_DEFAULTS) || typeof value !== typeof PREF_DEFAULTS[key]) return;
      this.prefs.set(key, value);
    });
    on('settings:action', (name, arg) => {
      if (name === 'testTrigger') this.actions.testTrigger(String(arg));
      else if (name === 'testWeather') this.actions.testWeather();
      else if (name === 'openQuotes') this.showQuotes();
      else if (name === 'solveRegion') this.actions.solveRegion();
      else if (name === 'helpWithWindow') this.actions.helpWithWindow();
      else if (name === 'undoMischief') this.actions.undoMischief();
      else if (name === 'openChat') this.actions.openFullChat();
      else if (name === 'signOut') this.actions.signOut();
      else if (name === 'resetMemory') this.actions.resetMemory(this.windows.settings);
      else if (name === 'openLink' && /^https:\/\//.test(String(arg))) shell.openExternal(String(arg));
    });
    this.prefs.on('change', () => this.send('settings:prefs', this.prefs.all()));

    // ------------------------------------------------------------------ quotes
    handle('quotes:state', () => ({
      pools: library.allKeys().map((key) => {
        const counts = library.sourceCounts(key);
        return { key, ...counts, total: counts.authored + counts.generated + counts.personalized };
      }),
      totalLines: library.totalLines(),
      recent: recentRefreshLines(),
    }));
    handle('quotes:detail', (key) => library.poolDetail(String(key)));
    on('quotes:refresh', () => this.actions.refreshNow());
    on('quotes:showLog', () => this.showLog());

    // --------------------------------------------------------------------- log
    handle('log:state', () => refreshLog.entries);
    on('log:clear', () => refreshLog.clear());
    refreshLog.on('change', () => { this.send('log', 'log:update'); this.send('quotes', 'quotes:update'); });

    // --------------------------------------------------------- personalization
    handle('personalize:state', () => ({
      model: this.personalization.model,
      machine: process.platform === 'win32' ? 'PC' : 'computer',
    }));
    on('personalize:action', (name) => {
      if (name === 'start') this.actions.startPersonalization();
      else if (name === 'login') this.actions.openFullChat();
      else if (name === 'done') { const win = this.windows.personalize; if (win && !win.isDestroyed()) win.close(); }
    });
    this.personalization.on('change', (model) => this.send('personalize', 'personalize:model', model));
  }

  reloadSettings() { this.send('settings', 'settings:reload'); }

  dispose() {
    for (const win of Object.values(this.windows)) if (!win.isDestroyed()) win.destroy();
    this.windows = {};
  }
}

module.exports = { Panels, TEST_TRIGGERS, ANIMATION_TRIGGERS };
