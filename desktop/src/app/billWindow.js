// Port of UI/CharacterWindow/{BillPanel,BillHitTestView}.swift and the window
// half of CharacterWindowController.swift.
//
// A transparent, borderless, always-on-top window that never takes focus.
// Its position is kept here as a float rectangle in the Mac's Y-up screen
// space (see geometry.js); the real window follows it in whole pixels.
const path = require('path');
const { pathToFileURL } = require('url');
const { EventEmitter } = require('events');
const { BrowserWindow, ipcMain } = require('electron');
const geometry = require('./geometry');
const { REST_FRAME, DISPLAY_SCALE, allSpriteFiles } = require('../core/clips');

const BASE_SIZE = { w: 260, h: 250 };
/** The part of the window that is actually Bill, at scale 1, from the bottom-left. */
const HIT_BASE = { x: 60, y: 25, w: 140, h: 195 };
const NEAR_MARGIN = 260;
const FAR_POLL = 400;
const NEAR_POLL = 60;
const DRAG_THRESHOLD = 3;
const LEVEL = 'pop-up-menu';

class BillWindow extends EventEmitter {
  constructor({ stateMachine, prefs, spritesDir }) {
    super();
    this.stateMachine = stateMachine;
    this.prefs = prefs;
    this.spritesDir = spritesDir;
    this.window = null;
    this.origin = { x: 0, y: 0 };
    this.size = { w: BASE_SIZE.w, h: BASE_SIZE.h };
    this.facing = 1;
    this.isReady = false;
    this.spritesLoaded = null;
    this.lastClip = null;
    this.isActive = false;
    this.ignoresMouse = null;
    this.press = null;
    this.pollTimer = null;
    this.menuOpen = false;
  }

  get scale() { return this.prefs.get('characterScale'); }
  get frame() { return { x: this.origin.x, y: this.origin.y, w: this.size.w, h: this.size.h }; }
  get isDragging() { return !!(this.press && this.press.dragging); }

  /** Where Bill's body is on screen — what bubbles point at. */
  bodyRect() {
    const s = this.scale; const f = this.frame;
    return { x: f.x + f.w / 2 - 112 * s, y: f.y + 5 * s, w: 224 * s, h: 215 * s };
  }

  hitRegion() {
    const s = this.scale;
    return { x: this.origin.x + HIT_BASE.x * s, y: this.origin.y + HIT_BASE.y * s, w: HIT_BASE.w * s, h: HIT_BASE.h * s };
  }

  screen() {
    const f = this.frame;
    return geometry.screenAt({ x: f.x + f.w / 2, y: f.y + f.h / 2 });
  }

