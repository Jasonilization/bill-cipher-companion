// Port of UI/MenuBar/StatusItemController.swift: the tray icon and its menu,
// which is also what right-clicking Bill opens.
const { Menu, Tray, nativeImage, dialog, clipboard } = require('electron');
const { ALL_STATES } = require('../core/states');
const BarkLines = require('../core/barklines');

const capitalized = (s) => s.charAt(0).toUpperCase() + s.slice(1);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** The tray wants a small icon at every display scale, not one big one shrunk on the fly. */
function trayImage(iconPath) {
  const base = nativeImage.createFromPath(iconPath);
  if (base.isEmpty()) return base;
  const size = process.platform === 'win32' ? 16 : 22;
  const image = nativeImage.createEmpty();
  for (const scaleFactor of [1, 1.25, 1.5, 2, 3]) {
    const px = Math.round(size * scaleFactor);
    image.addRepresentation({ scaleFactor, width: px, height: px, buffer: base.resize({ width: px, height: px, quality: 'best' }).toPNG() });
  }
  return image;
}

class AppMenu {
  /**
   * `app` supplies everything the menu can do: talkToBill, showFullChat,
   * refreshDialogueNow, showQuotes, showPersonalization, testWeather,
   * showSettings, showLog, triggerWander, quit, plus the engine, studyMode,
   * chatBridge and awareness objects.
   */
  constructor(app) {
    this.app = app;
    this.tray = null;
    this.minuteTimer = null;
  }

  createTray(iconPath) {
    try {
      this.tray = new Tray(trayImage(iconPath));
      this.tray.setToolTip('Bill');
      this.tray.on('click', () => this.tray.popUpContextMenu());
      this.refresh();
    } catch (e) {
      // Some Linux desktops have no tray at all. Right-clicking Bill opens the same menu.
      console.error('tray unavailable:', e.message);
      this.tray = null;
    }
    // The label counts the session down, and a tray menu is a snapshot.
    this.minuteTimer = setInterval(() => { if (this.app.studyMode.isActive) this.refresh(); }, 30 * 1000);
  }

  refresh() {
    if (this.tray && !this.tray.isDestroyed()) this.tray.setContextMenu(this.build(false));
  }

  studyItem() {
    const study = this.app.studyMode;
    if (!study.isActive) return { label: 'Study Mode (30 min)', type: 'checkbox', checked: false, click: () => this.toggleStudyMode() };
    const minutes = Math.ceil(study.remaining / 60000);
    return { label: `Study Mode — ${minutes} min left`, type: 'checkbox', checked: true, click: () => this.toggleStudyMode() };
  }

  /** `forBill` is the right-click menu on Bill himself; it is the same menu. */
  build() {
    const a = this.app;
    const mode = a.prefs.get('mode');
    return Menu.buildFromTemplate([
      { label: 'Talk to Bill', accelerator: a.hotkeyLabel || undefined, registerAccelerator: false, click: () => a.talkToBill() },
      { label: 'Solve Something On Screen…', accelerator: a.solveHotkeyLabel || undefined, registerAccelerator: false, click: () => a.solveRegion() },
      { label: 'Help With This Window', click: () => a.helpWithWindow() },
      { label: 'Mode', submenu: [
        { label: 'Troll: pranks your windows and cursor', type: 'radio', checked: mode === 'troll', click: () => a.prefs.set('mode', 'troll') },
        { label: 'Helpful: no pranks, offers to fix things', type: 'radio', checked: mode === 'helpful', click: () => a.prefs.set('mode', 'helpful') },
      ] },
      { label: 'Undo Bill\'s Mischief', click: () => a.undoMischief() },
      { label: 'Spawn a Fighting Bill', accelerator: a.brawlHotkeyLabel || undefined, registerAccelerator: false, click: () => a.spawnFighter() },
      { label: 'Clear the Brawl', click: () => a.clearBrawl() },
      { type: 'separator' },
      { label: 'Open Full Chat View…', click: () => a.toggleFullChat() },
      { label: 'Refresh Bill\'s Context Now', click: () => a.refreshDialogueNow() },
      { label: 'Quotes Manager…', click: () => a.showQuotes() },
      { label: 'Personalize Bill\'s Commentary…', click: () => a.showPersonalization() },
      { type: 'separator' },
      { label: 'Test Weather Now', click: () => a.testWeather() },
      { type: 'separator' },
      this.studyItem(),
      { type: 'separator' },
      { label: 'Settings…', click: () => a.showSettings() },
      { type: 'separator' },
      { label: 'Debug: Force State', submenu: ALL_STATES.map((state) => ({ label: capitalized(state), click: () => a.engine.request(state, true) })) },
      { label: 'Debug: Dump State', click: () => this.dumpState() },
      { label: 'Debug: Test Bark', click: () => a.engine.bark(BarkLines.random(BarkLines.POOLS.coding)) },
      { label: 'Debug: Trigger Wander Now', click: () => a.triggerWander() },
      { label: 'Debug: Test Chat Connection', click: () => this.testChat() },
      { label: 'Debug: Test Screen Awareness Now', click: () => this.testAwareness() },
      { label: 'Debug: Show Dialogue Refresh Log', click: () => a.showLog() },
      { type: 'separator' },
      { label: 'Quit Bill', click: () => a.quit() },
    ]);
  }

