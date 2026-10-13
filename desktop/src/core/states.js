// Port of Animation/BillState.swift — every state Bill can be in, with the
// same priorities, continuity rules and hold durations as the Mac app.

const ALL_STATES = [
  'idle', 'walking', 'talking', 'thinking', 'happy', 'annoyed', 'sleeping', 'gaming', 'coding',
  'channeling', 'focused', 'heatingUp', 'charging', 'surprised', 'celebrating', 'confused', 'dazed',
  'poked', 'smug', 'caneFlourish', 'powerSurge', 'zodiacVision', 'summonRitual', 'zodiacRage',
  'prismDance', 'zodiacCrimson', 'ghostPale', 'glitchForm', 'shadowHands', 'meltdown', 'trickster',
  'darkWorld', 'hollowed', 'cultLeader', 'spooked', 'scanning', 'sneaking', 'glitching', 'charged',
  'transferring', 'summoning', 'sculpting', 'kinship', 'fractaling', 'presenting', 'guilty', 'dreading',
  'grooving', 'dispatching', 'ambushed', 'stressed', 'watched', 'flinching', 'huffy', 'pushingCode',
  'browsingStore', 'dancing', 'caneTwist', 'hookCane', 'conjuring', 'tumbling', 'dashTarget',
  'grumpEyes', 'zipAround', 'rampaging', 'ritualBuildup', 'crouching', 'launching', 'rising', 'falling',
  'landingSoft', 'landingHard', 'ledgeGrabbing', 'climbingUp', 'climbingDown', 'hangingIdle',
  'edgePeek', 'running',
];

const ROAM_PHYSICS = [
  'crouching', 'launching', 'rising', 'falling', 'landingSoft', 'landingHard', 'ledgeGrabbing',
  'climbingUp', 'climbingDown', 'hangingIdle', 'edgePeek', 'running',
];

const DOCK_APP_REACTIONS = [
  'trickster', 'darkWorld', 'hollowed', 'cultLeader', 'spooked', 'scanning', 'sneaking', 'glitching',
  'charged', 'transferring', 'summoning', 'sculpting', 'kinship', 'fractaling', 'presenting', 'guilty',
  'dreading', 'grooving', 'dispatching', 'ambushed', 'stressed', 'watched', 'flinching', 'huffy',
  'pushingCode', 'browsingStore', 'dancing',
];

const PRIORITY = {
  surprised: 100, meltdown: 99, powerSurge: 98, glitchForm: 97, zodiacRage: 96, zodiacCrimson: 96,
  poked: 95, ghostPale: 94, prismDance: 93, zodiacVision: 92, shadowHands: 91, summonRitual: 90,
  ritualBuildup: 89, celebrating: 89, caneFlourish: 82, heatingUp: 80, dazed: 72, annoyed: 70,
  confused: 65, smug: 62, happy: 60, focused: 58, gaming: 50, coding: 50, channeling: 50,
  caneTwist: 85, hookCane: 85, conjuring: 85, tumbling: 85, dashTarget: 85, grumpEyes: 85,
  zipAround: 85, rampaging: 85, thinking: 45, talking: 45, charging: 40, walking: 30, sleeping: 20,
  idle: 0,
};
for (const s of DOCK_APP_REACTIONS) PRIORITY[s] = 50;
for (const s of ROAM_PHYSICS) PRIORITY[s] = 55;

const CONTINUOUS = new Set([
  'talking', 'thinking', 'sleeping', 'gaming', 'coding', 'channeling', 'heatingUp', 'charging',
  'walking', 'sneaking', 'glitching', 'pushingCode', 'browsingStore', 'rising', 'falling',
  'climbingUp', 'climbingDown', 'hangingIdle', 'running',
]);

const NO_HOLD_LIMIT = new Set([
  'sleeping', 'walking', 'running', 'rising', 'falling', 'climbingUp', 'climbingDown', 'hangingIdle',
  'talking', 'thinking',
]);

/** Seconds a continuous state may run before settling by itself; null = until told otherwise. */
function maxHoldDuration(state) {
  if (!CONTINUOUS.has(state)) return null;
  if (NO_HOLD_LIMIT.has(state)) return null;
  if (state === 'heatingUp') return 12;
  if (state === 'charging') return 10;
  return 9;
}

const ROAMING_MOTION = new Set([...ROAM_PHYSICS, 'walking']);

const RARE_EASTER_EGGS = [
  'powerSurge', 'zodiacVision', 'summonRitual', 'ghostPale', 'glitchForm', 'shadowHands', 'meltdown',
  'caneTwist', 'hookCane', 'conjuring', 'tumbling', 'dashTarget', 'grumpEyes', 'zipAround',
  'ritualBuildup', 'zodiacRage', 'prismDance', 'zodiacCrimson',
];

const NOT_SHOWCASEABLE = new Set([
  'idle', 'walking', 'running', 'crouching', 'launching', 'rising', 'falling', 'landingSoft',
  'landingHard', 'ledgeGrabbing', 'climbingUp', 'climbingDown', 'hangingIdle', 'edgePeek',
  'sleeping', 'charging', 'heatingUp', 'rampaging',
]);

module.exports = {
  ALL_STATES,
  DOCK_APP_REACTIONS,
  RARE_EASTER_EGGS,
  NOT_SHOWCASEABLE,
  priority: (s) => PRIORITY[s] ?? 0,
  isContinuous: (s) => CONTINUOUS.has(s),
  isRoamingMotion: (s) => ROAMING_MOTION.has(s),
  maxHoldDuration,
};
