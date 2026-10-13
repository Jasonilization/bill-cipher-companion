// Windows backend: everything the Mac app got from AppKit / CoreGraphics /
// Accessibility / CoreAudio, via plain Win32 through koffi (no compiler needed).
//
//   CGWindowListCopyWindowInfo        -> z-order walk + DWM extended frame bounds
//   NSWorkspace.frontmostApplication  -> GetForegroundWindow + process image
//   AX focused-window title           -> GetWindowTextW (no permission needed)
//   AX minimize-button press          -> WM_SYSCOMMAND / SC_MINIMIZE
//   CoreAudio volume + mute           -> IAudioEndpointVolume (COM)
//   CoreWLAN RSSI                     -> `netsh wlan show interfaces`
//   Vision OCR                        -> Windows.Media.Ocr (PowerShell helper)
const koffi = require('koffi');
const fs = require('fs');
const path = require('path');
const { execFile } = require('child_process');

const user32 = koffi.load('user32.dll');
const dwmapi = koffi.load('dwmapi.dll');
const kernel32 = koffi.load('kernel32.dll');

const RECT = koffi.struct('RECT', { left: 'long', top: 'long', right: 'long', bottom: 'long' });

const GetTopWindow = user32.func('GetTopWindow', 'uintptr_t', ['uintptr_t']);
const GetWindow = user32.func('GetWindow', 'uintptr_t', ['uintptr_t', 'uint32']);
const IsWindowVisible = user32.func('IsWindowVisible', 'bool', ['uintptr_t']);
const IsIconic = user32.func('IsIconic', 'bool', ['uintptr_t']);
const IsWindow = user32.func('IsWindow', 'bool', ['uintptr_t']);
const GetWindowTextW = user32.func('GetWindowTextW', 'int', ['uintptr_t', 'void *', 'int']);
const GetClassNameW = user32.func('GetClassNameW', 'int', ['uintptr_t', 'void *', 'int']);
const GetWindowLongPtrW = user32.func('GetWindowLongPtrW', 'intptr_t', ['uintptr_t', 'int']);
const GetWindowThreadProcessId = user32.func('GetWindowThreadProcessId', 'uint32', ['uintptr_t', koffi.out(koffi.pointer('uint32'))]);
const GetForegroundWindow = user32.func('GetForegroundWindow', 'uintptr_t', []);
const SetForegroundWindow = user32.func('SetForegroundWindow', 'bool', ['uintptr_t']);
const PostMessageW = user32.func('PostMessageW', 'bool', ['uintptr_t', 'uint32', 'uintptr_t', 'intptr_t']);
const GetWindowRect = user32.func('GetWindowRect', 'bool', ['uintptr_t', koffi.out(koffi.pointer(RECT))]);
const DwmGetRect = dwmapi.func('DwmGetWindowAttribute', 'long', ['uintptr_t', 'uint32', koffi.out(koffi.pointer(RECT)), 'uint32']);
const DwmGetInt = dwmapi.func('DwmGetWindowAttribute', 'long', ['uintptr_t', 'uint32', koffi.out(koffi.pointer('int')), 'uint32']);
const OpenProcess = kernel32.func('OpenProcess', 'uintptr_t', ['uint32', 'bool', 'uint32']);
const CloseHandle = kernel32.func('CloseHandle', 'bool', ['uintptr_t']);
const SetWindowPos = user32.func('SetWindowPos', 'bool', ['uintptr_t', 'uintptr_t', 'int', 'int', 'int', 'int', 'uint32']);
const ShowWindowAsync = user32.func('ShowWindowAsync', 'bool', ['uintptr_t', 'int']);
const IsZoomed = user32.func('IsZoomed', 'bool', ['uintptr_t']);
const SetCursorPos = user32.func('SetCursorPos', 'bool', ['int', 'int']);
const GetAsyncKeyState = user32.func('GetAsyncKeyState', 'short', ['int']);
const QueryFullProcessImageNameW = kernel32.func('QueryFullProcessImageNameW', 'bool', ['uintptr_t', 'uint32', 'void *', koffi.inout(koffi.pointer('uint32'))]);