  // ---------------------------------------------------------------- creation
  create() {
    const s = this.scale;
    this.size = { w: Math.round(BASE_SIZE.w * s), h: Math.round(BASE_SIZE.h * s) };
    const visible = geometry.primaryScreen().visible;
    this.origin = { x: visible.x + visible.w - this.size.w - 24, y: visible.y + 24 };

    const win = new BrowserWindow({
      ...this.bounds(),
      show: false,
      frame: false,
      transparent: true,
      backgroundColor: '#00000000',
      hasShadow: false,
      resizable: false,
      movable: false,
      minimizable: false,
      maximizable: false,
      fullscreenable: false,
      skipTaskbar: true,
      focusable: false,
      alwaysOnTop: true,
      thickFrame: false,
      roundedCorners: false,
      title: 'Bill',
      webPreferences: {
        preload: path.join(__dirname, '..', '..', 'renderer', 'preload.js'),
        contextIsolation: true,
        nodeIntegration: false,
        sandbox: true,
        // He keeps animating whether or not anything thinks he is "visible".
        backgroundThrottling: false,
      },
    });
    this.window = win;
    win.setAlwaysOnTop(true, LEVEL);
    if (process.platform !== 'win32') win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
    win.setMenuBarVisibility(false);

    win.webContents.on('did-finish-load', () => this.initRenderer());
    win.webContents.on('render-process-gone', () => { this.isReady = false; if (!win.isDestroyed()) win.reload(); });
    win.once('ready-to-show', () => { win.showInactive(); this.applyBounds(); });
    win.loadFile(path.join(__dirname, '..', '..', 'renderer', 'bill.html'));

    const mine = (handler) => (event, ...args) => { if (this.window && event.sender === this.window.webContents) handler(...args); };
    ipcMain.on('bill:ready', mine((info) => this.rendererReady(info)));
    ipcMain.on('bill:pointerDown', mine(() => this.pointerDown()));
    ipcMain.on('bill:pointerUp', mine(() => this.pointerUp()));
    ipcMain.on('bill:contextMenu', mine(() => { if (!this.isDragging) this.emit('contextMenu'); }));
    ipcMain.on('bill:battery', mine((state) => this.emit('battery', state)));

    this.stateMachine.on('clip', (message) => { this.lastClip = message; this.send('bill:clip', message); });
    this.stateMachine.on('settle', () => { this.lastClip = null; this.send('bill:settle'); });
    this.stateMachine.on('activity', (active) => { this.isActive = active; this.send('bill:activity', active); });
    this.prefs.on('change:characterScale', () => this.applyScale());

    this.setClickThrough(true);
    this.pollCursor();
    // Another always-on-top window, or "show desktop", can bury him.
    this.raiseTimer = setInterval(() => {
      if (!this.window || this.window.isDestroyed() || this.menuOpen) return;
      if (!this.window.isVisible()) this.window.showInactive();
      this.window.setAlwaysOnTop(true, LEVEL);
    }, 5000);
  }

  initRenderer() {
    this.isReady = false;
    this.send('bill:init', {
      spritesUrl: `${pathToFileURL(this.spritesDir).href}/`,
      files: allSpriteFiles(),
      restFrame: REST_FRAME,
      displayScale: DISPLAY_SCALE,
      scale: this.scale,
      facing: this.facing,
    }, true);
  }

  rendererReady(info) {
    if (info && info.early) {
      this.isReady = true;
      this.send('bill:activity', this.isActive);
      if (this.lastClip) this.send('bill:clip', this.lastClip);
      return;
    }
    this.spritesLoaded = info;
    this.emit('ready', info);
  }

  send(channel, payload, force = false) {
    if (!this.window || this.window.isDestroyed() || (!this.isReady && !force)) return;
    this.window.webContents.send(channel, payload);
  }

  // ---------------------------------------------------------------- geometry
  bounds() {
    const r = geometry.toDown(this.frame);
    return { x: Math.round(r.x), y: Math.round(r.y), width: this.size.w, height: this.size.h };
  }

  applyBounds() {
    if (!this.window || this.window.isDestroyed()) return;
    // Always the full rectangle: on fractional display scaling, moving by
    // position alone lets the window's size creep.
    this.window.setBounds(this.bounds());
  }

  setOrigin(x, y) {
    this.origin = { x, y };
    this.applyBounds();
    this.emit('moved');
  }

  /** The sheet art faces left: +1 is as drawn, -1 mirrors him to face right. */
  setFacing(direction) {
    this.facing = direction;
    this.send('bill:facing', direction);
  }

  /** Resizes around his feet: same centre line, same bottom edge. */
  applyScale() {
    const s = this.scale;
    const midX = this.origin.x + this.size.w / 2;
    this.size = { w: Math.round(BASE_SIZE.w * s), h: Math.round(BASE_SIZE.h * s) };
    this.origin = { x: midX - this.size.w / 2, y: this.origin.y };
    this.send('bill:scale', s);
    this.clampToScreen();
  }

