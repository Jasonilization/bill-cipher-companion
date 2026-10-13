// Bill Cipher — Desktop Companion, for Windows and Linux.
//
// This is the port of App/AppDelegate.swift plus the wiring half of
// UI/CharacterWindow/CharacterWindowController.swift: it builds every part of
// Bill and connects them. The parts themselves live under src/.
const fs = require('fs');
const os = require('os');
const path = require('path');
const { app, dialog, globalShortcut, powerMonitor, screen } = require('electron');

const isLinux = process.platform === 'linux';
const isWindows = process.platform === 'win32';
const env = process.env;
const flag = (name) => env[name] === '1';

// ------------------------------------------------------------- early set-up
// Bill needs to place his own windows anywhere on screen, keep them above
// everything, and see where other apps' windows are. Wayland allows none of
// that by design, so on a Wayland session he runs through XWayland instead.
function needsX11Relaunch() {
  if (!isLinux || !env.DISPLAY) return false;
  if (process.argv.some((arg) => arg.startsWith('--ozone-platform'))) return false;
  return env.XDG_SESSION_TYPE === 'wayland' || !!env.WAYLAND_DISPLAY;
}

if (needsX11Relaunch()) {
  app.relaunch({
    execPath: env.APPIMAGE || process.execPath,
    args: [...process.argv.slice(1), '--ozone-platform=x11'],
  });
  app.exit(0);
  return;
}

if (env.BILL_USER_DATA) app.setPath('userData', path.resolve(env.BILL_USER_DATA));

if (!app.requestSingleInstanceLock()) {
  app.quit();
  return;
}

// Windows stops painting a window it believes is covered. Bill is a small
// always-on-top overlay; he must keep animating regardless.
if (isWindows) app.commandLine.appendSwitch('disable-features', 'CalculateNativeWinOcclusion');
if (isLinux) app.commandLine.appendSwitch('enable-transparent-visuals');
if (isWindows) app.setAppUserModelId('com.billcipher.companion');

const assetsRoot = app.isPackaged
  ? path.join(process.resourcesPath, 'assets')
  : path.join(__dirname, '..', 'Sources', 'Bill', 'Resources');
const spritesDir = path.join(assetsRoot, 'Sprites');
const dialogueFile = path.join(assetsRoot, 'Dialogue', 'dialogue.json');
const iconPath = path.join(__dirname, 'build', 'icon.png');
const dataDir = path.join(app.getPath('userData'), 'data');

const stores = require('./src/core/stores');
stores.setDataDir(dataDir);

// A desktop pet that dies with an error dialog is worse than one that logs
// the problem and carries on.
const logFile = path.join(dataDir, 'bill.log');
function logError(label, error) {
  const text = `[${new Date().toISOString()}] ${label}: ${error && error.stack ? error.stack : error}\n`;
  process.stderr.write(text);
  try {
    if (fs.existsSync(logFile) && fs.statSync(logFile).size > 512 * 1024) fs.renameSync(logFile, `${logFile}.old`);
    fs.appendFileSync(logFile, text);
  } catch { /* logging must never be the thing that fails */ }
}
process.on('uncaughtException', (error) => logError('uncaught exception', error));
process.on('unhandledRejection', (error) => logError('unhandled rejection', error));

// The Settings "Test Triggers" buttons: what the reaction router would pick
// for each trigger (AppDelegate.testTriggerAnimations).
const TEST_TRIGGER_ANIMATIONS = {
  batteryLow: ['stressed', 'dreading', 'huffy', 'grumpEyes', 'watched', 'annoyed'],
  networkLost: ['confused', 'glitchForm', 'spooked', 'dazed', 'glitching', 'ambushed'],
  networkRestored: ['celebrating', 'happy', 'charged', 'zipAround', 'fractaling'],
  'volume.100': ['dancing', 'grooving', 'happy', 'flinching', 'surprised', 'caneFlourish'],
  'volume.mute': ['dancing', 'grooving', 'happy', 'flinching', 'surprised', 'caneFlourish'],
  poked: ['poked', 'surprised', 'flinching', 'dazed'],
  chatFailed: ['confused', 'spooked', 'glitchForm'],
  stillThinking: ['thinking', 'focused'],
  'incognito.search': ['rampaging'],
  'deal.offer': ['caneFlourish', 'smug'],
  'cipher.message': ['scanning'],
  userReturned: ['watched', 'smug', 'presenting'],
  'clock.morning': ['presenting', 'dispatching', 'watched', 'smug', 'zodiacVision'],
  'clock.night': ['presenting', 'dispatching', 'watched', 'smug', 'zodiacVision'],
};