  async report(title, detail, firstButton = 'OK') {
    const { response } = await dialog.showMessageBox({ type: 'info', title: 'Bill', message: title, detail, buttons: [firstButton, 'Copy'], defaultId: 0, cancelId: 0, noLink: true });
    if (response === 1) clipboard.writeText(detail);
    return response;
  }

  dumpState() {
    const dump = [
      this.app.engine.stateMachine.debugDump(),
      ...this.app.debugLines(),
    ].join('\n');
    console.log(`=== Bill debug dump ===\n${dump}`);
    this.report('Bill debug dump', dump);
  }

  async testChat() {
    const raw = await this.app.chatBridge.diagnose();
    let pretty = raw; let signedOut = false;
    try {
      const d = JSON.parse(raw);
      signedOut = d.looksLoggedOut === true || d.hasComposer === false;
      pretty = Object.keys(d).sort().map((key) => `${key}: ${d[key]}`).join('\n');
    } catch { /* not JSON: show it as it came */ }
    console.log(`=== chat bridge diagnostic ===\n${pretty}`);
    const response = await this.report(
      signedOut ? 'Bill is not signed in to ChatGPT' : 'Chat connection looks healthy',
      (signedOut ? 'Bill\'s chat view has its own cookies, separate from your browser — so signing in there doesn\'t sign him in. Open the full chat view and log in once.\n\n' : '') + pretty,
      signedOut ? 'Open Chat to Sign In' : 'OK',
    );
    if (response === 0 && signedOut) this.app.showFullChat();
  }

  async testAwareness() {
    const { response } = await dialog.showMessageBox({
      type: 'question', title: 'Bill', message: 'Test screen awareness',
      detail: 'Click Start, then bring the app you want to test to the front. Bill will look at it in 4 seconds.',
      buttons: ['Start', 'Cancel'], defaultId: 0, cancelId: 1, noLink: true,
    });
    if (response !== 0) return;
    await sleep(4000);
    const report = await this.app.awareness.diagnose();
    console.log(`=== screen awareness diagnostic ===\n${report}`);
    this.report('Screen awareness diagnostic', report);
  }

  async toggleStudyMode() {
    const study = this.app.studyMode;
    if (!study.isActive) { study.start(); this.refresh(); return; }
    const minutes = Math.ceil(study.remaining / 60000);
    const { response } = await dialog.showMessageBox({
      type: 'warning', title: 'Bill', message: 'End Study Mode early?',
      detail: `There are ${minutes} minutes left. Bill will have opinions.`,
      buttons: ['Keep Studying', 'End Session'], defaultId: 0, cancelId: 0, noLink: true,
    });
    study.cancel(response === 1);
    this.refresh();
  }

  dispose() {
    clearInterval(this.minuteTimer);
    if (this.tray && !this.tray.isDestroyed()) this.tray.destroy();
    this.tray = null;
  }
}

module.exports = { AppMenu };
