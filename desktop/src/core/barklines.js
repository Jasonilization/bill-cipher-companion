// Port of the helpers at the bottom of CharacterEngine/BarkLines.swift. The
// pools themselves are generated straight from that file (scripts/convert-swift-data.js).
const POOLS = require('../data/barklines.json');
const { DOCK_APP_REACTIONS, RARE_EASTER_EGGS } = require('./states');

const random = (lines) => (lines && lines.length ? lines[Math.floor(Math.random() * lines.length)] : '');

function resolvedRandom(lines, appName, description) {
  let line = random(lines).split('{app}').join(appName);
  if (description !== undefined) line = line.split('{description}').join(description);
  return line;
}

const PLACEHOLDER = ['...'];
const specialApp = (state) => (DOCK_APP_REACTIONS.includes(state) && POOLS[state]) || PLACEHOLDER;
const rareEvent = (state) => POOLS[state] || PLACEHOLDER;

/** The line that goes with a daily-showcase animation, if it has one. */
function showcaseLine(state) {
  if (RARE_EASTER_EGGS.includes(state)) return random(rareEvent(state));
  const pool = specialApp(state);
  if (pool === PLACEHOLDER) return null;
  // A showcase has no app to name, so prefer the lines that don't need one.
  const standalone = pool.filter((line) => !line.includes('{app}'));
  return standalone.length ? random(standalone) : random(pool).split('{app}').join('that app');
}

module.exports = { POOLS, random, resolvedRandom, specialApp, rareEvent, showcaseLine };
