// Port of UI/ChatWindow/BarkPanelController.swift.
//
// The bark bubble is its own free-floating window, completely decoupled from
// Bill's: it can sit left, right, above or below him without being cropped by
// his window, and it never takes a click.
const path = require('path');
const { BrowserWindow } = require('electron');
const geometry = require('./geometry');
const { makeBubble } = require('../core/bubble');

/** The gap between the tail tip and Bill. */
const GAP = 6;
const FADE = 220;
const MAX_WIDTH = 240;
const pick = (list) => list[Math.floor(Math.random() * list.length)];

class BarkWindow {
  constructor({ prefs }) {
    this.prefs = prefs;
    this.window = null;
    this.isLoaded = false;
    this.isVisible = false;
    this.frame = null;
    this.lastBillFrame = null;
    this.pending = null;
    this.hideTimer = null;
    this.lastPlacement = null;
  }

  create() {
    const win = new BrowserWindow({
      width: 200, height: 80, show: false,
      frame: false, transparent: true, backgroundColor: '#00000000', hasShadow: false,
      resizable: false, movable: false, minimizable: false, maximizable: false, fullscreenable: false,
      skipTaskbar: true, focusable: false, alwaysOnTop: true, thickFrame: false, roundedCorners: false,
      title: 'Bill — Bark',
      webPreferences: {
        preload: path.join(__dirname, '..', '..', 'renderer', 'preload.js'),
        contextIsolation: true, nodeIntegration: false, sandbox: true, backgroundThrottling: false,
      },
    });
    this.window = win;
    win.setAlwaysOnTop(true, 'pop-up-menu');
    win.setIgnoreMouseEvents(true);
    if (process.platform !== 'win32') win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
    win.webContents.on('did-finish-load', () => {
      this.isLoaded = true;
      if (this.pending) { const p = this.pending; this.pending = null; this.present(p); }
    });
    win.webContents.on('render-process-gone', () => { this.isLoaded = false; if (!win.isDestroyed()) win.reload(); });
    win.loadFile(path.join(__dirname, '..', '..', 'renderer', 'bark.html'));
  }

  /**
   * Shows a bark near Bill in whichever direction has room: a random one when
   * there is room everywhere, away from the screen edge when he is near one.
   * `billFrame` and `screen` are in Y-up space.
   */
  show(text, billFrame, screen) {
    const visible = screen.visible;
    const maxX = visible.x + visible.w; const maxY = visible.y + visible.h;
    const bill = { minX: billFrame.x, maxX: billFrame.x + billFrame.w, minY: billFrame.y, maxY: billFrame.y + billFrame.h };
    bill.midX = (bill.minX + bill.maxX) / 2; bill.midY = (bill.minY + bill.maxY) / 2;

    const roomRight = maxX - bill.maxX - GAP;
    const roomLeft = bill.minX - visible.x - GAP;
    const roomAbove = maxY - bill.maxY - GAP;
    const roomBelow = bill.minY - visible.y - GAP;

    let direction;
    if (roomLeft > 120 && roomRight > 120 && roomAbove > 120 && roomBelow > 60) direction = pick(['left', 'right', 'above', 'below']);
    else if (roomRight >= roomLeft && roomRight > 80) direction = 'right';
    else if (roomLeft > 80) direction = 'left';
    else if (roomAbove > 80) direction = 'above';
    else direction = 'below';

    const textScale = this.prefs.get('bubbleTextScale');
    const columnWidth = Math.max(160, Math.min(MAX_WIDTH, visible.w * 0.2));
    const options = {
      left: { maxWidth: roomLeft, maxHeight: visible.h * 0.6, tailEdge: 'rightSide' },
      right: { maxWidth: roomRight, maxHeight: visible.h * 0.6, tailEdge: 'leftSide' },
      above: { maxWidth: columnWidth, maxHeight: roomAbove, tailEdge: 'above' },
      below: { maxWidth: columnWidth, maxHeight: roomBelow, tailEdge: 'below' },
    }[direction];
    const bubble = makeBubble({ text, textScale, ...options });
    const w = bubble.displayWidth; const h = bubble.displayHeight;

    let x; let y;
    if (direction === 'left') { x = bill.minX - GAP - w; y = bill.midY - h / 2; }
    else if (direction === 'right') { x = bill.maxX + GAP; y = bill.midY - h / 2; }
    else if (direction === 'above') { x = bill.midX - w / 2; y = bill.maxY + GAP; }
    else { x = bill.midX - w / 2; y = bill.minY - GAP - h; }

    this.frame = this.clamp({ x, y, w, h }, visible);
    this.lastBillFrame = billFrame;
    this.lastPlacement = { direction, text, frame: { ...this.frame }, lines: bubble.lines.length };
    const message = {
      grid: { w: bubble.w, h: bubble.h, scale: bubble.scale, cells: bubble.cells },
      accent: this.prefs.accentColor(),
      dark: this.prefs.get('darkModeChrome'),
    };
    if (this.isLoaded) this.present(message); else this.pending = message;
  }

  present(message) {
    const win = this.window;
    if (!win || win.isDestroyed()) return;
    clearTimeout(this.hideTimer);
    this.applyFrame();
    win.webContents.send('bark:show', message);
    win.showInactive();
    win.setAlwaysOnTop(true, 'pop-up-menu');
    this.isVisible = true;
  }

  fadeOut() {
    this.pending = null;
    const win = this.window;
    if (!win || win.isDestroyed() || !this.isVisible) return;
    win.webContents.send('bark:hide');
    clearTimeout(this.hideTimer);
    this.hideTimer = setTimeout(() => {
      this.isVisible = false;
      if (!win.isDestroyed()) win.hide();
    }, FADE + 30);
  }

  /** Follows Bill: applies however far he moved since the bark was placed, then re-clamps. */
  reposition(billFrame, screen) {
    if (!this.isVisible || !this.lastBillFrame || !this.frame) return;
    const dx = (billFrame.x + billFrame.w / 2) - (this.lastBillFrame.x + this.lastBillFrame.w / 2);
    const dy = (billFrame.y + billFrame.h / 2) - (this.lastBillFrame.y + this.lastBillFrame.h / 2);
    if (dx === 0 && dy === 0) return;
    this.frame = this.clamp({ ...this.frame, x: this.frame.x + dx, y: this.frame.y + dy }, screen.visible);
    this.lastBillFrame = billFrame;
    this.applyFrame();
  }

  clamp(frame, visible) {
    const out = { ...frame };
    if (out.x + out.w > visible.x + visible.w) out.x = visible.x + visible.w - out.w;
    if (out.x < visible.x) out.x = visible.x;
    if (out.y + out.h > visible.y + visible.h) out.y = visible.y + visible.h - out.h;
    if (out.y < visible.y) out.y = visible.y;
    return out;
  }

  applyFrame() {
    if (!this.window || this.window.isDestroyed() || !this.frame) return;
    const r = geometry.toDown(this.frame);
    this.window.setBounds({ x: Math.round(r.x), y: Math.round(r.y), width: Math.ceil(r.width), height: Math.ceil(r.height) });
  }

  async capture() {
    if (!this.window || this.window.isDestroyed()) return null;
    return (await this.window.webContents.capturePage()).toPNG();
  }

  dispose() {
    clearTimeout(this.hideTimer);
    if (this.window && !this.window.isDestroyed()) this.window.destroy();
    this.window = null;
  }
}

module.exports = { BarkWindow };