const GW_HWNDNEXT = 2;
const GWL_EXSTYLE = -20;
const WS_EX_TOOLWINDOW = 0x80;
const DWMWA_EXTENDED_FRAME_BOUNDS = 9;
const DWMWA_CLOAKED = 14;
const WM_SYSCOMMAND = 0x0112;
const SC_MINIMIZE = 0xF020;
const PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
const SWP_MOVE_ONLY = 0x0001 | 0x0004 | 0x0010 | 0x4000; // NOSIZE | NOZORDER | NOACTIVATE | ASYNCWINDOWPOS
const SW_SHOWNOACTIVATE = 4;

const SHELL_CLASSES = new Set(['Progman', 'WorkerW', 'Shell_TrayWnd', 'Shell_SecondaryTrayWnd', 'Windows.UI.Core.CoreWindow', 'XamlExplorerHostIslandWindow']);
const ownPid = process.pid;
const SHELL_HOSTS = new Set(['startmenuexperiencehost', 'searchhost', 'searchapp', 'searchui', 'shellexperiencehost', 'shellhost', 'lockapp', 'textinputhost']);
const SWITCHER_CLASSES = new Set(['MultitaskingViewFrame', 'TaskSwitcherWnd', 'TaskListThumbnailWnd', 'ForegroundStaging', 'NotifyIconOverflowWindow', 'TopLevelWindowForOverflowXamlIsland']);
const EXPLORER_WINDOW_CLASSES = new Set(['CabinetWClass', 'ExploreWClass']);
const num = (v) => (typeof v === 'bigint' ? Number(v) : v);

const textBuffer = Buffer.alloc(1024);
function windowText(hwnd) {
  const n = GetWindowTextW(hwnd, textBuffer, 511);
  return n > 0 ? textBuffer.toString('utf16le', 0, n * 2) : '';
}
function className(hwnd) {
  const n = GetClassNameW(hwnd, textBuffer, 255);
  return n > 0 ? textBuffer.toString('utf16le', 0, n * 2) : '';
}
function pidOf(hwnd) {
  const out = [0];
  GetWindowThreadProcessId(hwnd, out);
  return out[0];
}
function frameRect(hwnd) {
  const r = {};
  // The extended frame bounds exclude the invisible resize border, so this is
  // the edge the user actually sees — the one Bill should stand on.
  if (DwmGetRect(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, r, 16) !== 0 && !GetWindowRect(hwnd, r)) return null;
  return { x: r.left, y: r.top, width: r.right - r.left, height: r.bottom - r.top };
}
function isCloaked(hwnd) {
  const out = [0];
  return DwmGetInt(hwnd, DWMWA_CLOAKED, out, 4) === 0 && out[0] !== 0;
}

/** Every real, visible top-level window, front-to-back, in physical pixels. */
function listWindows() {
  const result = [];
  let hwnd = GetTopWindow(0);
  let guard = 0;
  while (hwnd && guard++ < 2000) {
    const id = num(hwnd);
    if (IsWindowVisible(hwnd) && !IsIconic(hwnd) && !isCloaked(hwnd)) {
      const exStyle = num(GetWindowLongPtrW(hwnd, GWL_EXSTYLE));
      const pid = pidOf(hwnd);
      if (!(exStyle & WS_EX_TOOLWINDOW) && pid !== ownPid && !ownPids.has(pid)) {
        const title = windowText(hwnd);
        if (title && !SHELL_CLASSES.has(className(hwnd))) {
          const rect = frameRect(hwnd);
          if (rect) result.push({ id, pid, rect, title });
        }
      }
    }
    hwnd = GetWindow(hwnd, GW_HWNDNEXT);
  }
  return result;
}

/** Electron runs several processes; none of their windows are furniture. */
const ownPids = new Set();
function setOwnPids(pids) { ownPids.clear(); for (const p of pids) ownPids.add(p); }

// ---------------------------------------------------------- foreground app
const exeCache = new Map();
function exePath(pid) {
  if (exeCache.has(pid)) return exeCache.get(pid);
  let result = null;
  const handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
  if (handle) {
    const buf = Buffer.alloc(2048);
    const size = [1023];
    if (QueryFullProcessImageNameW(handle, 0, buf, size)) result = buf.toString('utf16le', 0, size[0] * 2);
    CloseHandle(handle);
  }
  if (exeCache.size > 300) exeCache.clear();
  exeCache.set(pid, result);
  return result;
}