  /** Keeps *Bill* on screen, not the mostly-empty window around him. */
  clampToScreen() {
    const visible = this.screen().visible;
    const s = this.scale;
    const minX = visible.x - HIT_BASE.x * s;
    const maxX = visible.x + visible.w - (HIT_BASE.x + HIT_BASE.w) * s;
    const minY = visible.y - HIT_BASE.y * s;
    const maxY = visible.y + visible.h - (HIT_BASE.y + HIT_BASE.h) * s;
    this.setOrigin(
      Math.min(Math.max(this.origin.x, minX), Math.max(minX, maxX)),
      Math.min(Math.max(this.origin.y, minY), Math.max(minY, maxY)),
    );
  }

  /** Debug: parks him against the right edge, where bubbles have to flip sides. */
  parkNearRightEdge() {
    const visible = this.screen().visible;
    this.origin = { x: visible.x + visible.w - this.size.w + 150, y: visible.y + 24 };
    this.clampToScreen();
  }

  // ------------------------------------------------------------ click-through
  // The window is a rectangle but Bill is not. Rather than make the whole
  // rectangle swallow clicks, it ignores the mouse entirely except while the
  // pointer is actually over him.
  setClickThrough(ignore) {
    if (this.ignoresMouse === ignore || !this.window || this.window.isDestroyed()) return;
    this.ignoresMouse = ignore;
    this.window.setIgnoreMouseEvents(ignore);
  }

  pollCursor() {
    clearTimeout(this.pollTimer);
    if (!this.window || this.window.isDestroyed()) return;
    const cursor = geometry.cursor();
    const hit = this.hitRegion();
    const near = { x: hit.x - NEAR_MARGIN, y: hit.y - NEAR_MARGIN, w: hit.w + NEAR_MARGIN * 2, h: hit.h + NEAR_MARGIN * 2 };
    // Never flip mid-press: that would drop the drag on the floor.
    if (!this.press && !this.menuOpen) this.setClickThrough(!geometry.contains(hit, cursor));
    this.pollTimer = setTimeout(() => this.pollCursor(), geometry.contains(near, cursor) ? NEAR_POLL : FAR_POLL);
  }

  // -------------------------------------------------------------- drag + poke
  pointerDown() {
    if (this.press) return;
    this.press = { downAt: geometry.cursor(), origin: { ...this.origin }, dragging: false, timer: null };
    this.press.timer = setInterval(() => this.followCursor(), 16);
  }

  followCursor() {
    const press = this.press;
    if (!press) return;
    const cursor = geometry.cursor();
    const dx = cursor.x - press.downAt.x; const dy = cursor.y - press.downAt.y;
    if (!press.dragging) {
      if (Math.hypot(dx, dy) <= DRAG_THRESHOLD) return;
      press.dragging = true;
      this.emit('dragStart');
    }
    this.setOrigin(press.origin.x + dx, press.origin.y + dy);
  }

  pointerUp() {
    const press = this.press;
    if (!press) return;
    clearInterval(press.timer);
    this.press = null;
    if (press.dragging) { this.clampToScreen(); this.emit('dragEnd'); }
    else this.emit('poke');
  }

  // ------------------------------------------------------------- context menu
  /** A window that cannot take focus cannot dismiss a menu either, so borrow focus for its lifetime. */
  popup(menu) {
    if (!this.window || this.window.isDestroyed()) return;
    this.menuOpen = true;
    const win = this.window;
    if (process.platform === 'win32') { win.setFocusable(true); win.focus(); }
    menu.popup({
      window: win,
      callback: () => {
        this.menuOpen = false;
        if (process.platform === 'win32' && !win.isDestroyed()) { win.setFocusable(false); win.setAlwaysOnTop(true, LEVEL); }
      },
    });
  }

  /** A PNG of exactly what the window is showing (self-test). */
  async capture() {
    if (!this.window || this.window.isDestroyed()) return null;
    return (await this.window.webContents.capturePage()).toPNG();
  }

  dispose() {
    clearTimeout(this.pollTimer);
    clearInterval(this.raiseTimer);
    if (this.press) clearInterval(this.press.timer);
    if (this.window && !this.window.isDestroyed()) this.window.destroy();
    this.window = null;
  }
}

module.exports = { BillWindow, BASE_SIZE, HIT_BASE };