const HOTKEY_FALLBACKS = ['Control+Alt+B', 'Control+Shift+Alt+B'];
const SOLVE_HOTKEY_FALLBACKS = ['Control+Shift+Alt+S', 'Control+Alt+Q'];
const BRAWL_HOTKEY_FALLBACKS = ['Control+Shift+Alt+F', 'Control+Alt+K'];
const POKE_MEMORY = 25 * 1000;
const SETTINGS_DROP_BY_COOLDOWN = 60 * 1000;
const HARD_LANDING_HEIGHT = 260;

let bill = null; // everything, once built
let isQuitting = false;

app.on('second-instance', () => { if (bill) bill.panels.showSettings(); });
// Closing Settings (or any other panel) is not quitting: Bill himself stays.
app.on('window-all-closed', () => {});
app.on('will-quit', () => globalShortcut.unregisterAll());
app.on('before-quit', () => shutDown());
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => app.quit());

function shutDown() {
  if (isQuitting) return;
  isQuitting = true;
  if (bill) {
    const safely = (fn) => { try { fn(); } catch (e) { logError('shutdown', e); } };
    for (const timer of bill.timers) { clearTimeout(timer); clearInterval(timer); }
    safely(() => bill.brawl.dispose());
    safely(() => bill.screenPlay.stop());
    safely(() => bill.snip.dispose());
    safely(() => bill.platform.disposeReader());
    safely(() => bill.conversation.stop());
    safely(() => bill.roaming.stop());
    safely(() => bill.monitor.stop());
    safely(() => bill.weather.stop());
    safely(() => bill.awareness.stop());
    safely(() => bill.engine.stop());
    safely(() => bill.menu.dispose());
    safely(() => bill.panels.dispose());
    safely(() => bill.chatBridge.dispose());
    safely(() => bill.chatBubble.dispose());
    safely(() => bill.barkWindow.dispose());
    safely(() => bill.window.dispose());
  }
  try { stores.flushAll(); } catch (e) { logError('flush', e); }
}

app.whenReady().then(() => {
  // On X11 a transparent window created the instant the app is ready can come
  // up opaque; the compositor needs a moment to hand out an ARGB visual.
  if (isLinux) setTimeout(start, 300); else start();
}).catch((error) => { logError('launch', error); app.exit(1); });

function start() {
  try {
    bill = build();
  } catch (error) {
    logError('launch', error);
    dialog.showErrorBox('Bill could not start', String(error && error.stack ? error.stack : error));
    app.exit(1);
  }
}