let versionApi = null;
function loadVersionApi() {
  if (versionApi !== null) return versionApi;
  try {
    const lib = koffi.load('version.dll');
    versionApi = {
      size: lib.func('GetFileVersionInfoSizeW', 'uint32', ['str16', koffi.out(koffi.pointer('uint32'))]),
      info: lib.func('GetFileVersionInfoW', 'bool', ['str16', 'uint32', 'uint32', 'void *']),
      query: lib.func('VerQueryValueW', 'bool', ['void *', 'str16', koffi.out(koffi.pointer('void *')), koffi.out(koffi.pointer('uint32'))]),
    };
  } catch { versionApi = false; }
  return versionApi;
}

const PRETTY = {
  code: 'Visual Studio Code', explorer: 'File Explorer', msedge: 'Microsoft Edge', chrome: 'Google Chrome',
  winword: 'Word', excel: 'Excel', powerpnt: 'PowerPoint', windowsterminal: 'Terminal', cmd: 'Command Prompt',
  powershell: 'PowerShell', pwsh: 'PowerShell', devenv: 'Visual Studio', taskmgr: 'Task Manager', mspaint: 'Paint',
};
const descriptionCache = new Map();
/** The exe's FileDescription ("Google Chrome"), which is what the Start menu shows. */
function fileDescription(file) {
  if (descriptionCache.has(file)) return descriptionCache.get(file);
  let result = null;
  const api = loadVersionApi();
  if (api) {
    try {
      const size = api.size(file, [0]);
      if (size > 0) {
        const block = Buffer.alloc(size);
        if (api.info(file, 0, size, block)) {
          const ptr = [null]; const len = [0];
          let lang = '040904b0';
          if (api.query(block, '\\VarFileInfo\\Translation', ptr, len) && len[0] >= 4) {
            const pair = koffi.decode(ptr[0], koffi.array('uint16', 2));
            lang = pair[0].toString(16).padStart(4, '0') + pair[1].toString(16).padStart(4, '0');
          }
          if (api.query(block, `\\StringFileInfo\\${lang}\\FileDescription`, ptr, len) && len[0] > 1) {
            const chars = koffi.decode(ptr[0], koffi.array('uint16', len[0] - 1));
            result = String.fromCharCode(...chars).trim() || null;
          }
        }
      }
    } catch { result = null; }
  }
  descriptionCache.set(file, result);
  return result;
}

function describeWindow(hwnd) {
  const pid = pidOf(hwnd);
  const title = windowText(hwnd);
  const exe = exePath(pid);
  const base = exe ? path.basename(exe).toLowerCase() : `pid-${pid}`;
  const stem = base.replace(/\.exe$/, '');
  let id = base; let name;
  if (stem === 'applicationframehost' && title) {
    // Store apps all share one host process; the title is the app.
    id = `uwp:${title.toLowerCase()}`; name = title;
  } else {
    name = PRETTY[stem] || (exe && fileDescription(exe)) || stem.replace(/[-_]/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase());
  }
  return { windowId: num(hwnd), pid, title, exe, id, name, desktopCategories: null };
}

function foreground() {
  const hwnd = GetForegroundWindow();
  if (!hwnd || !IsWindow(hwnd)) return null;
  const pid = pidOf(hwnd);
  if (pid === ownPid || ownPids.has(pid)) return { own: true, windowId: num(hwnd), pid };
  const cls = className(hwnd);
  if (SHELL_CLASSES.has(cls) && cls !== 'Windows.UI.Core.CoreWindow') return null;
  if (SWITCHER_CLASSES.has(cls)) return null;
  const described = describeWindow(hwnd);
  // The Start menu, search, Alt-Tab and the taskbar's fly-outs take focus
  // without being apps anyone "opened"; of Explorer, only real folder windows count.
  const stem = described.exe ? path.basename(described.exe).toLowerCase().replace(/.exe$/, '') : '';
  if (SHELL_HOSTS.has(stem)) return null;
  if (stem === 'explorer' && !EXPLORER_WINDOW_CLASSES.has(cls)) return null;
  return described;
}

function windowTitle(windowId) { return windowId && IsWindow(windowId) ? windowText(windowId) : null; }
function minimize(windowId) { return !!(windowId && IsWindow(windowId) && PostMessageW(windowId, WM_SYSCOMMAND, SC_MINIMIZE, 0)); }
function activate(windowId) { return !!(windowId && IsWindow(windowId) && SetForegroundWindow(windowId)); }

