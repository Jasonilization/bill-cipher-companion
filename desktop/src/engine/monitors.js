// Port of SystemMonitor/*.swift: app activity, power, network, CPU, idle,
// volume and the half-hour clock, normalised into the same events the
// reaction router consumes on the Mac.
const os = require('os');
const { net, powerMonitor } = require('electron');
const platform = require('../platform');
const { identify } = require('../core/apps');
const { timeOfDay } = require('../core/dialogue');

const CPU_HOT_THRESHOLD = 75;
const IDLE_THRESHOLD = 300;
const BATTERY_STEP = 5;
const BATTERY_HYSTERESIS = 2;
const VOLUME_MARKS = [0, 25, 50, 75, 100];
const VOLUME_MARK_TOLERANCE = 4;
const DWELL_TIME = 25 * 1000;
const RSSI_HYSTERESIS = 4;
const TIER_RANK = { offline: 0, poor: 1, good: 2, excellent: 3 };

const bucket = (percent) => Math.floor(Math.min(100, Math.max(0, percent)) / BATTERY_STEP) * BATTERY_STEP;
const nearestMark = (percent) => VOLUME_MARKS.reduce((best, m) => (Math.abs(m - percent) < Math.abs(best - percent) ? m : best));

/** When the next :00 or :30 lands. */
function nextHalfHour(from = new Date()) {
  const next = new Date(from);
  next.setSeconds(0, 0);
  if (from.getMinutes() < 30) next.setMinutes(30);
  else { next.setMinutes(0); next.setHours(next.getHours() + 1); }
  return next;
}

class SystemMonitor {
  constructor() {
    this.onEvent = null;
    /** Fires on every foreground-app change, before the event — the roaming world is stale. */
    this.onForegroundChanged = null;
    this.timers = [];
    this.stopVolume = null;

    this.lastAppId = null;
    this.lastPowerState = null;
    this.lastBatteryBucket = null;
    this.lastNetworkConnected = null;
    this.wasCPUHot = false;
    this.wasIdle = false;
    this.lastVolumeMark = null;
    this.lastMuted = null;
    this.previousCPU = null;
    this.lastTimeOfDay = null;
    this.clockTimer = null;

    // Network quality
    this.isConnected = true;
    this.link = { type: 'wired' };
    this.reportedQuality = null;
    this.pendingQuality = null;
    this.dwellTimer = null;
    this.wiredStreak = 0;
    this.linkTimer = null;
  }

  emit(event) { if (this.onEvent) { try { this.onEvent(event); } catch (e) { console.error('reaction failed:', e); } } }
  every(ms, fn) { const t = setInterval(fn, ms); this.timers.push(t); return t; }

  start() {
    // App activity: the Mac gets a notification; here the foreground window is polled.
    this.every(750, () => this.sampleForeground());
    this.every(10000, () => platform.refreshOwnPids());
    platform.refreshOwnPids();

    // Network reachability + link quality.
    this.every(3000, () => this.sampleNetwork());
    this.sampleNetwork();
    this.sampleLink();

    // CPU + idle.
    this.every(10000, () => this.sampleCPU());
    this.every(30000, () => this.sampleIdle());
    this.sampleCPU();
    this.sampleIdle();

    // Volume: baseline first so launching at 50% doesn't announce 50%.
    platform.readVolume().then((v) => {
      if (v && v.percent !== null) this.lastVolumeMark = nearestMark(v.percent);
      if (v) this.lastMuted = v.muted;
    });
    this.stopVolume = platform.watchVolume((percent, muted) => this.handleVolumeChange(percent, muted));

    // Clock.
    this.lastTimeOfDay = timeOfDay();
    this.armClock();
    powerMonitor.on('resume', this.onResume = () => this.armClock());
  }

  stop() {
    for (const t of this.timers) clearInterval(t);
    this.timers = [];
    clearTimeout(this.clockTimer); clearTimeout(this.dwellTimer); clearTimeout(this.linkTimer);
    if (this.stopVolume) this.stopVolume();
    if (this.onResume) powerMonitor.removeListener('resume', this.onResume);
  }

