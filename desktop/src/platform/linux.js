// Linux backend: everything the Mac app got from AppKit / CoreGraphics /
// Accessibility / CoreAudio, via Xlib (through koffi) and standard desktop CLIs.
//
//   CGWindowListCopyWindowInfo        -> _NET_CLIENT_LIST_STACKING + geometry
//   NSWorkspace.frontmostApplication  -> _NET_ACTIVE_WINDOW + WM_CLASS + .desktop
//   AX focused-window title           -> _NET_WM_NAME (no permission needed)
//   AX minimize-button press          -> XIconifyWindow
//   CoreAudio volume + mute           -> pactl / wpctl / amixer
//   CoreWLAN RSSI                     -> /proc/net/wireless
//   Vision OCR                        -> tesseract (if installed)
//
// X11 only. Under Wayland the app relaunches itself on XWayland (see main.js),
// because Wayland deliberately gives no client a way to position its own
// window or to see anyone else's — both of which Bill's whole act depends on.
const koffi = require('koffi');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFile, spawn } = require('child_process');

const num = (v) => (typeof v === 'bigint' ? Number(v) : v);
const ownPid = process.pid;
const ownPids = new Set();
function setOwnPids(pids) { ownPids.clear(); for (const p of pids) ownPids.add(p); }

// ------------------------------------------------------------------- Xlib
let X = null;
const arrayTypes = new Map();
function arrayOf(type, count) {
  const key = `${type}:${count}`;
  let t = arrayTypes.get(key);
  if (!t) { t = koffi.array(type, count); arrayTypes.set(key, t); }
  return t;
}

