// Bill's sprite view (port of Animation/{BillScene,BillRigNode,AnimationClip,FXLibrary}.swift).
//
// The main process decides what plays and for how long; this file only draws
// it. Everything is laid out in the Mac scene's units — a 260x250 canvas with
// the rig root 130 across and 110 up — and scaled as one.
(() => {
  const BASE_W = 260; const BASE_H = 250;
  const ROOT_X = 130; const ROOT_Y = 110;          // rig root, from the bottom-left
  const SPRITE_W = 118; const SPRITE_H = 111;
  const AMBIENT_FPS = 12; const ACTIVE_FPS = 30;

  const canvas = document.getElementById('stage');
  const ctx = canvas.getContext('2d');
  const images = new Map();

  let displayScale = 1.9;
  let scale = 1;
  let facing = 1;
  let fps = AMBIENT_FPS;
  let dpr = 0;
  let baseUrl = '';
  let restFrame = null;
  let ready = false;

  // What is on screen.
  let frame = null;                                 // [file, anchorShift]
  let track = null;                                 // texture track
  let motion = null;                                // transform track
  const offset = { dx: 0, dy: 0, rot: 0 };
  let emitters = [];
  let label = null;

  const now = () => performance.now() / 1000;
  const ease = {
    linear: (t) => t,
    easeIn: (t) => t * t,
    easeOut: (t) => t * (2 - t),
    easeInEaseOut: (t) => (t < 0.5 ? 2 * t * t : -1 + (4 - 2 * t) * t),
  };

  // ------------------------------------------------------------------ layout
  function layout() {
    dpr = window.devicePixelRatio || 1;
    const w = Math.round(BASE_W * scale); const h = Math.round(BASE_H * scale);
    canvas.style.width = `${w}px`; canvas.style.height = `${h}px`;
    canvas.width = Math.round(w * dpr); canvas.height = Math.round(h * dpr);
  }

  // ------------------------------------------------------------------- clips
  function playClip(clip) {
    const t = now();
    const textures = clip.textures || [];
    if (textures.length === 1) { frame = textures[0]; track = null; }
    else if (textures.length > 1) track = { textures, frameDuration: clip.frameDuration, loop: clip.loop, start: t };

    const keys = clip.transform || [];
    if (!keys.length) { motion = null; return; }
    let sequence = keys;
    if (clip.loop === 'pingpong') {
      // Forward, then back through the same poses, then home.
      const last = keys[keys.length - 1];
      sequence = keys.concat(keys.slice(0, -1).reverse(), [{ duration: last.duration, dx: 0, dy: 0, rot: 0, timing: last.timing }]);
    }
    motion = { keys: sequence, repeat: clip.loop !== 'once', index: 0, start: t, from: { ...offset } };
  }

  /** Ease back to the rest pose on the rest frame. */
  function settle() {
    track = null;
    frame = restFrame;
    motion = {
      keys: [{ duration: 0.25, dx: 0, dy: 0, rot: 0, timing: 'easeOut' }],
      repeat: false, index: 0, start: now(), from: { ...offset },
    };
    setFX(null);
  }

  function advance(t) {
    if (track) {
      const n = track.textures.length;
      const step = Math.floor((t - track.start) / track.frameDuration);
      let index;
      if (track.loop === 'once') index = Math.min(step, n - 1);
      else if (track.loop === 'pingpong') { const m = step % (2 * n); index = m < n ? m : 2 * n - 1 - m; }
      else index = step % n;
      frame = track.textures[Math.max(0, index)];
    }
    while (motion) {
      const key = motion.keys[motion.index];
      const p = key.duration > 0 ? (t - motion.start) / key.duration : 1;
      if (p < 1) {
        const e = (ease[key.timing] || ease.easeInEaseOut)(Math.max(0, p));
        offset.dx = motion.from.dx + (key.dx - motion.from.dx) * e;
        offset.dy = motion.from.dy + (key.dy - motion.from.dy) * e;
        offset.rot = motion.from.rot + (key.rot - motion.from.rot) * e;
        break;
      }
      offset.dx = key.dx; offset.dy = key.dy; offset.rot = key.rot;
      motion.start += key.duration;
      motion.from = { dx: key.dx, dy: key.dy, rot: key.rot };
      motion.index += 1;
      if (motion.index >= motion.keys.length) {
        if (motion.repeat) motion.index = 0; else motion = null;
      }
    }
  }

  // ---------------------------------------------------------------------- FX
  const rand = (base, range) => base + (Math.random() - 0.5) * range;

  const EMITTERS = {
    steam: () => ({
      x: 0, y: 74, rate: 14, max: Infinity, life: [1.1, 0.4], range: [14, 4], speed: [26, 10],
      angle: [Math.PI / 2, Math.PI / 5], alpha: [0.5, 0.15], alphaSpeed: -0.5, size: [0.5, 0.2], sizeSpeed: 0.35,
      gravity: 0, spin: 0, shape: 'puff', colors: ['217,217,217'], blend: 'source-over', unit: 18,
    }),
    sparkle: (count = 24) => ({
      x: 0, y: 10, rate: 18, max: count, life: [0.6, 0.25], range: [60, 60], speed: [6, 0],
      angle: [0, Math.PI * 2], alpha: [0.9, 0], alphaSpeed: -1.4, size: [0.35, 0.2], sizeSpeed: -0.25,
      gravity: 0, spin: 2.2, shape: 'star', colors: ['255,235,128'], blend: 'lighter', unit: 16,
    }),
    confetti: () => ({
      x: 0, y: 40, rate: 60, max: 60, life: [1.4, 0.6], range: [90, 4], speed: [140, 60],
      angle: [Math.PI / 2, Math.PI * 0.7], alpha: [1, 0], alphaSpeed: -0.6, size: [0.28, 0.15], sizeSpeed: 0,
      gravity: -220, spin: 6, shape: 'square', colors: ['250,199,38', '255,105,180', '64,224,208', '160,96,255'],
      blend: 'source-over', unit: 14,
    }),
  };

  function makeEmitter(spec) { return { spec, particles: [], born: 0, carry: 0, last: now() }; }

  function setFX(kind) {
    emitters = []; label = null;
    if (kind === 'steam') emitters = [makeEmitter(EMITTERS.steam())];
    else if (kind === 'sparkle') emitters = [makeEmitter(EMITTERS.sparkle())];
    else if (kind === 'confettiAndSparkle') emitters = [makeEmitter(EMITTERS.confetti()), makeEmitter(EMITTERS.sparkle(30))];
    else if (kind === 'zzz') label = { text: 'Z z z', x: 36, y: 74 };
  }

  function stepEmitter(emitter, t) {
    const { spec } = emitter;
    const dt = Math.min(0.1, t - emitter.last);
    emitter.last = t;
    emitter.carry += spec.rate * dt;
    while (emitter.carry >= 1 && emitter.born < spec.max) {
      emitter.carry -= 1; emitter.born += 1;
      const angle = rand(spec.angle[0], spec.angle[1]);
      const speed = rand(spec.speed[0], spec.speed[1]);
      emitter.particles.push({
        x: spec.x + rand(0, spec.range[0]), y: spec.y + rand(0, spec.range[1]),
        vx: Math.cos(angle) * speed, vy: Math.sin(angle) * speed,
        life: Math.max(0.05, rand(spec.life[0], spec.life[1])), age: 0,
        alpha: rand(spec.alpha[0], spec.alpha[1]), size: Math.max(0.05, rand(spec.size[0], spec.size[1])),
        rotation: Math.random() * Math.PI, color: spec.colors[Math.floor(Math.random() * spec.colors.length)],
      });
    }
    if (emitter.born >= spec.max) emitter.carry = 0;
    emitter.particles = emitter.particles.filter((p) => {
      p.age += dt;
      p.vy += spec.gravity * dt;
      p.x += p.vx * dt; p.y += p.vy * dt;
      p.alpha += spec.alphaSpeed * dt;
      p.size += spec.sizeSpeed * dt;
      p.rotation += spec.spin * dt;
      return p.age < p.life && p.alpha > 0.01 && p.size > 0.02;
    });
  }

  function drawParticle(spec, p) {
    const r = spec.unit * p.size;
    ctx.save();
    ctx.translate(p.x, -p.y);
    ctx.globalAlpha = Math.max(0, Math.min(1, p.alpha));
    if (spec.shape === 'puff') {
      const g = ctx.createRadialGradient(0, 0, 0, 0, 0, r);
      g.addColorStop(0, `rgba(${p.color},1)`); g.addColorStop(1, `rgba(${p.color},0)`);
      ctx.fillStyle = g;
      ctx.beginPath(); ctx.arc(0, 0, r, 0, Math.PI * 2); ctx.fill();
    } else if (spec.shape === 'star') {
      ctx.rotate(p.rotation);
      ctx.fillStyle = `rgb(${p.color})`;
      ctx.beginPath();
      for (let i = 0; i < 8; i++) {
        const radius = i % 2 === 0 ? r : r * 0.28;
        const a = (i * Math.PI) / 4;
        ctx.lineTo(Math.cos(a) * radius, Math.sin(a) * radius);
      }
      ctx.closePath(); ctx.fill();
    } else {
      ctx.rotate(p.rotation);
      ctx.fillStyle = `rgb(${p.color})`;
      ctx.fillRect(-r / 2, -r / 2, r, r);
    }
    ctx.restore();
  }

  // -------------------------------------------------------------------- draw
  function draw(t) {
    if ((window.devicePixelRatio || 1) !== dpr) layout();
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    const k = dpr * scale;
    // Rig root, with Y flipped so the scene's "up" is up.
    ctx.setTransform(k, 0, 0, k, k * ROOT_X, k * (BASE_H - ROOT_Y));
    ctx.imageSmoothingEnabled = false;

    const image = frame && images.get(frame[0]);
    if (image) {
      const w = SPRITE_W * displayScale; const h = SPRITE_H * displayScale;
      ctx.save();
      ctx.translate(offset.dx, -offset.dy);
      ctx.rotate(-offset.rot);
      ctx.scale(facing, 1);
      // Every frame shares one canvas; a group's art can sit off-centre in it,
      // and the shift slides it back without moving the canvas itself.
      ctx.beginPath(); ctx.rect(-w / 2, -h / 2, w, h); ctx.clip();
      ctx.drawImage(image, -w / 2 + frame[1] * displayScale, -h / 2, w, h);
      ctx.restore();
    }

    ctx.imageSmoothingEnabled = true;
    for (const emitter of emitters) {
      stepEmitter(emitter, t);
      ctx.globalCompositeOperation = emitter.spec.blend;
      for (const p of emitter.particles) drawParticle(emitter.spec, p);
    }
    ctx.globalCompositeOperation = 'source-over';
    ctx.globalAlpha = 1;
    if (label) {
      ctx.font = '600 22px "Avenir Next", "Segoe UI", "Noto Sans", sans-serif';
      ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
      ctx.fillStyle = 'rgba(255,255,255,0.85)';
      ctx.fillText(label.text, label.x, -label.y);
    }
  }

  let lastDraw = 0;
  function loop() {
    requestAnimationFrame(loop);
    if (!ready) return;
    const t = now();
    if (t - lastDraw < 1 / fps - 0.004) return;
    lastDraw = t;
    advance(t);
    draw(t);
  }

  // -------------------------------------------------------------------- input
  let pressed = false;
  canvas.addEventListener('pointerdown', (event) => {
    if (event.button !== 0) return;
    pressed = true;
    try { canvas.setPointerCapture(event.pointerId); } catch { /* already released */ }
    window.bill.send('bill:pointerDown');
  });
  const release = () => { if (!pressed) return; pressed = false; window.bill.send('bill:pointerUp'); };
  canvas.addEventListener('pointerup', (event) => { if (event.button === 0) release(); });
  canvas.addEventListener('pointercancel', release);
  canvas.addEventListener('lostpointercapture', release);
  window.addEventListener('blur', release);
  window.addEventListener('contextmenu', (event) => { event.preventDefault(); window.bill.send('bill:contextMenu'); });
  window.addEventListener('dragstart', (event) => event.preventDefault());

  // ------------------------------------------------------------------ battery
  if (navigator.getBattery) {
    navigator.getBattery().then((battery) => {
      const report = () => window.bill.send('bill:battery', { charging: battery.charging, level: battery.level });
      battery.addEventListener('chargingchange', report);
      battery.addEventListener('levelchange', report);
      report();
    }).catch(() => { /* no battery API on this machine */ });
  }

  // --------------------------------------------------------------------- wire
  function preload(files) {
    return Promise.all(files.map((file) => new Promise((resolve) => {
      const image = new Image();
      image.onload = () => { images.set(file, image); resolve(); };
      image.onerror = () => resolve();
      image.src = baseUrl + file;
    })));
  }

  window.bill.on('bill:init', async (config) => {
    baseUrl = config.spritesUrl;
    displayScale = config.displayScale;
    restFrame = config.restFrame;
    scale = config.scale;
    facing = config.facing;
    layout();
    // The rest frame first, so he is on screen before the other 400 arrive.
    await preload([restFrame[0]]);
    if (!frame) frame = restFrame;
    ready = true;
    window.bill.send('bill:ready', { early: true });
    await preload(config.files);
    window.bill.send('bill:ready', { early: false, loaded: images.size, expected: config.files.length });
  });
  window.bill.on('bill:clip', ({ clip, fx }) => {
    playClip(clip);
    if (fx !== undefined) setFX(fx);
  });
  window.bill.on('bill:settle', settle);
  window.bill.on('bill:facing', (value) => { facing = value; });
  window.bill.on('bill:scale', (value) => { scale = value; layout(); });
  window.bill.on('bill:activity', (active) => { fps = active ? ACTIVE_FPS : AMBIENT_FPS; });

  requestAnimationFrame(loop);
})();
