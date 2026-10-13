// The seam between Bill and the operating system. Everything above this file
// is platform-neutral; everything OS-specific lives in win32.js / linux.js.
//
// All rectangles that leave this module are in Electron DIPs with a top-left
// origin, whatever the backend natively speaks.
const fs = require('fs');
const os = require('os');
const path = require('path');
const { app, screen, shell, desktopCapturer } = require('electron');
const reader = require('./reader');

const stub = {
  name: 'unsupported', coordsArePhysical: false, permissionNote: null,
  listWindows: () => [], setOwnPids: () => {}, foreground: () => null, windowTitle: () => null,
  minimize: () => false, activate: () => false, windowState: () => null, moveWindow: () => false, restore: () => false,
  setCursor: () => false, isMouseDown: () => false, canMoveCursor: () => false, readVolume: async () => null, watchVolume: () => () => {},
  linkQuality: async () => ({ type: 'wired' }), installedApps: async () => [], ocr: async () => null,
  ocrStatus: { available: false, detail: 'Not supported on this platform.' },
};

let backend = stub;
try {
  if (process.platform === 'win32') backend = require('./win32');
  else if (process.platform === 'linux') backend = require('./linux');
} catch (e) {
  console.error('platform: backend failed to load —', e.message);
}

function toDipRect(rect) {
  if (!backend.coordsArePhysical) return rect;
  if (process.platform === 'win32') {
    const r = screen.screenToDipRect(null, rect);
    return { x: r.x, y: r.y, width: r.width, height: r.height };
  }
  const scale = screen.getPrimaryDisplay().scaleFactor || 1;
  if (scale === 1) return rect;
  return { x: rect.x / scale, y: rect.y / scale, width: rect.width / scale, height: rect.height / scale };
}

function refreshOwnPids() {
  try { backend.setOwnPids(app.getAppMetrics().map((m) => m.pid)); } catch { /* not ready yet */ }
}

/** Other apps' windows, front-to-back: [{ id, pid, rect, title }]. */
function listWindows() {
  try {
    return backend.listWindows().map((w) => ({ ...w, rect: toDipRect(w.rect) }));
  } catch (e) {
    return [];
  }
}

/** The focused window's app: { windowId, pid, title, id, name, desktopCategories } | { own: true } | null. */
function foreground() {
  try { return backend.foreground(); } catch { return null; }
}

const safe = (fn, fallback) => (...args) => { try { return fn(...args); } catch { return fallback; } };

/** How many native pixels one DIP is, for a window at this DIP rectangle. */
function scaleAt(rect) {
  if (!backend.coordsArePhysical) return 1;
  if (process.platform === 'win32' && rect) return screen.getDisplayMatching(rect).scaleFactor || 1;
  return screen.getPrimaryDisplay().scaleFactor || 1;
}

/**
 * A window Bill is about to push around: where it is in the backend's own
 * pixels (`origin`, what `moveWindow` takes), the outline the user sees in
 * DIPs, and how many native pixels make one DIP there.
 */
function windowState(windowId) {
  try {
    const state = backend.windowState(windowId);
    if (!state) return null;
    const rect = toDipRect(state.frame);
    return { origin: { x: state.x, y: state.y }, rect, scale: scaleAt(rect), minimized: state.minimized, maximized: state.maximized };
  } catch { return null; }
}

/** True when a window covers a whole display: a game, a film, a presentation. Not something to play with. */
function isFullscreen(windowId) {
  const state = windowState(windowId);
  if (!state || state.minimized) return false;
  const display = screen.getDisplayMatching(state.rect).bounds;
  return state.rect.x <= display.x && state.rect.y <= display.y
    && state.rect.x + state.rect.width >= display.x + display.width
    && state.rect.y + state.rect.height >= display.y + display.height;
}

/** Puts the mouse pointer at a DIP screen point (Y down). False where the session does not allow it. */
function setCursor(point) {
  try {
    if (process.platform === 'win32') {
      const p = screen.dipToScreenPoint({ x: Math.round(point.x), y: Math.round(point.y) });
      return backend.setCursor(p.x, p.y);
    }
    const scale = scaleAt(null);
    return backend.setCursor(point.x * scale, point.y * scale);
  } catch { return false; }
}

/** The composited screen under a DIP rectangle (Y down), as a nativeImage at full resolution. */
async function captureRegion(rect) {
  try {
    const display = screen.getDisplayMatching({ x: Math.round(rect.x), y: Math.round(rect.y), width: Math.max(1, Math.round(rect.width)), height: Math.max(1, Math.round(rect.height)) });
    const factor = display.scaleFactor || 1;
    const sources = await desktopCapturer.getSources({
      types: ['screen'],
      thumbnailSize: { width: Math.round(display.size.width * factor), height: Math.round(display.size.height * factor) },
    });
    const source = sources.find((s) => String(s.display_id) === String(display.id)) || (sources.length === 1 ? sources[0] : null);
    if (!source || source.thumbnail.isEmpty()) return null;
    const shot = source.thumbnail;
    const size = shot.getSize();
    const kx = size.width / display.bounds.width; const ky = size.height / display.bounds.height;
    const x0 = Math.max(0, Math.floor((rect.x - display.bounds.x) * kx));
    const y0 = Math.max(0, Math.floor((rect.y - display.bounds.y) * ky));
    const x1 = Math.min(size.width, Math.ceil((rect.x - display.bounds.x + rect.width) * kx));
    const y1 = Math.min(size.height, Math.ceil((rect.y - display.bounds.y + rect.height) * ky));
    if (x1 - x0 < 2 || y1 - y0 < 2) return null;
    return shot.crop({ x: x0, y: y0, width: x1 - x0, height: y1 - y0 });
  } catch {
    return null;
  }
}

