// Port of Animation/BillSpriteCatalog.swift + AnimationClipLibrary.swift.
// A clip is plain data so the main process can time it and the renderer can
// draw it from the very same description.

/** group name -> [frame count, anchorShift in sprite pixels (positive = right)] */
const GROUPS = {
  idle: [7], walk: [6], annoyed: [6], happy: [2], confused: [4], heating: [7], charging: [1],
  surprised: [3], poked: [4], dazed: [2], sleeping: [1], thinking: [4], coding: [2], talking: [3],
  smug: [2], snap: [3], focused: [4], channeling: [9, 3], celebrating: [5], curious: [4], cane: [8],
  powersurge: [4], powersurgeclose: [1], portalring: [8], zodiac: [8], summonritual: [4],
  zodiacrage: [10, 4], prismdance: [5], zodiaccrimson: [6], summonbuild: [3, -2], summonhold: [1, -2],
  ghost: [8], glitch: [4], shadowa: [5], shadowb: [4], meltdown: [8], trickster: [8], darkworld: [9],
  hollowed: [11], cultleader: [8], spooked: [5], scanning: [8, 10], sneaking: [6], glitching: [4],
  charged: [6], transferring: [12, 6], summoning: [8, 1], sculpting: [14], kinship: [5],
  fractaling: [3], presenting: [3], guilty: [3], dreading: [4], grooving: [3], dispatching: [4, -3],
  ambushed: [8], stressed: [7], watched: [5], flinching: [3], huffy: [6], pushingcode: [6],
  browsingstore: [3], dancing: [7], canetwist: [8], hookcane: [5], conjuring: [18, 1], tumbling: [4],
  dashtarget: [4], grumpeyes: [6], ziparound: [11], rampaging: [10],
};

/** Frames are `[file, anchorShift]` pairs. */
function frames(group) {
  const [count, shift = 0] = GROUPS[group];
  const out = [];
  for (let i = 1; i <= count; i++) out.push([`bill_${group}_${String(i).padStart(2, '0')}.png`, shift]);
  return out;
}

const F = new Proxy({}, { get: (_, group) => frames(group) });

function pingpong(fr, cycles = 1) {
  if (fr.length <= 1) return fr;
  const one = fr.concat(fr.slice(0, -1).reverse());
  let out = one;
  for (let i = 1; i < cycles; i++) out = out.concat(one.slice(1));
  return out;
}
function pingpongLoop(fr) {
  if (fr.length <= 2) return fr;
  return fr.concat(fr.slice(1, -1).reverse());
}
function holdLast(fr, extra) {
  if (!fr.length) return fr;
  return fr.concat(Array(extra).fill(fr[fr.length - 1]));
}
const rev = (fr) => fr.slice().reverse();

/** keyframe: [duration, dx, dy, rotation, timing]; dy is positive-up, rotation in radians (CCW). */
const k = (duration, { dx = 0, dy = 0, rot = 0, timing = 'easeInEaseOut' } = {}) => ({ duration, dx, dy, rot, timing });

function clip(textures, frameDuration = 0.12, loop = 'once', transform = []) {
  return { textures, frameDuration, loop, transform };
}

const FX = {
  heatingUp: 'steam', sleeping: 'zzz', celebrating: 'confettiAndSparkle', happy: 'sparkle',
  smug: 'sparkle', caneFlourish: 'sparkle', meltdown: 'sparkle', powerSurge: 'sparkle',
  zodiacVision: 'sparkle', summonRitual: 'sparkle', ritualBuildup: 'sparkle',
};

