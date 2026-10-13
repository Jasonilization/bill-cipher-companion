// Port of SystemMonitor/WeatherMonitor.swift. Keyless: an IP geolocation
// lookup, then Open-Meteo for the current conditions and a 15-minute nowcast.
const { net } = require('electron');

const FETCH_INTERVAL = 5 * 60 * 1000;
const FAILURE_LINE = "THE WEATHER PULL FAILED. THE SKY ISN'T RESPONDING. CHECK YOUR CONNECTION — OR YOUR REALITY.";

function conditionFor(code) {
  if (code === 0) return 'clear';
  if (code >= 1 && code <= 3) return 'cloudy';
  if (code === 45 || code === 48) return 'fog';
  if ((code >= 51 && code <= 67) || (code >= 80 && code <= 82)) return 'rain';
  if ((code >= 71 && code <= 77) || code === 85 || code === 86) return 'snow';
  if (code >= 95 && code <= 99) return 'thunder';
  return 'other';
}

/** The hourly code lags; the nowcast knows whether it is raining right now. */
function resolveCondition(wmoCode, nowcast) {
  let condition = conditionFor(wmoCode);
  const current = (nowcast && nowcast[0]) || 0;
  const next = (nowcast && nowcast[1]) || 0;
  // 0.05mm: drizzle counts, condensation noise doesn't.
  if (current > 0.05) {
    if (condition !== 'thunder' && condition !== 'snow') condition = 'rain';
  } else if (condition === 'rain' && next <= 0.05) {
    condition = 'cloudy';
  }
  return condition;
}

async function getJSON(url) {
  const response = await net.fetch(url, { signal: AbortSignal.timeout(10000) });
  if (response.status !== 200) throw new Error(`HTTP ${response.status}`);
  return response.json();
}

async function pull() {
  try {
    const geo = await getJSON('https://get.geojs.io/v1/ip/geo.json');
    const latitude = Number(geo.latitude); const longitude = Number(geo.longitude);
    if (!Number.isFinite(latitude) || !Number.isFinite(longitude)) return null;
    // Rounded coordinates: ~11km precision keeps the request boring.
    const lat = Math.round(latitude * 100) / 100; const lon = Math.round(longitude * 100) / 100;
    const data = await getJSON(`https://api.open-meteo.com/v1/forecast?latitude=${lat}&longitude=${lon}&current=temperature_2m,weather_code,is_day&minutely_15=precipitation`);
    if (!data.current || !Number.isFinite(data.current.temperature_2m)) return null;
    return {
      temperatureC: data.current.temperature_2m,
      condition: resolveCondition(data.current.weather_code, data.minutely_15 && data.minutely_15.precipitation),
      isDay: data.current.is_day === 1,
      city: geo.city || null,
    };
  } catch {
    return null;
  }
}

const DESCRIPTIONS = {
  cloudy: 'overcast', fog: 'foggy', rain: 'raining', snow: 'snowing',
  thunder: 'storming — thunder and all', other: 'doing something unclassifiable',
};

/** One line of context for chat and generated dialogue. */
function contextBlurb(snapshot) {
  if (!snapshot) return null;
  const sky = snapshot.condition === 'clear' ? (snapshot.isDay ? 'clear skies' : 'a clear night sky') : DESCRIPTIONS[snapshot.condition];
  const place = snapshot.city ? `in ${snapshot.city}, ` : '';
  return `${place}the weather is ${sky}, ${Math.round(snapshot.temperatureC)}°C`;
}

class WeatherMonitor {
  constructor(prefs) {
    this.prefs = prefs;
    this.onReport = null;
    this.onFetchError = null;
    this.latest = null;
    this.timer = null; this.firstPull = null;
    this.lastAnnouncedCondition = null;
    this.lastAnnouncedAt = 0;
    this.hasAnnouncedFirstPull = false;
    this.isTestForced = false;
  }

  start() {
    this.stop();
    // First pull shortly after launch — off the launch critical path.
    this.firstPull = setTimeout(() => this.fetch(), 5000);
    this.timer = setInterval(() => this.fetch(), FETCH_INTERVAL);
  }
  stop() { clearInterval(this.timer); clearTimeout(this.firstPull); this.timer = null; }

  testNow() { this.isTestForced = true; this.fetch(); }

  get blurb() { return this.prefs.get('weatherEnabled') ? contextBlurb(this.latest) : null; }

  async fetch() {
    const forced = this.isTestForced;
    if (!forced && !this.prefs.get('weatherEnabled')) return;
    const snapshot = await pull();
    if (!snapshot) {
      // The test path tells the user what went wrong rather than staying silent.
      this.isTestForced = false;
      if (this.onFetchError) this.onFetchError(FAILURE_LINE);
      return;
    }
    this.latest = snapshot;
    const reason = this.reportReason(snapshot, forced);
    if (!reason) return;
    this.lastAnnouncedCondition = snapshot.condition;
    this.lastAnnouncedAt = Date.now();
    if (this.onReport) this.onReport(snapshot, reason);
  }

  reportReason(snapshot, forced) {
    if (forced) { this.isTestForced = false; return 'forcedTest'; }
    if (!this.hasAnnouncedFirstPull) { this.hasAnnouncedFirstPull = true; return 'firstPull'; }
    if (snapshot.condition !== this.lastAnnouncedCondition) return 'conditionChange';
    const minutes = this.prefs.get('weatherAnnounceMinutes');
    if (!(minutes > 0)) return null;
    if (this.lastAnnouncedAt && Date.now() - this.lastAnnouncedAt < minutes * 60 * 1000) return null;
    return 'periodic';
  }
}

module.exports = { WeatherMonitor, contextBlurb, resolveCondition, conditionFor, pull, FAILURE_LINE };