function openX() {
  if (X !== null) return X;
  try {
    const lib = koffi.load('libX11.so.6');
    const XWindowAttributes = koffi.struct('XWindowAttributes', {
      x: 'int', y: 'int', width: 'int', height: 'int', border_width: 'int', depth: 'int',
      visual: 'void *', root: 'ulong', class: 'int', bit_gravity: 'int', win_gravity: 'int',
      backing_store: 'int', backing_planes: 'ulong', backing_pixel: 'ulong', save_under: 'int',
      colormap: 'ulong', map_installed: 'int', map_state: 'int', all_event_masks: 'long',
      your_event_mask: 'long', do_not_propagate_mask: 'long', override_redirect: 'int', screen: 'void *',
    });
    const fn = {
      XOpenDisplay: lib.func('XOpenDisplay', 'void *', ['str']),
      XDefaultRootWindow: lib.func('XDefaultRootWindow', 'ulong', ['void *']),
      XDefaultScreen: lib.func('XDefaultScreen', 'int', ['void *']),
      XInternAtom: lib.func('XInternAtom', 'ulong', ['void *', 'str', 'int']),
      XGetWindowProperty: lib.func('XGetWindowProperty', 'int', [
        'void *', 'ulong', 'ulong', 'long', 'long', 'int', 'ulong',
        koffi.out(koffi.pointer('ulong')), koffi.out(koffi.pointer('int')),
        koffi.out(koffi.pointer('ulong')), koffi.out(koffi.pointer('ulong')), koffi.out(koffi.pointer('void *')),
      ]),
      XFree: lib.func('XFree', 'int', ['void *']),
      XGetWindowAttributes: lib.func('XGetWindowAttributes', 'int', ['void *', 'ulong', koffi.out(koffi.pointer(XWindowAttributes))]),
      XTranslateCoordinates: lib.func('XTranslateCoordinates', 'int', [
        'void *', 'ulong', 'ulong', 'int', 'int',
        koffi.out(koffi.pointer('int')), koffi.out(koffi.pointer('int')), koffi.out(koffi.pointer('ulong')),
      ]),
      XQueryTree: lib.func('XQueryTree', 'int', [
        'void *', 'ulong', koffi.out(koffi.pointer('ulong')), koffi.out(koffi.pointer('ulong')),
        koffi.out(koffi.pointer('void *')), koffi.out(koffi.pointer('uint')),
      ]),
      XIconifyWindow: lib.func('XIconifyWindow', 'int', ['void *', 'ulong', 'int']),
      XMoveWindow: lib.func('XMoveWindow', 'int', ['void *', 'ulong', 'int', 'int']),
      XMapWindow: lib.func('XMapWindow', 'int', ['void *', 'ulong']),
      XWarpPointer: lib.func('XWarpPointer', 'int', ['void *', 'ulong', 'ulong', 'int', 'int', 'uint', 'uint', 'int', 'int']),
      XQueryPointer: lib.func('XQueryPointer', 'int', [
        'void *', 'ulong', koffi.out(koffi.pointer('ulong')), koffi.out(koffi.pointer('ulong')),
        koffi.out(koffi.pointer('int')), koffi.out(koffi.pointer('int')),
        koffi.out(koffi.pointer('int')), koffi.out(koffi.pointer('int')), koffi.out(koffi.pointer('uint')),
      ]),
      XSendEvent: lib.func('XSendEvent', 'int', ['void *', 'ulong', 'int', 'long', 'void *']),
      XFlush: lib.func('XFlush', 'int', ['void *']),
      XSync: lib.func('XSync', 'int', ['void *', 'int']),
      XSetErrorHandler: lib.func('XSetErrorHandler', 'void *', ['void *']),
    };
    // Xlib's default error handler exits the process. Windows vanish between
    // being listed and being asked about all the time (BadWindow), so that
    // must never be fatal.
    const handlerType = koffi.proto('int BillXErrorHandler(void *display, void *event)');
    const handler = koffi.register(() => 0, koffi.pointer(handlerType));
    fn.XSetErrorHandler(handler);

    const dpy = fn.XOpenDisplay(null);
    if (!dpy) throw new Error('XOpenDisplay failed (no DISPLAY?)');
    const atom = (name) => num(fn.XInternAtom(dpy, name, 0));
    X = {
      ...fn, dpy, handler,
      root: num(fn.XDefaultRootWindow(dpy)),
      screen: fn.XDefaultScreen(dpy),
      A: {
        clientListStacking: atom('_NET_CLIENT_LIST_STACKING'), clientList: atom('_NET_CLIENT_LIST'),
        activeWindow: atom('_NET_ACTIVE_WINDOW'), currentDesktop: atom('_NET_CURRENT_DESKTOP'),
        wmDesktop: atom('_NET_WM_DESKTOP'), wmPid: atom('_NET_WM_PID'), wmName: atom('_NET_WM_NAME'),
        wmNameLegacy: atom('WM_NAME'), wmClass: atom('WM_CLASS'), wmState: atom('_NET_WM_STATE'),
        icccmState: atom('WM_STATE'), hidden: atom('_NET_WM_STATE_HIDDEN'),
        windowType: atom('_NET_WM_WINDOW_TYPE'), typeNormal: atom('_NET_WM_WINDOW_TYPE_NORMAL'),
        typeDialog: atom('_NET_WM_WINDOW_TYPE_DIALOG'), frameExtents: atom('_NET_FRAME_EXTENTS'),
        gtkFrameExtents: atom('_GTK_FRAME_EXTENTS'),
        maximizedVert: atom('_NET_WM_STATE_MAXIMIZED_VERT'), maximizedHorz: atom('_NET_WM_STATE_MAXIMIZED_HORZ'),
        fullscreen: atom('_NET_WM_STATE_FULLSCREEN'),
      },
    };
  } catch (e) {
    console.error('linux: X11 unavailable —', e.message);
    X = false;
  }
  return X;
}