function buildClips() {
  const c = {};
  const held = (group, extra, d) => clip(holdLast(F[group], extra), d);
  const pp = (group, d) => clip(pingpong(F[group]), d);
  const loop = (group, d) => clip(pingpongLoop(F[group]), d, 'loop');

  c.idle = clip(pingpongLoop(F.idle), 0.15, 'loop', [k(1.4, { dy: -5 }), k(1.4, { dy: 0 })]);
  c.walking = clip(F.walk, 0.16, 'loop', [k(0.32, { dy: 3 }), k(0.32, { dy: 0 })]);
  c.talking = loop('talking', 0.15);
  c.thinking = loop('thinking', 0.35);
  c.happy = clip(F.happy, 0.16);
  c.annoyed = held('annoyed', 1, 0.16);
  c.surprised = held('surprised', 4, 0.18);
  c.confused = clip(F.confused, 0.18);
  c.dazed = pp('dazed', 0.22);
  c.poked = clip(F.poked, 0.11);
  c.smug = clip(holdLast(F.snap.concat(F.smug), 2), 0.2);
  c.caneFlourish = pp('cane', 0.13);
  c.celebrating = held('celebrating', 2, 0.14);
  c.powerSurge = clip(F.portalring.concat(pingpong(F.powersurge), holdLast(F.powersurgeclose, 6)), 0.09);
  c.zodiacVision = held('zodiac', 3, 0.3);
  const ritual = F.summonritual;
  c.summonRitual = clip(Array(6).fill(ritual[0]).concat(ritual.slice(1)), 0.25);
  c.zodiacRage = held('zodiacrage', 4, 0.18);
  c.prismDance = held('prismdance', 3, 0.16);
  c.zodiacCrimson = held('zodiaccrimson', 4, 0.2);
  c.ghostPale = held('ghost', 5, 0.2);
  c.glitchForm = pp('glitch', 0.08);
  const sa = F.shadowa; const sb = F.shadowb;
  c.shadowHands = clip(holdLast([sb[0], sa[0], sa[3], sb[2]], 4), 0.3);
  c.meltdown = held('meltdown', 4, 0.15);
  c.trickster = held('trickster', 3, 0.15);
  c.darkWorld = held('darkworld', 3, 0.17);
  c.hollowed = held('hollowed', 3, 0.16);
  c.cultLeader = held('cultleader', 3, 0.17);
  c.spooked = held('spooked', 3, 0.13);
  c.scanning = held('scanning', 3, 0.13);
  c.sneaking = loop('sneaking', 0.14);
  c.glitching = loop('glitching', 0.14);
  c.charged = held('charged', 3, 0.14);
  c.transferring = held('transferring', 3, 0.09);
  c.summoning = held('summoning', 3, 0.14);
  c.sculpting = held('sculpting', 3, 0.16);
  c.kinship = pp('kinship', 0.13);
  c.fractaling = held('fractaling', 3, 0.2);
  c.presenting = pp('presenting', 0.17);
  c.guilty = pp('guilty', 0.2);
  c.dreading = held('dreading', 3, 0.16);
  c.grooving = pp('grooving', 0.15);
  c.dispatching = pp('dispatching', 0.14);
  c.ambushed = held('ambushed', 3, 0.13);
  c.stressed = held('stressed', 3, 0.16);
  c.watched = pp('watched', 0.16);
  c.flinching = pp('flinching', 0.13);
  c.huffy = held('huffy', 3, 0.11);
  c.pushingCode = loop('pushingcode', 0.1);
  c.browsingStore = loop('browsingstore', 0.1);
  c.dancing = pp('dancing', 0.12);
  c.sleeping = clip(F.sleeping, 0.12, 'pingpong', [k(1.6, { dy: -2 }), k(1.6, { dy: 0 })]);
  c.gaming = clip([F.cane[5]], 0.12, 'pingpong', [k(0.3, { rot: -0.08 }), k(0.3, { rot: 0.08 })]);
  c.coding = clip(F.coding, 0.22, 'loop');
  c.heatingUp = loop('heating', 0.2);
  c.charging = clip(F.charging, 0.12, 'pingpong', [k(1.1, { dy: 2 }), k(1.1, { dy: 0 })]);
  c.channeling = loop('channeling', 0.15);
  c.focused = pp('focused', 0.2);
  c.caneTwist = pp('canetwist', 0.13);
  c.hookCane = pp('hookcane', 0.18);
  c.conjuring = held('conjuring', 3, 0.15);
  c.tumbling = held('tumbling', 3, 0.15);
  c.dashTarget = held('dashtarget', 4, 0.11);
  c.grumpEyes = held('grumpeyes', 3, 0.15);
  c.zipAround = held('ziparound', 3, 0.11);
  c.rampaging = held('rampaging', 3, 0.11);
  c.ritualBuildup = clip(holdLast(F.summonbuild.concat(F.summonhold), 8), 0.25);

  // Roaming physics states reuse existing art, exactly like the Mac app.
  const fl = F.flinching; const sn = F.sneaking;
  c.crouching = clip(holdLast(fl, 2), 0.06);
  c.launching = clip(rev(fl), 0.055, 'once', [k(0.09, { dy: 6, timing: 'easeOut' }), k(0.08, { dy: 0, timing: 'easeIn' })]);
  c.rising = clip([fl[0]], 0.12, 'loop', [k(0.45, { dy: 4, timing: 'easeOut' }), k(0.45, { dy: 0, timing: 'easeIn' })]);
  c.falling = clip(F.tumbling, 0.1, 'loop');
  c.landingSoft = clip(pingpong(fl.slice(0, 2)), 0.075);
  c.landingHard = clip(pingpong(fl, 2), 0.07, 'once', [k(0.1, { dy: -7, timing: 'easeOut' }), k(0.22, { dy: 0, timing: 'easeOut' })]);
  c.ledgeGrabbing = clip(holdLast(sn.slice(0, 2), 2), 0.08);
  c.climbingUp = clip(sn, 0.13, 'loop');
  c.climbingDown = clip(rev(sn), 0.15, 'loop');
  c.hangingIdle = clip([sn[0]], 0.12, 'loop', [k(1.1, { rot: 0.045 }), k(1.1, { rot: -0.045 })]);
  c.edgePeek = pp('focused', 0.16);
  c.running = clip(F.rampaging, 0.08, 'loop', [k(0.16, { dy: 4 }), k(0.16, { dy: 0 })]);
  return c;
}

const CLIPS = buildClips();

const IDLE_VARIANTS = {
  shiftWeight: clip([F.idle[3]], 0.9),
  stretch: clip([F.idle[0]], 0.12, 'once', [k(0.35, { dy: 6, timing: 'easeOut' }), k(0.45, { dy: 0, timing: 'easeIn' })]),
  tiltCheck: clip([F.idle[0]], 0.12, 'once', [k(0.4, { rot: 0.1 }), k(0.4, { rot: 0 })]),
  curious: clip(F.curious, 0.25),
};

/** Length of one pass of a clip — the longer of its frame track and its transform track. */
function singlePassDuration(c) {
  const textureTime = c.textures.length * c.frameDuration;
  const transformTime = c.transform.reduce((sum, kf) => sum + kf.duration, 0);
  return Math.max(textureTime, transformTime);
}

function allSpriteFiles() {
  const out = [];
  for (const group of Object.keys(GROUPS)) for (const [file] of frames(group)) out.push(file);
  return out;
}

module.exports = {
  CLIPS, IDLE_VARIANTS, FX, GROUPS,
  REST_FRAME: F.idle[0],
  DISPLAY_SCALE: 1.9,
  singlePassDuration,
  allSpriteFiles,
};
