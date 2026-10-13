// Port of the window half of UI/ChatWindow/PixelChatBubble.swift: the pixel
// chat bubble that opens beside Bill when you talk to him.
const { BrowserWindow, shell } = require('electron');
const geometry = require('./geometry');
const { rendererFile, localWebPreferences, lockDown, listen } = require('./windows');
const { GLYPHS, lineWidth } = require('../core/bubble');

const GAP = 14;
const clamp = (v, lo, hi) => Math.min(Math.max(v, lo), Math.max(lo, hi));

/** A line of the 5x7 dot-matrix font as a paintable grid (the header's "BILL"). */
function labelGrid(label) {
  const w = lineWidth(label) + 2; const h = 9;
  const cells = new Array(w * h).fill(0);
  let x = 1;
  for (const ch of label) {
    const rows = GLYPHS[ch];
    if (rows) for (let r = 0; r < 7; r++) for (let c = 0; c < 5; c++) if (rows[r][c] === '#') cells[(1 + r) * w + x + c] = 4;
    x += ch === ' ' ? 4 : 6;
  }
  return { w, h, scale: 2, cells };
}

class ChatBubble {
  constructor({ prefs }) {
    this.prefs = prefs;
    this.window = null;
    this.isLoaded = false;
    this.isVisible = false;
    this.pinned = false;
    this.isComposing = true;
    this.frame = null;
    this.bounds = null;
    this.tailSide = 'left';
    this.queue = [];
    /** A screen answer stays up when the user clicks back into their work. */
    this.pinned = false;
    this.onSubmit = null;
    this.onDismiss = null;
  }