/** Reads a property. Format 32 comes back as numbers, format 8 as a Buffer. */
function property(win, atom, maxItems = 4096) {
  const type = [0]; const format = [0]; const count = [0]; const after = [0]; const data = [null];
  if (X.XGetWindowProperty(X.dpy, win, atom, 0, maxItems, 0, 0, type, format, count, after, data) !== 0) return null;
  if (!data[0]) return null;
  try {
    const n = num(count[0]);
    if (!n) return null;
    // Xlib hands 32-bit properties back as an array of C `long`, which is 8 bytes on 64-bit Linux.
    if (format[0] === 32) return Array.from(koffi.decode(data[0], arrayOf('long', n)), num);
    if (format[0] === 8) return Buffer.from(koffi.decode(data[0], arrayOf('uint8', n)));
    return null;
  } finally { X.XFree(data[0]); }
}
const longs = (win, atom, maxItems) => { const v = property(win, atom, maxItems); return Array.isArray(v) ? v : null; };
const bytes = (win, atom) => { const v = property(win, atom); return Buffer.isBuffer(v) ? v : null; };
const first = (list) => (list && list.length ? list[0] : null);

function titleOf(win) {
  const utf8 = bytes(win, X.A.wmName);
  if (utf8) return utf8.toString('utf8').replace(/\0+$/, '');
  const legacy = bytes(win, X.A.wmNameLegacy);
  return legacy ? legacy.toString('latin1').replace(/\0+$/, '') : '';
}
function classOf(win) {
  const raw = bytes(win, X.A.wmClass);
  if (!raw) return { instance: '', cls: '' };
  const [instance = '', cls = ''] = raw.toString('utf8').split('\0');
  return { instance, cls };
}
const pidOf = (win) => first(longs(win, X.A.wmPid)) || 0;

/** The outline the user sees, in root-window pixels. */
function geometry(win) {
  const attrs = {};
  if (!X.XGetWindowAttributes(X.dpy, win, attrs)) return null;
  if (attrs.map_state !== 2 || attrs.class === 2) return null; // not viewable, or InputOnly
  const ox = [0]; const oy = [0]; const child = [0];
  X.XTranslateCoordinates(X.dpy, win, X.root, 0, 0, ox, oy, child);
  let x = ox[0]; let y = oy[0]; let width = attrs.width; let height = attrs.height;
  // Server-side decorations sit outside the client window: grow to include the title bar.
  const frame = longs(win, X.A.frameExtents);
  if (frame && frame.length === 4) { x -= frame[0]; y -= frame[2]; width += frame[0] + frame[1]; height += frame[2] + frame[3]; }
  // Client-side decorations (GTK) pad the window with an invisible shadow: shrink to what is drawn.
  const gtk = longs(win, X.A.gtkFrameExtents);
  if (gtk && gtk.length === 4) { x += gtk[0]; y += gtk[2]; width -= gtk[0] + gtk[1]; height -= gtk[2] + gtk[3]; }
  if (width <= 0 || height <= 0) return null;
  return { x, y, width, height };
}

/** For window managers that publish no EWMH client list: walk the tree for WM_STATE holders. */
function children(win) {
  const root = [0]; const parent = [0]; const list = [null]; const n = [0];
  if (!X.XQueryTree(X.dpy, win, root, parent, list, n) || !list[0]) return [];
  try { return n[0] ? Array.from(koffi.decode(list[0], arrayOf('ulong', n[0])), num) : []; } finally { X.XFree(list[0]); }
}

function treeClients() {
  const result = [];
  const findClient = (win, depth) => {
    if (property(win, X.A.icccmState)) return win;
    if (depth >= 2) return null;
    for (const child of children(win)) { const hit = findClient(child, depth + 1); if (hit) return hit; }
    return null;
  };
  for (const top of children(X.root)) { const client = findClient(top, 0); if (client) result.push(client); }
  return result;
}

/** Every real, visible top-level window, front-to-back, in physical pixels. */
function listWindows() {
  if (!openX()) return [];
  const ids = longs(X.root, X.A.clientListStacking, 8192) || longs(X.root, X.A.clientList, 8192) || treeClients();
  const current = first(longs(X.root, X.A.currentDesktop));
  const result = [];
  for (let i = ids.length - 1; i >= 0; i--) {
    const win = ids[i];
    const pid = pidOf(win);
    if (pid === ownPid || ownPids.has(pid)) continue;
    const state = longs(win, X.A.wmState);
    if (state && state.includes(X.A.hidden)) continue;
    const type = longs(win, X.A.windowType);
    if (type && type.length && !type.some((t) => t === X.A.typeNormal || t === X.A.typeDialog)) continue;
    const desktop = first(longs(win, X.A.wmDesktop));
    if (current !== null && desktop !== null && desktop !== current && desktop !== 0xFFFFFFFF && desktop !== -1) continue;
    const rect = geometry(win);
    if (rect) result.push({ id: win, pid, rect, title: titleOf(win) });
  }
  return result;
}