  // ------------------------------------------------------------ app activity
  sampleForeground() {
    const fg = platform.foreground();
    if (!fg || fg.own) return; // the desktop, the taskbar, or Bill himself: nothing changed
    const app = identify(fg);
    this.current = app;
    if (app.id === this.lastAppId) return;
    this.lastAppId = app.id;
    if (this.onForegroundChanged) this.onForegroundChanged(app);
    this.emit({ type: 'appActivated', app });
  }

  // ------------------------------------------------------------------ power
  /** Fed from the renderer's Battery Status API: { charging, level 0..1 }. */
  handleBattery({ charging, level }) {
    const state = { isCharging: !!charging, percentage: Number.isFinite(level) ? Math.round(level * 100) : null };
    const isLow = (s) => !s.isCharging && (s.percentage === null ? 100 : s.percentage) <= 20;
    const previous = this.lastPowerState;
    this.lastPowerState = state;
    if (!previous) {
      // First read at launch only seeds the tracking — no event.
      this.lastBatteryBucket = state.percentage === null ? null : bucket(state.percentage);
      return;
    }
    if (state.isCharging !== previous.isCharging) {
      this.emit({ type: state.isCharging ? 'batteryCharging' : 'batteryUnplugged' });
      this.lastBatteryBucket = state.percentage === null ? null : bucket(state.percentage);
      return;
    }
    if (isLow(state) && !isLow(previous)) this.emit({ type: 'batteryLow', percent: state.percentage || 0 });
    if (state.percentage === null) return;
    const b = bucket(state.percentage);
    if (this.lastBatteryBucket === null) { this.lastBatteryBucket = b; return; }
    if (b === this.lastBatteryBucket) return;
    // Hysteresis: a reading wobbling on a boundary must not fire twice.
    const distance = Math.abs(state.percentage - b);
    if (distance > BATTERY_HYSTERESIS && Math.abs(b - this.lastBatteryBucket) < BATTERY_STEP) return;
    this.lastBatteryBucket = b;
    this.emit({ type: 'batteryLevel', percent: b, isCharging: state.isCharging });
  }

  // ----------------------------------------------------------------- volume
  handleVolumeChange(percent, muted) {
    if (this.lastMuted !== null && this.lastMuted !== muted) this.emit({ type: 'volumeMuteChanged', isMuted: muted });
    this.lastMuted = muted;
    if (percent === null || percent === undefined) return;
    const mark = nearestMark(percent);
    if (Math.abs(percent - mark) > VOLUME_MARK_TOLERANCE) return;
    if (mark === this.lastVolumeMark) return;
    this.lastVolumeMark = mark;
    this.emit({ type: 'volumeMark', percent: mark });
  }

  // ---------------------------------------------------------------- network
  sampleNetwork() {
    let connected = true;
    try { connected = net.isOnline(); } catch { return; }
    const changed = connected !== this.isConnected;
    this.isConnected = connected;
    if (this.lastNetworkConnected === null) this.lastNetworkConnected = connected; // first read: no event
    else if (this.lastNetworkConnected !== connected) {
      this.lastNetworkConnected = connected;
      this.emit({ type: connected ? 'networkRestored' : 'networkLost' });
    }
    if (changed) this.sampleLink();
    this.evaluateQuality();
  }

  sampleLink() {
    clearTimeout(this.linkTimer);
    platform.linkQuality().then((link) => {
      this.link = link || { type: 'wired' };
      this.wiredStreak = this.link.type === 'wired' ? this.wiredStreak + 1 : 0;
      this.evaluateQuality();
      // A machine with no Wi-Fi radio does not need asking twice a minute.
      this.linkTimer = setTimeout(() => this.sampleLink(), this.wiredStreak >= 3 ? 5 * 60 * 1000 : 30 * 1000);
    });
  }

