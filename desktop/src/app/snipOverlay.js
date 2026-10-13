// "Show Bill the problem": a see-through sheet over the display the pointer is
// on, where the user drags a box around whatever they want him to read.
const { BrowserWindow, screen } = require('electron');
const { rendererFile, localWebPreferences, lockDown, listen } = require('./windows');

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

class SnipOverlay {
  constructor() {
    this.window = null;
    this.settle = null;
    const mine = () => this.window;
    listen('snip:ready', mine, () => { this.isReady = true; });
    listen('snip:done', mine, (rect) => this.finish(rect));
    listen('snip:cancel', mine, () => this.finish(null));
  }

  get isOpen() { return !!this.window; }

  /** Resolves with a DIP screen rectangle (Y down), or null if the user backed out. */
  pick() {
    if (this.window) return Promise.resolve(null);
    const display = screen.getDisplayNearestPoint(screen.getCursorScreenPoint());
    const win = new BrowserWindow({
      ...display.bounds, show: false,
      frame: false, transparent: true, backgroundColor: '#00000000', hasShadow: false,
      resizable: false, movable: false, minimizable: false, maximizable: false, fullscreenable: false,
      skipTaskbar: true, alwaysOnTop: true, thickFrame: false, roundedCorners: false, enableLargerThanScreen: true,
      title: 'Show Bill the problem',
      webPreferences: localWebPreferences(),
    });
    this.window = win;
    this.isReady = false;
    this.origin = { x: display.bounds.x, y: display.bounds.y };
    lockDown(win);
    win.setAlwaysOnTop(true, 'screen-saver');
    win.once('ready-to-show', () => {
      if (win.isDestroyed()) return;
      win.setBounds(display.bounds);
      win.show();
      win.focus();
    });
    // Clicking through to another app (alt-tab, a notification) is backing out.
    win.on('blur', () => setTimeout(() => { if (this.window === win) this.finish(null); }, 120));
    win.on('closed', () => { if (this.window === win) { this.window = null; this.resolve(null); } });
    win.loadFile(rendererFile('snip.html'));
    return new Promise((resolve) => { this.settle = resolve; });
  }

  resolve(value) {
    const settle = this.settle;
    this.settle = null;
    if (settle) settle(value);
  }

  async finish(rect) {
    const win = this.window;
    if (!win) return;
    this.window = null;
    const origin = this.origin;
    if (!win.isDestroyed()) win.destroy();
    let result = null;
    if (rect && Number.isFinite(rect.x) && Number.isFinite(rect.y) && rect.width >= 8 && rect.height >= 8) {
      result = { x: origin.x + rect.x, y: origin.y + rect.y, width: rect.width, height: rect.height };
      // Let the sheet actually leave the screen before anyone photographs it.
      await sleep(220);
    }
    this.resolve(result);
  }

  cancel() { this.finish(null); }

  dispose() {
    const win = this.window;
    this.window = null;
    if (win && !win.isDestroyed()) win.destroy();
    this.resolve(null);
  }
}

module.exports = { SnipOverlay };