function build() {
  const { prefs, memory, coverage, personalized, refreshLog } = stores;
  const { library } = require('./src/core/dialogue');
  const { ALL_STATES } = require('./src/core/states');
  const BarkLines = require('./src/core/barklines');
  const platform = require('./src/platform');
  const { CharacterEngine } = require('./src/engine/characterEngine');
  const { ReactionRouter } = require('./src/engine/reactionRouter');
  const { SystemMonitor } = require('./src/engine/monitors');
  const { AwarenessMonitor } = require('./src/engine/awareness');
  const { WeatherMonitor, pull: pullWeather } = require('./src/engine/weather');
  const { HabitNagger } = require('./src/engine/habitNagger');
  const { StudyMode } = require('./src/engine/studyMode');
  const { ChatBridge } = require('./src/engine/chatBridge');
  const { PersonalizationEngine } = require('./src/engine/personalization');
  const { BillWindow } = require('./src/app/billWindow');
  const { BarkWindow } = require('./src/app/barkWindow');
  const { ChatBubble } = require('./src/app/chatBubble');
  const { RoamingController, topology } = require('./src/app/roaming');
  const { Conversation } = require('./src/app/conversation');
  const { Panels } = require('./src/app/panels');
  const { AppMenu } = require('./src/app/menu');
  const { SnipOverlay } = require('./src/app/snipOverlay');
  const { ScreenHelper } = require('./src/app/helper');
  const { ScreenPlay } = require('./src/app/screenPlay');
  const ModeLines = require('./src/core/modeLines');
  const { Brawl } = require('./src/app/brawl');
  const geometry = require('./src/app/geometry');

  // ------------------------------------------------------------------ state
  prefs.load();
  memory.load();
  coverage.load();
  personalized.load();
  refreshLog.load();
  library.load(dialogueFile);
  library.setGenerated(memory.generatedPools);
  personalized.publish();

  const isDiagnosticRun = flag('BILL_SELFTEST') || flag('BILL_CHAT_DIAGNOSTIC') || flag('BILL_BARK_DIAGNOSTIC')
    || flag('BILL_WEATHER_DIAGNOSTIC') || flag('BILL_AWARENESS_DIAGNOSTIC');

  // ------------------------------------------------------------------ parts
  const engine = new CharacterEngine();
  const window = new BillWindow({ stateMachine: engine.stateMachine, prefs, spritesDir });
  const barkWindow = new BarkWindow({ prefs });
  const chatBubble = new ChatBubble({ prefs });
  const chatBridge = new ChatBridge();
  const weather = new WeatherMonitor(prefs);
  const personalization = new PersonalizationEngine(memory);
  const roaming = new RoamingController({ bill: window, characterEngine: engine, prefs });
  const router = new ReactionRouter({ characterEngine: engine, prefs, memory });
  const monitor = new SystemMonitor();
  const awareness = new AwarenessMonitor(prefs);
  const nagger = new HabitNagger(memory);
  const studyMode = new StudyMode(prefs);
  const conversation = new Conversation({ engine, chatBridge, chatBubble, bill: window, roaming, prefs, weather, personalization });
  const snip = new SnipOverlay();
  const helper = new ScreenHelper({ engine, conversation, snip, prefs, bill: window, barkWindow, monitor });
  // A diagnostic run must never touch the user's windows or pointer.
  const screenPlay = new ScreenPlay({ engine, roaming, bill: window, prefs, monitor, chatBubble, studyMode, helper, snip, enabled: !isDiagnosticRun });
  const brawl = new Brawl({ engine, bill: window, prefs, spritesDir });
  const timers = [];
  const later = (ms, fn) => { const t = setTimeout(fn, ms); timers.push(t); return t; };

  /** Plays the animation the user assigned to a trigger, or one from the usual pool. */
  const playFor = (key, states) => {
    const assigned = prefs.get('customAnimationMap')[key];
    const state = assigned && ALL_STATES.includes(assigned) ? assigned : coverage.pick(states);
    if (state) engine.request(state, true);
  };

  // -------------------------------------------------------- windows + barks
  window.create();
  barkWindow.create();
  chatBubble.create();

  engine.stateMachine.on('bark', (text) => barkWindow.show(text, window.bodyRect(), window.screen()));
  engine.stateMachine.on('barkFadeOut', () => barkWindow.fadeOut());

  let bubbleFollow = null;
  let lastSettingsDropBy = 0;
  const checkSettingsDropBy = () => {
    const frame = panels.settingsFrame();
    if (!frame) return;
    const mine = window.frame;
    const overlaps = frame.x < mine.x + mine.w && mine.x < frame.x + frame.w && frame.y < mine.y + mine.h && mine.y < frame.y + frame.h;
    if (!overlaps || Date.now() - lastSettingsDropBy <= SETTINGS_DROP_BY_COOLDOWN) return;
    lastSettingsDropBy = Date.now();
    engine.request('smug', true);
    const line = library.line('settings.visit');
    if (line) engine.bark(line, 'always');
  };

  window.on('moved', () => {
    barkWindow.reposition(window.bodyRect(), window.screen());
    // The chat bubble is a heavier window: let a burst of movement settle first.
    if (chatBubble.isVisible) {
      clearTimeout(bubbleFollow);
      bubbleFollow = setTimeout(() => conversation.reanchor(), 120);
    }
    checkSettingsDropBy();
  });

  window.on('dragStart', () => {
    roaming.suspend();
    playFor('grabbed', ['surprised']);
    engine.bark(library.line('grabbed') || '');
  });
  window.on('dragEnd', () => {
    playFor('dropped', ['dazed']);
    engine.bark(library.line('dropped') || '');
    roaming.resume();
  });

  // Being clicked escalates: prodding him repeatedly gets a different answer than the first tap.
  let pokeCount = 0;
  let lastPokeAt = 0;
  window.on('poke', () => {
    // "Poke me and I'll read it": a standing offer turns the poke into a yes.
    if (screenPlay.acceptOffer()) return;
    pokeCount += 1;
    if (Date.now() - lastPokeAt > POKE_MEMORY) pokeCount = 1;
    lastPokeAt = Date.now();
    if (pokeCount >= 5) {
      const state = coverage.pick(['meltdown', 'shadowHands', 'grumpEyes', 'tumbling']);
      if (state) engine.request(state, true);
    } else if (pokeCount >= 3) {
      const state = coverage.pick(['annoyed', 'huffy', 'grumpEyes']);
      if (state) engine.request(state, true);
    } else {
      playFor('poked', ['poked', 'surprised', 'flinching', 'dazed']);
    }
    const key = pokeCount >= 5 ? 'poked.furious' : pokeCount >= 3 ? 'poked.annoyed' : 'poked';
    engine.bark(library.line(key) || '', 'always');
  });

  window.on('battery', (state) => monitor.handleBattery(state));
  window.on('contextMenu', () => window.popup(menu.build()));

  // ---------------------------------------------------------------- roaming
  roaming.onEvent = (event) => {
    switch (event.kind) {
      case 'landed':
        screenPlay.landed();
        // Only a genuinely long drop is worth remarking on.
        if (event.hard && event.fromHeight > HARD_LANDING_HEIGHT) engine.bark(BarkLines.random(BarkLines.POOLS.roamHardLanding));
        break;
      case 'grabbedLedge': engine.bark(BarkLines.random(BarkLines.POOLS.roamLedgeGrab)); break;
      case 'fellOffWorld': engine.bark(BarkLines.random(BarkLines.POOLS.roamFellOffWorld)); break;
      case 'shoved': engine.bark(BarkLines.random(BarkLines.POOLS.roamShoved)); break;
      case 'minimizePrankArrived': {
        // The finger-snap-then-gloat clip reads exactly as pressing a button.
        // The window really minimizing right after sells it, and its
        // disappearance drops him through where its top edge used to be.
        engine.request('smug', true);
        const line = library.line('prank.minimize');
        if (line) engine.bark(line, 'always');
        const target = event.window;
        later(550, () => {
          if (target && target.id !== undefined && platform.minimize(target.id)) screenPlay.noteMinimized(target.id);
          roaming.invalidateTopology();
        });
        break;
      }
      default: break;
    }
  };

  // -------------------------------------------------------------- reactions
  router.goToApp = (target) => roaming.goToApp(target);
  router.studyModeInterceptor = (target) => studyMode.intercept(target);
  router.habitNagger = nagger;
  nagger.onNag = (key) => router.nag(key);
  studyMode.goToApp = (target) => roaming.goToApp(target);
  studyMode.announce = (keys, states, substitutions) => router.announceStudy(keys, states, substitutions);
  studyMode.onStateChanged = () => menu.refresh();
  awareness.onInsight = (insight, target) => router.reportInsight(insight, target);
  monitor.onEvent = (event) => router.handle(event);
  monitor.onForegroundChanged = () => roaming.invalidateTopology();
  weather.onReport = (snapshot, reason) => router.handle({ type: 'weatherChanged', snapshot, reason });
  weather.onFetchError = (message) => engine.bark(message, 'always');

  // ------------------------------------------------------------ preferences
  const applySpeaking = () => { engine.speakingFrequencyMultiplier = prefs.get('speakingFrequency'); };
  const applySpacing = () => { engine.ambientAnimationSpacingMultiplier = prefs.get('ambientAnimationSpacing'); };
  applySpeaking(); applySpacing();
  prefs.on('change:speakingFrequency', applySpeaking);
  prefs.on('change:ambientAnimationSpacing', applySpacing);
  for (const key of ['chatBubbleMaxWidth', 'bubbleAccentColorHex', 'bubbleTextScale']) prefs.on(`change:${key}`, () => conversation.relayout());
  prefs.on('change:windowAwareness', () => awareness.refresh());
  prefs.on('change:roaming', (enabled) => { if (enabled) roaming.dropIfUnsupported(); });

  // ------------------------------------------------------------------- mood
  chatBridge.modeNote = () => ModeLines.MODE_NOTES[prefs.get('mode')];
  conversation.onScreenQuestion = (text) => helper.helpWithWindow(null, { question: text });
  prefs.on('change:mode', (mode) => {
    screenPlay.modeChanged();
    engine.request(mode === 'troll' ? 'trickster' : 'presenting', true);
    engine.bark(ModeLines.pick(mode === 'troll' ? 'modeTroll' : 'modeHelpful'), 'always');
    menu.refresh();
  });

  // The switch in Settings reflects what the system will actually do.
  try {
    const actual = !!platform.isLaunchAtLoginEnabled();
    if (actual !== prefs.get('launchAtLogin')) prefs.set('launchAtLogin', actual);
  } catch (e) { logError('launch at login', e); }
  prefs.on('change:launchAtLogin', (enabled) => {
    try { platform.setLaunchAtLogin(enabled); } catch (e) { logError('launch at login', e); }
  });

  // --------------------------------------------------------------- hot key
  const hotkey = { registered: null };
  // Another app may already own the preferred combination (a global hot key
  // can only belong to one), so there are fallbacks; whichever is registered
  // is the one the menu and Settings show.
  const registerHotkey = () => {
    if (hotkey.registered) { globalShortcut.unregister(hotkey.registered); hotkey.registered = null; }
    const wanted = String(prefs.get('hotkey') || '').trim();
    for (const accelerator of [wanted, ...HOTKEY_FALLBACKS]) {
      if (!accelerator) continue;
      try {
        if (!globalShortcut.register(accelerator, () => conversation.talkToBill())) continue;
        hotkey.registered = accelerator;
        break;
      } catch { /* not a valid accelerator: try the next */ }
    }
    if (hotkey.registered !== wanted) console.error(`hot key ${wanted || '(none)'} is unavailable; using ${hotkey.registered || 'none (his menu still works)'}`);
  };
  // "Solve something on screen" has its own key, with fallbacks for the same reason.
  const solveHotkey = { registered: null };
  const registerSolveHotkey = () => {
    if (solveHotkey.registered) { globalShortcut.unregister(solveHotkey.registered); solveHotkey.registered = null; }
    const wanted = String(prefs.get('solveHotkey') || '').trim();
    for (const accelerator of [wanted, ...SOLVE_HOTKEY_FALLBACKS]) {
      if (!accelerator || accelerator === hotkey.registered) continue;
      try {
        if (!globalShortcut.register(accelerator, () => helper.solveRegion())) continue;
        solveHotkey.registered = accelerator;
        break;
      } catch { /* not a valid accelerator: try the next */ }
    }
    if (solveHotkey.registered !== wanted) console.error(`solve hot key ${wanted || '(none)'} is unavailable; using ${solveHotkey.registered || 'none (his menu still works)'}`);
  };
  // The brawl key: spawns fighting copies of him.
  const brawlHotkey = { registered: null };
  const registerBrawlHotkey = () => {
    if (brawlHotkey.registered) { globalShortcut.unregister(brawlHotkey.registered); brawlHotkey.registered = null; }
    const wanted = String(prefs.get('brawlHotkey') || '').trim();
    for (const accelerator of [wanted, ...BRAWL_HOTKEY_FALLBACKS]) {
      if (!accelerator || accelerator === hotkey.registered || accelerator === solveHotkey.registered) continue;
      try {
        if (!globalShortcut.register(accelerator, () => brawl.spawn())) continue;
        brawlHotkey.registered = accelerator;
        break;
      } catch { /* not a valid accelerator: try the next */ }
    }
    if (brawlHotkey.registered !== wanted) console.error(`brawl hot key ${wanted || '(none)'} is unavailable; using ${brawlHotkey.registered || 'none (his menu still works)'}`);
  };
  registerHotkey();
  registerSolveHotkey();
  if (!isDiagnosticRun) registerBrawlHotkey();
  prefs.on('change:hotkey', () => { registerHotkey(); registerSolveHotkey(); menu.refresh(); panels.reloadSettings(); });
  prefs.on('change:solveHotkey', () => { registerSolveHotkey(); menu.refresh(); panels.reloadSettings(); });

  // ------------------------------------------------------- panels and menu
  const testTrigger = (key) => {
    playFor(key, TEST_TRIGGER_ANIMATIONS[key] || []);
    const line = library.firstLine([key]);
    if (line) engine.bark(line, 'always');
  };

  const resetMemory = async (parent) => {
    const options = {
      type: 'warning', title: 'Bill', message: 'Reset Bill\'s memory?',
      detail: 'He forgets which apps you use, how long he has known you, and every line he wrote for himself. Your settings stay.',
      buttons: ['Cancel', 'Reset Memory'], defaultId: 0, cancelId: 0, noLink: true,
    };
    const live = parent && !parent.isDestroyed() ? parent : null;
    const { response } = live ? await dialog.showMessageBox(live, options) : await dialog.showMessageBox(options);
    if (response !== 1) return;
    memory.reset();
    library.setGenerated(memory.generatedPools);
    panels.reloadSettings();
  };

  const panels = new Panels({
    prefs, personalization, iconPath,
    actions: {
      testTrigger,
      testWeather: () => weather.testNow(),
      openFullChat: () => conversation.showFullChat(),
      signOut: () => chatBridge.signOut(),
      resetMemory,
      refreshNow: () => conversation.refreshDialogueNow(),
      startPersonalization: () => conversation.runPersonalizationSetup(),
      activeHotkey: () => hotkey.registered,
      activeSolveHotkey: () => solveHotkey.registered,
      solveRegion: () => helper.solveRegion(),
      helpWithWindow: () => helper.helpWithWindow(),
      undoMischief: () => screenPlay.undoMischief(),
    },
  });

  const describe = (fn) => { try { return fn(); } catch (e) { return `(${e.message})`; } };
  const menu = new AppMenu({
    engine, studyMode, chatBridge, awareness,
    get hotkeyLabel() { return hotkey.registered; },
    get solveHotkeyLabel() { return solveHotkey.registered; },
    get brawlHotkeyLabel() { return brawlHotkey.registered; },
    spawnFighter: () => brawl.spawn(),
    clearBrawl: () => brawl.clear(),
    prefs,
    solveRegion: () => helper.solveRegion(),
    helpWithWindow: () => helper.helpWithWindow(),
    undoMischief: () => screenPlay.undoMischief(),
    talkToBill: () => conversation.talkToBill(),
    toggleFullChat: () => chatBridge.toggle(),
    showFullChat: () => conversation.showFullChat(),
    refreshDialogueNow: () => conversation.refreshDialogueNow(),
    showQuotes: () => panels.showQuotes(),
    showPersonalization: () => panels.showPersonalization(),
    testWeather: () => weather.testNow(),
    showSettings: () => panels.showSettings(),
    showLog: () => panels.showLog(),
    // Settle to idle first: a wander only starts from rest.
    triggerWander: () => { engine.request('idle', true); roaming.triggerNow(); },
    quit: () => app.quit(),
    debugLines: () => {
      const f = window.frame;
      const on = window.screen();
      return [
        `version: ${app.getVersion()} — ${platform.name} backend, ${os.type()} ${os.release()}, Electron ${process.versions.electron}`,
        `window: x=${Math.round(f.x)} y=${Math.round(f.y)} ${f.w}x${f.h}, scale ${window.scale}, dragging=${window.isDragging}`,
        `screen: ${Math.round(on.visible.w)}x${Math.round(on.visible.h)} at ${Math.round(on.visible.x)},${Math.round(on.visible.y)} @${on.scaleFactor}x (${geometry.allScreens().length} display(s))`,
        `sprites: ${window.spritesLoaded ? `${window.spritesLoaded.loaded}/${window.spritesLoaded.expected}` : 'still loading'}`,
        `roaming: enabled=${prefs.get('roaming')} suspended=${roaming.isSuspended} ticking=${roaming.isTicking} step=${roaming.step.kind} goal=${roaming.goal ? roaming.goal.kind : 'none'}`,
        `platforms: ${describe(() => topology.platforms(true).length)} window(s) he can stand on`,
        `foreground: ${describe(() => { const fg = platform.foreground(); return !fg ? 'none' : fg.own ? 'Bill' : `${fg.name || '?'} [${fg.id || '?'}]`; })}`,
        `chat: awaiting=${conversation.isAwaitingChatResponse} background=${conversation.isPerformingBackgroundChatWork} generating=${chatBridge.isGenerating} bubble=${chatBubble.isVisible}`,
        `weather: ${weather.latest ? `${weather.latest.condition} ${Math.round(weather.latest.temperatureC)}°C${weather.latest.city ? ` in ${weather.latest.city}` : ''}` : 'no report yet'}`,
        `study mode: ${studyMode.isActive ? `${Math.ceil(studyMode.remaining / 60000)} min left` : 'off'}`,
        `screen reading: ${describe(() => platform.ocrStatus.detail)}; for solving: ${describe(() => platform.readerDetail)}`,
        `hot key: ${hotkey.registered || 'not registered'}; solve: ${solveHotkey.registered || 'not registered'}`,
        `mode: ${prefs.get('mode')}, screen play ${screenPlay.enabled ? 'live' : 'disabled for this run'}`,
        `data: ${dataDir}`,
      ];
    },
  });
  menu.createTray(iconPath);

  // ----------------------------------------------------------------- launch
  conversation.wirePersonalization();
  conversation.start();
  engine.start();
  monitor.start();
  // The self-test stays off the network.
  if (!flag('BILL_SELFTEST')) weather.start();
  awareness.refresh();
  roaming.start();
  screenPlay.start();

  // The multicolour prism beat as the opening flourish: a brief welcome
  // light-show that says "I'm here and I'm fabulous".
  later(3000, () => engine.request('prismDance', true));

  // If his window ever goes away, so does he: there is nothing left to see.
  window.window.on('closed', () => { if (!isQuitting) app.quit(); });

  // Displays come, go and change size; he stays on one of them, standing on something.
  const onDisplaysChanged = () => {
    window.clampToScreen();
    roaming.invalidateTopology();
    roaming.dropIfUnsupported();
    conversation.relayout();
  };
  let displayDebounce = null;
  const displaysChanged = () => { clearTimeout(displayDebounce); displayDebounce = setTimeout(onDisplaysChanged, 250); };
  screen.on('display-added', displaysChanged);
  screen.on('display-removed', displaysChanged);
  screen.on('display-metrics-changed', displaysChanged);
  powerMonitor.on('resume', displaysChanged);

  // Offered once, automatically; re-runnable any time from the menu.
  if (!isDiagnosticRun && !personalized.isPersonalized && !prefs.get('didOfferPersonalizationSetup')) {
    prefs.set('didOfferPersonalizationSetup', true);
    later(15000, () => panels.showPersonalization());
  }

  const built = {
    engine, window, barkWindow, chatBubble, chatBridge, weather, personalization, roaming, router, monitor,
    awareness, nagger, studyMode, conversation, panels, menu, timers, prefs, platform, topology, dataDir,
    snip, helper, screenPlay, brawl,
  };
  runDiagnostics(built, { later, pullWeather, library });
  return built;
}