  currentQuality() {
    if (!this.isConnected) return 'offline';
    if (this.link.type === 'wired') return 'excellent';
    const rssi = this.link.dbm;
    if (!Number.isFinite(rssi)) return 'good';
    // Climbing a tier needs a few dB of margin so a link on a boundary doesn't flap.
    const bump = this.reportedQuality && TIER_RANK[this.reportedQuality] > 0 ? RSSI_HYSTERESIS : 0;
    if (rssi >= -60 + bump) return 'excellent';
    if (rssi >= -72 + bump && rssi < -60) return 'good';
    return 'poor';
  }

  evaluateQuality() {
    const quality = this.currentQuality();
    if (quality === this.reportedQuality) {
      this.pendingQuality = null;
      clearTimeout(this.dwellTimer); this.dwellTimer = null;
      return;
    }
    if (quality === 'offline') {
      clearTimeout(this.dwellTimer); this.dwellTimer = null;
      this.pendingQuality = null;
      this.reportedQuality = quality;
      this.emit({ type: 'networkQualityChanged', quality });
      return;
    }
    if (quality === this.pendingQuality) return;
    // A new tier must hold for the dwell time before Bill mentions it.
    this.pendingQuality = quality;
    clearTimeout(this.dwellTimer);
    this.dwellTimer = setTimeout(() => this.commitPendingQuality(), DWELL_TIME);
  }

  commitPendingQuality() {
    this.dwellTimer = null;
    const pending = this.pendingQuality;
    if (!pending || pending === this.reportedQuality) return;
    if (this.currentQuality() !== pending) { this.pendingQuality = null; return; }
    const isFirst = this.reportedQuality === null;
    this.reportedQuality = pending;
    this.pendingQuality = null;
    if (!isFirst) this.emit({ type: 'networkQualityChanged', quality: pending });
  }

  // ------------------------------------------------------------- cpu + idle
  sampleCPU() {
    const totals = { busy: 0, all: 0 };
    for (const cpu of os.cpus()) {
      const t = cpu.times;
      totals.busy += t.user + t.sys + t.nice + (t.irq || 0);
      totals.all += t.user + t.sys + t.nice + (t.irq || 0) + t.idle;
    }
    const previous = this.previousCPU;
    this.previousCPU = totals;
    if (!previous) return;
    const all = totals.all - previous.all;
    if (all <= 0) return;
    const percent = (totals.busy - previous.busy) / all * 100;
    const isHot = percent >= CPU_HOT_THRESHOLD;
    if (isHot === this.wasCPUHot) return;
    this.wasCPUHot = isHot;
    this.emit({ type: isHot ? 'cpuHot' : 'cpuNormal' });
  }

  sampleIdle() {
    let seconds = 0;
    try { seconds = powerMonitor.getSystemIdleTime(); } catch { return; }
    const isIdle = seconds >= IDLE_THRESHOLD;
    if (isIdle === this.wasIdle) return;
    this.wasIdle = isIdle;
    this.emit({ type: isIdle ? 'userIdle' : 'userReturned' });
  }

  // ------------------------------------------------------------------ clock
  armClock() {
    clearTimeout(this.clockTimer);
    const delay = Math.max(1000, nextHalfHour().getTime() - Date.now());
    this.clockTimer = setTimeout(() => this.fireClock(), delay);
  }

  fireClock() {
    try {
      const now = new Date();
      const hour = now.getHours(); const minute = now.getMinutes();
      // Timers can land a hair early or late; snap to the boundary that was meant.
      if (minute >= 55) this.emit({ type: 'halfHour', hour: (hour + 1) % 24, minute: 0 });
      else this.emit({ type: 'halfHour', hour, minute: minute >= 30 ? 30 : 0 });
      const tod = timeOfDay(now);
      if (tod !== this.lastTimeOfDay) {
        this.lastTimeOfDay = tod;
        this.emit({ type: 'timeOfDayChanged', timeOfDay: tod });
      }
    } finally {
      this.armClock();
    }
  }
}

module.exports = { SystemMonitor, nextHalfHour, nearestMark, bucket };