// --------------------------------------------------------- .desktop index
// The Linux equivalent of an app bundle's Info.plist: display name, launcher
// categories, and the WM_CLASS that ties a running window back to it.
const desktopIndex = { byClass: new Map(), byFile: new Map(), byExec: new Map(), entries: [], loaded: false };

function desktopDirs() {
  const home = os.homedir();
  const data = (process.env.XDG_DATA_DIRS || '/usr/local/share:/usr/share').split(':').filter(Boolean);
  const dirs = [path.join(process.env.XDG_DATA_HOME || path.join(home, '.local/share'), 'applications')];
  for (const d of data) dirs.push(path.join(d, 'applications'));
  dirs.push('/var/lib/flatpak/exports/share/applications', path.join(home, '.local/share/flatpak/exports/share/applications'), '/var/lib/snapd/desktop/applications');
  return [...new Set(dirs)];
}

function parseDesktopFile(text) {
  const entry = {};
  let inMain = false;
  for (const raw of text.split('\n')) {
    const line = raw.trim();
    if (line.startsWith('[')) { inMain = line === '[Desktop Entry]'; continue; }
    if (!inMain || !line || line.startsWith('#')) continue;
    const eq = line.indexOf('=');
    if (eq > 0) entry[line.slice(0, eq).trim()] = line.slice(eq + 1).trim();
  }
  return entry;
}

async function loadDesktopIndex() {
  if (desktopIndex.loaded) return desktopIndex;
  for (const dir of desktopDirs()) {
    let files;
    try { files = await fs.promises.readdir(dir); } catch { continue; }
    for (const file of files) {
      if (!file.endsWith('.desktop')) continue;
      let entry;
      try { entry = parseDesktopFile(await fs.promises.readFile(path.join(dir, file), 'utf8')); } catch { continue; }
      if (entry.Type && entry.Type !== 'Application') continue;
      if (!entry.Name) continue;
      const base = file.slice(0, -8);
      const exec = (entry.Exec || '').split(/\s+/).filter((part) => part && !part.startsWith('%') && !/^[A-Z_]+=/.test(part) && part !== 'env')[0] || '';
      const record = {
        id: (entry.StartupWMClass || base).toLowerCase(),
        name: entry.Name,
        categories: (entry.Categories || '').split(';').filter(Boolean),
        hidden: entry.NoDisplay === 'true' || entry.Hidden === 'true',
      };
      if (desktopIndex.byFile.has(base.toLowerCase())) continue; // earlier dirs win (user overrides system)
      desktopIndex.entries.push(record);
      desktopIndex.byFile.set(base.toLowerCase(), record);
      const short = base.split('.').pop().toLowerCase();
      if (!desktopIndex.byFile.has(short)) desktopIndex.byFile.set(short, record);
      if (entry.StartupWMClass) desktopIndex.byClass.set(entry.StartupWMClass.toLowerCase(), record);
      const execBase = path.basename(exec).toLowerCase();
      if (execBase && !desktopIndex.byExec.has(execBase)) desktopIndex.byExec.set(execBase, record);
    }
  }
  desktopIndex.loaded = true;
  return desktopIndex;
}

function lookupDesktop(instance, cls) {
  const c = cls.toLowerCase(); const i = instance.toLowerCase();
  return desktopIndex.byClass.get(c) || desktopIndex.byClass.get(i)
    || desktopIndex.byFile.get(c) || desktopIndex.byFile.get(i)
    || desktopIndex.byExec.get(i) || desktopIndex.byExec.get(c) || null;
}