// ------------------------------------------------------------- diagnostics
// The same launch-time probes the Mac app has, driven by environment
// variables, so a build can be checked from a terminal.
function runDiagnostics(b, { later, pullWeather, library }) {
  const { engine } = b;

  if (flag('BILL_SELFTEST')) {
    require('./src/app/selftest').run(b).catch((error) => { logError('self-test', error); app.exit(1); });
  }

  // Loads the chat page and reports what it finds. Sends nothing.
  if (flag('BILL_CHAT_DIAGNOSTIC')) {
    b.chatBridge.prepareIfNeeded();
    later(12000, async () => {
      const report = await b.chatBridge.diagnose();
      console.log(`=== chat bridge diagnostic ===\n${report}\n=== end chat diagnostic ===`);
    });
  }

  // Proves the bubble sits by him, wraps, and flips sides at a screen edge.
  if (flag('BILL_BARK_DIAGNOSTIC')) {
    later(6000, () => {
      engine.bark('AH, A TEST SUBJECT. WATCH CLOSELY: THIS BUBBLE SITS RIGHT ABOVE MY HAT, WRAPS ITS TEXT PROPERLY, AND ITS TAIL IS PART OF THE BORDER.', 'always');
    });
    later(13000, () => {
      b.roaming.suspend();
      b.window.parkNearRightEdge();
    });
    later(14000, () => {
      engine.bark('NOW I\'M AT THE SCREEN\'S EDGE. NOTICE: THE BUBBLE SHIFTED LEFT, AND MY TAIL FOLLOWED ME. DIRECTIONAL. GEOMETRY IS A LIFESTYLE.', 'always');
    });
  }

  // Proves the whole weather pipeline: location → forecast → condition → dialogue → bubble.
  if (flag('BILL_WEATHER_DIAGNOSTIC')) {
    later(4000, async () => {
      console.log('=== WEATHER DIAGNOSTIC: pulling ===');
      const snapshot = await pullWeather();
      if (!snapshot) {
        console.log('=== WEATHER DIAGNOSTIC: PULL FAILED ===');
        engine.bark('THE WEATHER PULL FAILED. CHECK YOUR CONNECTION.', 'always');
        return;
      }
      const temp = Math.round(snapshot.temperatureC);
      console.log(`=== WEATHER DIAGNOSTIC: ${snapshot.condition} ${temp}°C in ${snapshot.city || '?'} ===`);
      const key = `weather.${snapshot.condition}`;
      console.log(`=== WEATHER DIAGNOSTIC: looking up dialogue pool '${key}' ===`);
      const line = library.firstLine([key]);
      if (line) {
        console.log(`=== WEATHER DIAGNOSTIC: barking '${line}' ===`);
        engine.bark(line, 'always');
      } else {
        console.log(`=== WEATHER DIAGNOSTIC: no line for '${key}' ===`);
        engine.bark(`IT'S ${temp} DEGREES AND ${String(snapshot.condition).toUpperCase()} OUT THERE. I'D SAY SOMETHING WITTY BUT MY SCRIPT WRITER IS ASLEEP.`, 'always');
      }
    });
  }

  if (flag('BILL_AWARENESS_DIAGNOSTIC')) {
    later(6000, async () => {
      const report = await b.awareness.diagnose();
      console.log(`=== screen awareness diagnostic ===\n${report}\n=== end diagnostic ===`);
    });
  }
}