// ------------------------------------------------- moving things on screen
/** Where a window is (physical pixels) and whether it can be pushed around. */
function windowState(windowId) {
  if (!windowId || !IsWindow(windowId)) return null;
  const r = {};
  if (!GetWindowRect(windowId, r)) return null;
  const frame = frameRect(windowId);
  return {
    x: r.left, y: r.top, width: r.right - r.left, height: r.bottom - r.top,
    frame: frame || { x: r.left, y: r.top, width: r.right - r.left, height: r.bottom - r.top },
    minimized: !!IsIconic(windowId), maximized: !!IsZoomed(windowId),
  };
}

/**
 * Moves a window without resizing, raising or focusing it. Asynchronous on
 * the far side, so a hung app cannot hang Bill; refused by Windows for
 * elevated apps, which simply reads as "it won't budge".
 */
function moveWindow(windowId, x, y) {
  if (!windowId || !IsWindow(windowId) || IsIconic(windowId) || IsZoomed(windowId)) return false;
  return !!SetWindowPos(windowId, 0, Math.round(x), Math.round(y), 0, 0, SWP_MOVE_ONLY);
}

/** Brings a minimized window back where it was, without stealing focus. */
function restore(windowId) {
  if (!windowId || !IsWindow(windowId)) return false;
  if (!IsIconic(windowId)) return true;
  return !!ShowWindowAsync(windowId, SW_SHOWNOACTIVATE);
}

function setCursor(x, y) { return !!SetCursorPos(Math.round(x), Math.round(y)); }
/** Any mouse button held: a drag is in progress and the pointer is not Bill's to touch. */
function isMouseDown() { return [1, 2, 4].some((key) => (GetAsyncKeyState(key) & 0x8000) !== 0); }

// ----------------------------------------------------------------- volume
// IAudioEndpointVolume through raw COM vtables. The default endpoint is
// re-resolved on every read, so plugging in headphones is handled for free.
let com = null;
function loadCom() {
  if (com !== null) return com;
  try {
    const ole32 = koffi.load('ole32.dll');
    const GUID = koffi.struct('GUID', { Data1: 'uint32', Data2: 'uint16', Data3: 'uint16', Data4: koffi.array('uint8', 8) });
    const guid = (s) => {
      const h = s.replace(/[{}-]/g, '');
      return {
        Data1: parseInt(h.slice(0, 8), 16), Data2: parseInt(h.slice(8, 12), 16), Data3: parseInt(h.slice(12, 16), 16),
        Data4: h.slice(16).match(/../g).map((b) => parseInt(b, 16)),
      };
    };
    const CoInitializeEx = ole32.func('CoInitializeEx', 'long', ['void *', 'uint32']);
    const CoCreateInstance = ole32.func('CoCreateInstance', 'long', [koffi.pointer(GUID), 'void *', 'uint32', koffi.pointer(GUID), koffi.out(koffi.pointer('void *'))]);
    CoInitializeEx(null, 2);
    const out = [null];
    const hr = CoCreateInstance(guid('BCDE0395-E52F-467C-8E3D-C4579291692E'), null, 23, guid('A95664D2-9614-4F35-A746-DE8DB63617E6'), out);
    if (hr !== 0 || !out[0]) throw new Error(`CoCreateInstance 0x${(hr >>> 0).toString(16)}`);
    const method = (obj, index) => koffi.decode(koffi.decode(obj, 'void *'), index * koffi.sizeof('void *'), 'void *');
    com = {
      GUID, enumerator: out[0], method,
      iidVolume: guid('5CDF2C82-841E-4546-9722-0CF74078229A'),
      Release: koffi.proto('uint32 BillRelease(void *self)'),
      GetDefault: koffi.proto('long BillGetDefault(void *self, int flow, int role, _Out_ void **device)'),
      Activate: koffi.proto('long BillActivate(void *self, GUID *iid, uint32 ctx, void *params, _Out_ void **out)'),
      GetScalar: koffi.proto('long BillGetScalar(void *self, _Out_ float *level)'),
      GetMute: koffi.proto('long BillGetMute(void *self, _Out_ int *muted)'),
    };
  } catch (e) {
    console.error('volume: COM unavailable —', e.message);
    com = false;
  }
  return com;
}