// ---------------------------------------------------------- foreground app
/** The program behind a window. Unreadable for another user's process, which is fine. */
function exeOf(pid) {
  if (!pid) return null;
  try { return fs.readlinkSync(`/proc/${pid}/exe`); } catch { return null; }
}

function describeWindow(win) {
  const pid = pidOf(win);
  const title = titleOf(win);
  const { instance, cls } = classOf(win);
  const entry = lookupDesktop(instance, cls);
  const raw = cls || instance || `pid-${pid}`;
  return {
    windowId: win, pid, title, exe: exeOf(pid),
    id: entry ? entry.id : raw.toLowerCase(),
    name: entry ? entry.name : raw.replace(/[-_.]/g, ' ').replace(/\b\w/g, (ch) => ch.toUpperCase()),
    desktopCategories: entry ? entry.categories : null,
  };
}

function foreground() {
  if (!openX()) return null;
  const win = first(longs(X.root, X.A.activeWindow));
  if (!win) return null;
  const pid = pidOf(win);
  if (pid === ownPid || ownPids.has(pid)) return { own: true, windowId: win, pid };
  const type = longs(win, X.A.windowType);
  if (type && type.length && !type.some((t) => t === X.A.typeNormal || t === X.A.typeDialog)) return null;
  return describeWindow(win);
}

function windowTitle(windowId) { return openX() && windowId ? titleOf(windowId) || null : null; }

function minimize(windowId) {
  if (!openX() || !windowId) return false;
  const ok = X.XIconifyWindow(X.dpy, windowId, X.screen) !== 0;
  X.XFlush(X.dpy);
  return ok;
}

function activate(windowId) {
  if (!openX() || !windowId) return false;
  // An XClientMessageEvent laid out by hand (LP64): type, serial, send_event,
  // display, window, message_type, format, then five longs of data.
  const event = Buffer.alloc(192);
  event.writeInt32LE(33, 0); // ClientMessage
  event.writeInt32LE(1, 16);
  event.writeBigUInt64LE(BigInt(windowId), 32);
  event.writeBigUInt64LE(BigInt(X.A.activeWindow), 40);
  event.writeInt32LE(32, 48);
  event.writeBigInt64LE(2n, 56); // source indication: pager / direct user action
  const mask = (1 << 20) | (1 << 19); // SubstructureRedirect | SubstructureNotify
  const ok = X.XSendEvent(X.dpy, X.root, 0, mask, event) !== 0;
  X.XFlush(X.dpy);
  return ok;
}

// ------------------------------------------------- moving things on screen
/** Where a window is (root pixels) and whether it can be pushed around. */
function windowState(windowId) {
  if (!openX() || !windowId) return null;
  const attrs = {};
  if (!X.XGetWindowAttributes(X.dpy, windowId, attrs)) return null;
  const ox = [0]; const oy = [0]; const child = [0];
  X.XTranslateCoordinates(X.dpy, windowId, X.root, 0, 0, ox, oy, child);
  // A move request names the corner of the window manager's frame, not of the
  // client inside it, so that is the corner to remember and to move.
  const extents = longs(windowId, X.A.frameExtents);
  const left = extents && extents.length === 4 ? extents[0] : 0;
  const top = extents && extents.length === 4 ? extents[2] : 0;
  const state = longs(windowId, X.A.wmState) || [];
  const frame = geometry(windowId);
  return {
    x: ox[0] - left, y: oy[0] - top, width: attrs.width, height: attrs.height,
    frame: frame || { x: ox[0] - left, y: oy[0] - top, width: attrs.width, height: attrs.height },
    minimized: attrs.map_state !== 2 || state.includes(X.A.hidden),
    maximized: state.includes(X.A.fullscreen) || (state.includes(X.A.maximizedVert) && state.includes(X.A.maximizedHorz)),
  };
}

/** Asks the window manager to move a window; it is not resized, raised or focused. */
function moveWindow(windowId, x, y) {
  if (!openX() || !windowId) return false;
  const ok = X.XMoveWindow(X.dpy, windowId, Math.round(x), Math.round(y)) !== 0;
  X.XFlush(X.dpy);
  return ok;
}