/** Enlarges small crops: recognisers want tall letters. */
function enlarged(image, factor) {
  const size = image.getSize();
  return image.resize({ width: Math.round(size.width * factor), height: Math.round(size.height * factor), quality: 'best' });
}

/**
 * Text in an image, read on this computer. Bill's own reader goes first (it
 * keeps the symbols in a sum); the operating system's is the fallback.
 */
async function readImage(image, { block = false } = {}) {
  if (!image || image.isEmpty()) return null;
  const size = image.getSize();
  const long = Math.max(size.width, size.height);
  if (reader.available) {
    // Screen text comes in every size, so a small crop is read twice, as it is
    // and doubled, and the reading the engine is surer of wins.
    const candidates = long < 1600 ? [image, enlarged(image, 2)] : [image];
    let best = null;
    for (const candidate of candidates) {
      const result = await reader.read(candidate.toPNG(), { block });
      if (result && result.text.trim() && (!best || result.confidence > best.confidence)) best = result;
    }
    if (best) return best.text;
  }
  if (!backend.ocrStatus.available) return null;
  let prepared = image;
  if (long < 1400 && size.height < 900) {
    const factor = Math.min(3, 1400 / Math.max(1, long));
    if (factor > 1.15) prepared = enlarged(image, factor);
  }
  const file = path.join(os.tmpdir(), `bill-read-${process.pid}-${Date.now()}.png`);
  try {
    await fs.promises.writeFile(file, prepared.toPNG());
    return await backend.ocr(file, { block }).catch(() => null);
  } catch {
    return null;
  } finally {
    fs.promises.unlink(file).catch(() => {});
  }
}

/** A PNG of one window (long edge <= `maxEdge`) in a temp file, for OCR. Caller deletes it. */
async function captureWindow(windowId, maxEdge = 1000) {
  try {
    const sources = await desktopCapturer.getSources({ types: ['window'], thumbnailSize: { width: maxEdge, height: maxEdge }, fetchWindowIcons: false });
    const source = sources.find((s) => s.id.split(':')[1] === String(windowId));
    if (!source || source.thumbnail.isEmpty()) return null;
    const file = path.join(os.tmpdir(), `bill-ocr-${process.pid}-${Date.now()}.png`);
    await fs.promises.writeFile(file, source.thumbnail.toPNG());
    return { file, size: source.thumbnail.getSize(), image: source.thumbnail };
  } catch {
    return null;
  }
}

// ------------------------------------------------------- launch at login
const autostartFile = () => path.join(process.env.XDG_CONFIG_HOME || path.join(os.homedir(), '.config'), 'autostart', 'bill.desktop');

function launchCommand() {
  if (process.env.APPIMAGE) return { exe: process.env.APPIMAGE, args: [] };
  return { exe: process.execPath, args: app.isPackaged ? [] : [app.getAppPath()] };
}

function setLaunchAtLogin(enabled) {
  const { exe, args } = launchCommand();
  try {
    if (process.platform === 'linux') {
      const file = autostartFile();
      if (!enabled) { fs.rmSync(file, { force: true }); return true; }
      const quote = (s) => `"${s.replace(/(["\\$`])/g, '\\$1')}"`;
      fs.mkdirSync(path.dirname(file), { recursive: true });
      fs.writeFileSync(file, [
        '[Desktop Entry]', 'Type=Application', 'Name=Bill',
        'Comment=Bill Cipher desktop companion',
        `Exec=${[exe, ...args].map(quote).join(' ')}`,
        'X-GNOME-Autostart-enabled=true', 'Terminal=false', '',
      ].join('\n'));
      return true;
    }
    app.setLoginItemSettings({ openAtLogin: !!enabled, path: exe, args });
    return true;
  } catch (e) {
    console.error('launch at login:', e.message);
    return false;
  }
}

function isLaunchAtLoginEnabled() {
  try {
    if (process.platform === 'linux') return fs.existsSync(autostartFile());
    const { exe, args } = launchCommand();
    return !!app.getLoginItemSettings({ path: exe, args }).openAtLogin;
  } catch { return false; }
}

module.exports = {
  name: backend.name,
  refreshOwnPids, listWindows, foreground, captureWindow, captureRegion, readImage,
  windowState, isFullscreen, setCursor,
  moveWindow: safe((id, x, y) => backend.moveWindow(id, x, y), false),
  restore: safe((id) => backend.restore(id), false),
  isMouseDown: safe(() => backend.isMouseDown(), false),
  canMoveCursor: safe(() => backend.canMoveCursor(), false),
  windowTitle: safe((id) => backend.windowTitle(id), null),
  minimize: safe((id) => backend.minimize(id), false),
  activate: safe((id) => backend.activate(id), false),
  readVolume: () => backend.readVolume().catch(() => null),
  watchVolume: (cb) => { try { return backend.watchVolume(cb); } catch { return () => {}; } },
  linkQuality: () => backend.linkQuality().catch(() => ({ type: 'wired' })),
  installedApps: () => backend.installedApps(shell).catch(() => []),
  ocr: (file, options) => backend.ocr(file, options).catch(() => null),
  get ocrStatus() { return backend.ocrStatus; },
  /** Whether he can read something the user shows him (his own reader, or the system's). */
  get canReadScreen() { return reader.available || backend.ocrStatus.available; },
  get readerDetail() { return reader.available ? reader.detail : backend.ocrStatus.detail; },
  disposeReader: () => reader.dispose(),
  setLaunchAtLogin, isLaunchAtLoginEnabled,
};