  create() {
    const win = new BrowserWindow({
      width: 600, height: 520, show: false,
      frame: false, transparent: true, backgroundColor: '#00000000', hasShadow: false,
      resizable: false, minimizable: false, maximizable: false, fullscreenable: false,
      skipTaskbar: true, alwaysOnTop: true, thickFrame: false, roundedCorners: false,
      title: 'Talk to Bill',
      webPreferences: localWebPreferences(),
    });
    this.window = win;
    lockDown(win);
    win.setAlwaysOnTop(true, 'pop-up-menu');
    if (process.platform !== 'win32') win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });

    const mine = () => this.window;
    listen('chat:ready', mine, () => { this.isLoaded = true; this.sendStyle(); this.flush(); });
    listen('chat:submit', mine, (text) => { if (this.isComposing && this.onSubmit) this.onSubmit(String(text || '')); });
    listen('chat:close', mine, () => this.hide());
    listen('chat:openLink', mine, (url) => { if (/^https?:\/\//i.test(String(url))) shell.openExternal(String(url)); });

    // A click anywhere outside puts it away, but only while composing: a reply
    // that is still on its way should not be lost to a stray click.
    win.on('blur', () => {
      setTimeout(() => {
        if (!this.isVisible || !this.isComposing || this.pinned || BrowserWindow.getFocusedWindow()) return;
        this.hide();
      }, 80);
    });
    win.on('close', (event) => { if (!this.isQuitting) { event.preventDefault(); this.hide(); } });
    win.webContents.on('render-process-gone', () => { this.isLoaded = false; if (!win.isDestroyed()) win.reload(); });
    for (const key of ['bubbleAccentColorHex', 'darkModeChrome']) this.prefs.on(`change:${key}`, () => this.sendStyle());
    win.loadFile(rendererFile('chat.html'));
  }

  send(channel, payload) {
    if (!this.window || this.window.isDestroyed()) return;
    if (!this.isLoaded) { this.queue.push([channel, payload]); return; }
    this.window.webContents.send(channel, payload);
  }

  flush() {
    const queued = this.queue; this.queue = [];
    for (const [channel, payload] of queued) this.send(channel, payload);
  }

  sendStyle() {
    if (!this.isLoaded) return;
    this.window.webContents.send('chat:style', {
      accent: this.prefs.accentColor(), dark: this.prefs.get('darkModeChrome'), tailSide: this.tailSide, title: labelGrid('BILL'),
    });
  }

  // --------------------------------------------------------------- placement
  /** Beside Bill: his right if it fits, else his left, else centred over him. */
  place(anchor, visible, size) {
    const maxX = visible.x + visible.w;
    let x; let tail;
    if (anchor.x + anchor.w + GAP + size.w <= maxX) { x = anchor.x + anchor.w + GAP; tail = 'left'; }
    else if (anchor.x - GAP - size.w >= visible.x) { x = anchor.x - GAP - size.w; tail = 'right'; }
    else { x = clamp(anchor.x + anchor.w / 2 - size.w / 2, visible.x + 10, maxX - size.w - 10); tail = 'left'; }
    const y = clamp(anchor.y, visible.y + 20, visible.y + visible.h - size.h - 20);
    return { frame: { x, y, w: size.w, h: size.h }, tail };
  }

  apply(placement) {
    this.frame = placement.frame;
    const r = geometry.toDown(this.frame);
    this.bounds = { x: Math.round(r.x), y: Math.round(r.y), width: Math.round(r.width), height: Math.round(r.height) };
    this.window.setBounds(this.bounds);
    if (placement.tail !== this.tailSide) { this.tailSide = placement.tail; this.sendStyle(); }
  }

  showCompose(anchor, screen) {
    if (!this.window || this.window.isDestroyed()) return;
    const visible = screen.visible;
    const size = {
      w: Math.round(Math.min(this.prefs.get('chatBubbleMaxWidth'), visible.w - 20)),
      h: Math.round(Math.min(visible.h - 40, visible.h * 0.8)),
    };
    this.apply(this.place(anchor, visible, size));
    this.isComposing = true;
    this.isVisible = true;
    this.send('chat:compose');
    this.window.show();
    this.window.setAlwaysOnTop(true, 'pop-up-menu');
    this.window.focus();
    this.holdPosition();
  }

  /** An X11 window manager may place a window itself as it is mapped: say where it goes again once it is up. */
  holdPosition() {
    if (process.platform !== 'linux') return;
    const again = () => { if (this.isVisible && this.bounds && this.window && !this.window.isDestroyed()) this.window.setBounds(this.bounds); };
    again();
    setTimeout(again, 150);
  }

  /** Something Bill read off the screen, shown as the user's side of the conversation. */
  showUser(text) { this.send('chat:user', String(text)); }

  showWaiting() {
    this.isComposing = false;
    this.send('chat:waiting');
  }

  showResponse(text) {
    this.isComposing = true;
    this.send('chat:response', String(text));
    if (this.isVisible && this.window && !this.window.isDestroyed()) this.window.show();
  }

  /** Follows Bill: only ever moves, never resizes. */
  reanchor(anchor, screen) {
    if (!this.isVisible || !this.frame) return;
    this.apply(this.place(anchor, screen.visible, { w: this.frame.w, h: this.frame.h }));
  }

  /** The Settings width slider applies to a bubble that is already open. */
  relayout(anchor, screen) {
    if (!this.isVisible || !this.frame) return;
    const size = { w: Math.round(Math.min(this.prefs.get('chatBubbleMaxWidth'), screen.visible.w - 20)), h: this.frame.h };
    this.apply(this.place(anchor, screen.visible, size));
  }

  hide() {
    if (!this.isVisible) return;
    this.isVisible = false;
    this.isComposing = true;
    this.send('chat:compose');
    if (this.window && !this.window.isDestroyed()) this.window.hide();
    if (this.onDismiss) this.onDismiss();
  }

  async capture() {
    if (!this.window || this.window.isDestroyed()) return null;
    return (await this.window.webContents.capturePage()).toPNG();
  }

  dispose() {
    this.isQuitting = true;
    if (this.window && !this.window.isDestroyed()) this.window.destroy();
    this.window = null;
  }
}

module.exports = { ChatBubble };