function readVolumeSync() {
  const c = loadCom();
  if (!c) return null;
  let device = null; let endpoint = null;
  try {
    const dev = [null];
    if (koffi.call(c.method(c.enumerator, 4), c.GetDefault, c.enumerator, 0, 1, dev) !== 0 || !dev[0]) return null;
    device = dev[0];
    const ep = [null];
    if (koffi.call(c.method(device, 3), c.Activate, device, c.iidVolume, 23, null, ep) !== 0 || !ep[0]) return null;
    endpoint = ep[0];
    const level = [0]; const muted = [0];
    const okLevel = koffi.call(c.method(endpoint, 9), c.GetScalar, endpoint, level) === 0;
    koffi.call(c.method(endpoint, 15), c.GetMute, endpoint, muted);
    return { percent: okLevel ? Math.round(level[0] * 100) : null, muted: muted[0] !== 0 };
  } catch { return null; } finally {
    try { if (endpoint) koffi.call(c.method(endpoint, 2), c.Release, endpoint); } catch { /* ignore */ }
    try { if (device) koffi.call(c.method(device, 2), c.Release, device); } catch { /* ignore */ }
  }
}

async function readVolume() { return readVolumeSync(); }

/** Calls back with (percent|null, muted) whenever either changes. Returns a stop function. */
function watchVolume(onChange) {
  let last = readVolumeSync();
  const timer = setInterval(() => {
    const now = readVolumeSync();
    if (!now) return;
    if (!last || now.percent !== last.percent || now.muted !== last.muted) { last = now; onChange(now.percent, now.muted); }
  }, 1500);
  return () => clearInterval(timer);
}

// ------------------------------------------------------------------ wi-fi
function run(file, args, timeout = 8000) {
  return new Promise((resolve) => {
    execFile(file, args, { timeout, windowsHide: true, maxBuffer: 4 * 1024 * 1024 }, (err, stdout) => resolve(err ? null : String(stdout)));
  });
}

/** { type: 'wifi', dbm } | { type: 'wired' } */
async function linkQuality() {
  const out = await run('netsh', ['wlan', 'show', 'interfaces']);
  const signal = out && out.match(/^\s*Signal\s*:\s*(\d+)\s*%/im);
  if (!signal) return { type: 'wired' };
  // Windows reports quality 0-100; the documented mapping to RSSI is linear over -100..-50 dBm.
  return { type: 'wifi', dbm: Number(signal[1]) / 2 - 100 };
}

// --------------------------------------------------------- installed apps
const SKIP_SHORTCUT = /uninstall|readme|read me|help|documentation|license|website|release notes|manual|changelog|\bsetup\b|report a|safe mode|repair|troubleshoot/i;

/** Start-menu shortcuts — the same surface the user actually launches from. */
async function installedApps(shell) {
  const roots = [
    path.join(process.env.ProgramData || 'C:\\ProgramData', 'Microsoft', 'Windows', 'Start Menu', 'Programs'),
    path.join(process.env.APPDATA || '', 'Microsoft', 'Windows', 'Start Menu', 'Programs'),
  ];
  const seen = new Set(); const result = [];
  const walk = async (dir, depth) => {
    let entries;
    try { entries = await fs.promises.readdir(dir, { withFileTypes: true }); } catch { return; }
    for (const entry of entries) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) { if (depth < 3) await walk(full, depth + 1); continue; }
      if (!entry.name.toLowerCase().endsWith('.lnk')) continue;
      const name = entry.name.slice(0, -4);
      if (SKIP_SHORTCUT.test(name)) continue;
      let target = null;
      try { target = shell.readShortcutLink(full).target; } catch { continue; }
      if (!target || !target.toLowerCase().endsWith('.exe')) continue;
      const id = path.basename(target).toLowerCase();
      if (seen.has(id)) continue;
      seen.add(id);
      result.push({ id, name });
    }
  };
  for (const root of roots) await walk(root, 0);
  return result;
}

// -------------------------------------------------------------------- OCR
const helperDir = path.join(__dirname, 'helpers').replace('app.asar', 'app.asar.unpacked');
const ocrStatus = { available: true, detail: 'Windows built-in OCR (Windows.Media.Ocr)' };
async function ocr(pngPath) {
  const out = await run('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', path.join(helperDir, 'ocr.ps1'), pngPath], 30000);
  const text = out && out.trim();
  return text || null;
}

module.exports = {
  name: 'win32', coordsArePhysical: true, permissionNote: null,
  listWindows, setOwnPids, foreground, windowTitle, minimize, activate,
  windowState, moveWindow, restore, setCursor, isMouseDown, canMoveCursor: () => true,
  readVolume, watchVolume, linkQuality, installedApps, ocr, ocrStatus,
};