/** Brings a minimized window back. */
function restore(windowId) {
  if (!openX() || !windowId) return false;
  const ok = X.XMapWindow(X.dpy, windowId) !== 0;
  X.XFlush(X.dpy);
  return ok;
}

function pointer() {
  if (!openX()) return null;
  const r = [0]; const c = [0]; const rx = [0]; const ry = [0]; const wx = [0]; const wy = [0]; const mask = [0];
  if (!X.XQueryPointer(X.dpy, X.root, r, c, rx, ry, wx, wy, mask)) return null;
  return { x: rx[0], y: ry[0], mask: mask[0] };
}

// Under XWayland the server accepts a warp and the real pointer stays put;
// the first attempt finds out which kind of session this is.
let warpWorks = null;
function setCursor(x, y) {
  if (!openX() || warpWorks === false) return false;
  X.XWarpPointer(X.dpy, 0, X.root, 0, 0, 0, 0, Math.round(x), Math.round(y));
  X.XSync(X.dpy, 0);
  if (warpWorks === null) {
    const now = pointer();
    warpWorks = !!now && Math.abs(now.x - Math.round(x)) <= 2 && Math.abs(now.y - Math.round(y)) <= 2;
  }
  return warpWorks;
}
function canMoveCursor() { return !!openX() && warpWorks !== false; }
/** Any mouse button held: a drag is in progress and the pointer is not Bill's to touch. */
function isMouseDown() { const p = pointer(); return !!p && (p.mask & 0x700) !== 0; }

// ----------------------------------------------------------------- volume
function run(file, args, timeout = 6000) {
  return new Promise((resolve) => {
    execFile(file, args, { timeout, maxBuffer: 4 * 1024 * 1024 }, (err, stdout) => resolve(err ? null : String(stdout)));
  });
}

async function readVolume() {
  const [volume, mute] = await Promise.all([
    run('pactl', ['get-sink-volume', '@DEFAULT_SINK@']),
    run('pactl', ['get-sink-mute', '@DEFAULT_SINK@']),
  ]);
  if (volume) {
    const percents = [...volume.matchAll(/(\d+)%/g)].map((m) => Number(m[1]));
    if (percents.length) {
      const average = Math.round(percents.reduce((a, b) => a + b, 0) / percents.length);
      return { percent: Math.min(100, average), muted: /yes/i.test(mute || '') };
    }
  }
  const wp = await run('wpctl', ['get-volume', '@DEFAULT_AUDIO_SINK@']);
  const wpMatch = wp && wp.match(/Volume:\s*([\d.]+)/);
  if (wpMatch) return { percent: Math.min(100, Math.round(Number(wpMatch[1]) * 100)), muted: /MUTED/.test(wp) };
  const alsa = await run('amixer', ['get', 'Master']);
  const alsaMatch = alsa && alsa.match(/\[(\d+)%\]/);
  if (alsaMatch) return { percent: Number(alsaMatch[1]), muted: /\[off\]/.test(alsa) };
  return null;
}

/** Calls back with (percent|null, muted) whenever either changes. Returns a stop function. */
function watchVolume(onChange) {
  let last = null; let stopped = false; let debounce = null; let child = null; let poll = null;
  const check = async () => {
    const now = await readVolume();
    if (stopped || !now) return;
    if (!last) { last = now; return; }
    if (now.percent !== last.percent || now.muted !== last.muted) { last = now; onChange(now.percent, now.muted); }
  };
  const startPolling = () => { if (!poll && !stopped) poll = setInterval(check, 2000); };
  check();
  try {
    // PulseAudio and PipeWire both speak this; it pushes a line the instant anything changes.
    child = spawn('pactl', ['subscribe'], { stdio: ['ignore', 'pipe', 'ignore'] });
    child.stdout.on('data', (chunk) => {
      if (!/sink|server/i.test(String(chunk))) return;
      clearTimeout(debounce);
      debounce = setTimeout(check, 120);
    });
    child.on('error', startPolling);
    child.on('exit', startPolling);
  } catch { startPolling(); }
  return () => { stopped = true; clearTimeout(debounce); clearInterval(poll); if (child) child.kill(); };
}

// ------------------------------------------------------------------ wi-fi
/** { type: 'wifi', dbm } | { type: 'wired' } */
async function linkQuality() {
  let text;
  try { text = await fs.promises.readFile('/proc/net/wireless', 'utf8'); } catch { return { type: 'wired' }; }
  for (const line of text.split('\n').slice(2)) {
    const fields = line.trim().split(/\s+/);
    if (fields.length < 4) continue;
    const quality = parseFloat(fields[2]); const level = parseFloat(fields[3]);
    if (!Number.isFinite(level)) continue;
    // Most drivers report the level in dBm (negative); a few report 0-70 quality only.
    if (level < 0) return { type: 'wifi', dbm: level };
    if (Number.isFinite(quality) && quality > 0) return { type: 'wifi', dbm: quality / 70 * 60 - 100 };
  }
  return { type: 'wired' };
}

// --------------------------------------------------------- installed apps
async function installedApps() {
  const index = await loadDesktopIndex();
  const seen = new Set(); const result = [];
  for (const entry of index.entries) {
    if (entry.hidden || seen.has(entry.id)) continue;
    seen.add(entry.id);
    result.push({ id: entry.id, name: entry.name });
  }
  return result;
}

// -------------------------------------------------------------------- OCR
const ocrStatus = { available: false, detail: 'Needs the `tesseract` package (e.g. `sudo apt install tesseract-ocr`).' };
run('tesseract', ['--version']).then((out) => {
  if (!out) return;
  ocrStatus.available = true;
  ocrStatus.detail = `tesseract ${(out.match(/tesseract\s+([\d.]+)/) || [])[1] || ''}`.trim();
});
/** `block` reads the image as one block of text (a selected problem) rather than as scattered labels. */
async function ocr(pngPath, { block = false } = {}) {
  if (!ocrStatus.available) return null;
  const out = await run('tesseract', [pngPath, 'stdout', '--psm', block ? '6' : '11'], 30000);
  return out && out.trim() ? out.trim() : null;
}

loadDesktopIndex().catch(() => {});

/** What the X server shows, stage by stage — for working out why a window is or is not seen. */
function diagnose() {
  if (!openX()) return { x11: false };
  const stacking = longs(X.root, X.A.clientListStacking, 8192);
  const list = longs(X.root, X.A.clientList, 8192);
  const tops = children(X.root);
  const tree = treeClients();
  const describe = (win) => {
    const attrs = {};
    const ok = X.XGetWindowAttributes(X.dpy, win, attrs);
    const type = longs(win, X.A.windowType);
    return {
      id: win, pid: pidOf(win), title: titleOf(win).slice(0, 40), cls: classOf(win).cls,
      mapState: ok ? attrs.map_state : null, overrideRedirect: ok ? attrs.override_redirect : null,
      size: ok ? `${attrs.width}x${attrs.height}` : null, hasWmState: !!property(win, X.A.icccmState),
      normal: !type || !type.length || type.some((t) => t === X.A.typeNormal || t === X.A.typeDialog),
      rect: geometry(win),
    };
  };
  return {
    x11: true, ownPid, ownPids: [...ownPids],
    clientListStacking: stacking ? stacking.length : null, clientList: list ? list.length : null,
    topLevel: tops.length, treeClients: tree.length,
    active: first(longs(X.root, X.A.activeWindow)),
    tops: tops.slice(-24).map(describe),
    listed: listWindows().length,
  };
}

module.exports = {
  diagnose,
  name: 'linux', coordsArePhysical: true, permissionNote: null,
  listWindows, setOwnPids, foreground, windowTitle, minimize, activate,
  windowState, moveWindow, restore, setCursor, isMouseDown, canMoveCursor,
  readVolume, watchVolume, linkQuality, installedApps, ocr, ocrStatus,
  available: () => !!openX(),
};
