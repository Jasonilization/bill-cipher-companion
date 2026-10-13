// `BILL_SELFTEST=1`: drives Bill through his paces on a real display, saves
// what each window actually painted, and writes a report that
// scripts/selftest.js checks. Nothing here talks to the network or to ChatGPT.
const fs = require('fs');
const os = require('os');
const path = require('path');
const { app, desktopCapturer, nativeImage, screen } = require('electron');
const geometry = require('./geometry');

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function waitFor(probe, timeoutMs, stepMs = 100) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const value = probe();
    if (value) return value;
    if (Date.now() > deadline) return null;
    await sleep(stepMs);
  }
}

/** What is in a captured window: how much is painted, where, and in how many colours. */
function describeImage(png) {
  const image = nativeImage.createFromBuffer(png);
  const { width, height } = image.getSize();
  const pixels = image.toBitmap();
  let painted = 0; let translucent = 0;
  let minX = width; let minY = height; let maxX = -1; let maxY = -1;
  const colours = new Set();
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const i = (y * width + x) * 4;
      const alpha = pixels[i + 3];
      if (alpha === 0) continue;
      painted += 1;
      if (alpha < 255) translucent += 1;
      if (x < minX) minX = x; if (x > maxX) maxX = x;
      if (y < minY) minY = y; if (y > maxY) maxY = y;
      if (colours.size < 4096) colours.add((pixels[i] << 16) | (pixels[i + 1] << 8) | pixels[i + 2]);
    }
  }
  return {
    width, height, painted, translucent,
    coverage: width * height ? painted / (width * height) : 0,
    box: painted ? { x: minX, y: minY, w: maxX - minX + 1, h: maxY - minY + 1 } : null,
    colours: colours.size,
  };
}

/** A crop of the real, composited screen around a Y-up rectangle. */
async function grabScreen(rectUp, pad = 24) {
  const display = screen.getDisplayNearestPoint({ x: Math.round(rectUp.x + rectUp.w / 2), y: Math.round(geometry.primaryHeight() - rectUp.y - rectUp.h / 2) });
  const factor = display.scaleFactor || 1;
  const sources = await desktopCapturer.getSources({
    types: ['screen'],
    thumbnailSize: { width: Math.round(display.size.width * factor), height: Math.round(display.size.height * factor) },
  });
  const source = sources.find((s) => String(s.display_id) === String(display.id)) || sources[0];
  if (!source || source.thumbnail.isEmpty()) return null;
  const shot = source.thumbnail;
  const size = shot.getSize();
  const kx = size.width / display.bounds.width; const ky = size.height / display.bounds.height;
  const down = geometry.toDown(rectUp);
  const x0 = Math.max(0, Math.floor((down.x - display.bounds.x - pad) * kx));
  const y0 = Math.max(0, Math.floor((down.y - display.bounds.y - pad) * ky));
  const x1 = Math.min(size.width, Math.ceil((down.x - display.bounds.x + down.width + pad) * kx));
  const y1 = Math.min(size.height, Math.ceil((down.y - display.bounds.y + down.height + pad) * ky));
  if (x1 <= x0 || y1 <= y0) return null;
  return shot.crop({ x: x0, y: y0, width: x1 - x0, height: y1 - y0 }).toPNG();
}

const union = (a, b) => {
  if (!b) return a;
  const x = Math.min(a.x, b.x); const y = Math.min(a.y, b.y);
  return { x, y, w: Math.max(a.x + a.w, b.x + b.w) - x, h: Math.max(a.y + a.h, b.y + b.h) - y };
};

async function run(b) {
  const out = path.resolve(process.env.BILL_SELFTEST_DIR || path.join(os.tmpdir(), 'bill-selftest'));
  fs.mkdirSync(out, { recursive: true });
  const report = {
    platform: process.platform, backend: b.platform.name, electron: process.versions.electron,
    session: process.env.XDG_SESSION_TYPE || null, images: {}, errors: [],
  };
  const fail = (what, error) => report.errors.push(`${what}: ${error && error.message ? error.message : error}`);
  const save = async (name, png) => {
    if (!png) { fail(name, 'nothing captured'); return; }
    fs.writeFileSync(path.join(out, `${name}.png`), png);
    report.images[name] = describeImage(png);
  };
  const step = async (name, fn) => { try { await fn(); } catch (e) { fail(name, e); } };
  const finish = () => {
    fs.writeFileSync(path.join(out, 'report.json'), JSON.stringify(report, null, 2));
    console.log(`SELFTEST_DONE ${out}`);
    app.quit();
  };
  // Whatever happens, the run ends and says why.
  const watchdog = setTimeout(() => { fail('self-test', 'timed out'); finish(); }, 150000);

  // Hold still for the pictures, and leave other apps' windows alone: a test
  // run must not press anybody's minimize button.
  b.prefs.set('minimizeMischief', false);
  b.roaming.suspend();
  const { engine, window: bill, barkWindow, chatBubble, panels } = b;

  await step('sprites', async () => {
    report.sprites = await waitFor(() => bill.spritesLoaded, 30000);
    if (!report.sprites) throw new Error('the sprite sheet never finished loading');
  });
  await sleep(600);

  await step('bill window', async () => {
    const display = bill.screen();
    report.bill = { frame: bill.frame, hit: bill.hitRegion(), scale: bill.scale, screen: display.visible, scaleFactor: display.scaleFactor };
    report.bill.bounds = bill.window.getBounds();
    report.bill.onTop = bill.window.isAlwaysOnTop();
    report.bill.visible = bill.window.isVisible();
    await save('bill-idle', await bill.capture());
    engine.request('celebrating', true);
    await sleep(900);
    report.bill.state = engine.stateMachine.currentState;
    await save('bill-celebrating', await bill.capture());
    await save('screen-bill', await grabScreen(bill.frame));
  });

  await step('facing and scale', async () => {
    bill.setFacing(-1);
    await sleep(250);
    await save('bill-facing-right', await bill.capture());
    bill.setFacing(1);
    const before = b.prefs.get('characterScale');
    b.prefs.set('characterScale', 1.5);
    await sleep(500);
    report.scaled = { frame: bill.frame, bounds: bill.window.getBounds() };
    await save('bill-scaled', await bill.capture());
    b.prefs.set('characterScale', before);
    await sleep(400);
    report.rescaled = { frame: bill.frame, bounds: bill.window.getBounds() };
  });

  // Barks are queued: wait out whatever he was already saying, then speak.
  const say = async (text) => {
    engine.stateMachine.clearBarkQueue();
    await waitFor(() => !engine.stateMachine.isBarkShowing, 9000);
    await sleep(350);
    engine.bark(text, 'always');
    await sleep(900);
  };

  await step('bark', async () => {
    await say('AH, A TEST SUBJECT. WATCH CLOSELY: THIS BUBBLE WRAPS ITS TEXT PROPERLY, AND ITS TAIL IS PART OF THE BORDER.');
    report.bark = { ...barkWindow.lastPlacement, bounds: barkWindow.window.getBounds(), visible: barkWindow.window.isVisible() };
    await save('bark', await barkWindow.capture());
    await save('screen-bark', await grabScreen(union(bill.frame, barkWindow.frame)));
    await waitFor(() => !engine.stateMachine.isBarkShowing, 9000);
    await sleep(500);
    report.bark.hiddenAfterFade = !barkWindow.window.isVisible();

    // Against the right edge the bubble has nowhere to go but his other side.
    bill.parkNearRightEdge();
    await sleep(200);
    await say('NOW I\'M AT THE SCREEN\'S EDGE. GEOMETRY IS A LIFESTYLE.');
    report.barkAtEdge = { ...barkWindow.lastPlacement, bounds: barkWindow.window.getBounds(), bill: bill.frame };
    await save('bark-edge', await barkWindow.capture());
    await save('screen-bark-edge', await grabScreen(union(bill.frame, barkWindow.frame)));
  });

  await step('chat bubble', async () => {
    chatBubble.showCompose(bill.frame, bill.screen());
    await waitFor(() => chatBubble.isLoaded, 8000);
    await sleep(700);
    report.chat = { frame: chatBubble.frame, tail: chatBubble.tailSide, bounds: chatBubble.window.getBounds(), visible: chatBubble.window.isVisible() };
    await save('chat-compose', await chatBubble.capture());
    chatBubble.showWaiting();
    await sleep(700);
    await save('chat-waiting', await chatBubble.capture());
    chatBubble.showResponse('WELL, WELL, WELL. A SELF-TEST. I\'VE SEEN BETTER RITUALS, BUT THIS ONE AT LEAST HAS **STRUCTURE**.\n\nREMEMBER: REALITY IS AN ILLUSION, THE UNIVERSE IS A HOLOGRAM, BUY GOLD. BYE!');
    await sleep(900);
    await save('chat-response', await chatBubble.capture());
    await save('screen-chat', await grabScreen(union(bill.frame, chatBubble.frame)));
    // Putting the bubble away must not start a wander mid-test.
    const dismiss = chatBubble.onDismiss;
    chatBubble.onDismiss = null;
    chatBubble.hide();
    chatBubble.onDismiss = dismiss;
    report.chat.hidden = !chatBubble.window.isVisible();
  });

  await step('panels', async () => {
    for (const name of ['settings', 'quotes', 'log', 'personalize']) {
      const win = panels.open(name);
      await waitFor(() => !win.webContents.isLoading(), 8000);
      await sleep(900);
      await save(`panel-${name}`, (await win.webContents.capturePage()).toPNG());
      if (name === 'settings') {
        for (const section of ['Behaviour', 'Animations', 'Test Triggers', 'Chat & Prompts', 'Weather', 'About']) {
          win.webContents.send('settings:section', section);
          await sleep(350);
          await save(`panel-settings-${section.toLowerCase().replace(/[^a-z]+/g, '-')}`, (await win.webContents.capturePage()).toPNG());
        }
        report.settingsFrame = panels.settingsFrame();
      }
      win.close();
    }
  });

  await step('platform', async () => {
    const p = b.platform;
    p.refreshOwnPids();
    const windows = p.listWindows();
    const fg = p.foreground();
    report.os = {
      windows: windows.length,
      sampleWindows: windows.slice(0, 6).map((w) => ({ rect: w.rect, hasTitle: !!w.title })),
      foreground: fg ? { own: !!fg.own, hasName: !!fg.name, hasId: !!fg.id } : null,
      volume: await p.readVolume(),
      link: await p.linkQuality(),
      installedApps: (await p.installedApps()).length,
      ocr: p.ocrStatus,
      launchAtLogin: p.isLaunchAtLoginEnabled(),
      platforms: b.topology.platforms(true).length,
      tray: !!b.menu.tray,
      menuItems: b.menu.build().items.length,
    };
  });

  await step('screen solving', async () => {
    // A window of his own with known problems in it: photograph it, read it, solve it.
    const { BrowserWindow } = require('electron');
    const { solveText } = require('../core/solver');
    const page = '<body style="margin:0;background:#fff;color:#000;font:30px Arial,sans-serif;padding:24px">'
      + '<p>1. 12 x 4 =</p><p>2. 3x + 2 = 14</p><p>3. What is 15% of 80?</p></body>';
    const win = new BrowserWindow({ width: 560, height: 330, show: false, title: 'Bill self-test problems', webPreferences: { sandbox: true } });
    await win.loadURL(`data:text/html;charset=utf-8,${encodeURIComponent(page)}`);
    win.showInactive();
    await sleep(600);
    const image = await win.webContents.capturePage();
    win.destroy();
    const text = await b.platform.readImage(image, { block: true });
    const solved = solveText(text || '', { ocr: true });
    report.solve = {
      ocr: b.platform.canReadScreen, reader: b.platform.readerDetail, text: text || null,
      answers: solved.problems.map((p) => `${p.source} ${p.answer}`),
    };
    if (report.solve.ocr && solved.problems.length < 2) throw new Error(`read "${text}" but solved only ${solved.problems.length} of 3`);

    const shot = await b.platform.captureRegion({ x: 100, y: 100, width: 300, height: 200 });
    report.solve.region = shot ? shot.getSize() : null;

    // The drag-a-box sheet, driven by synthetic input inside his own window.
    const picking = b.snip.pick();
    await waitFor(() => b.snip.isReady, 6000);
    await sleep(300);
    if (b.snip.window) {
      const contents = b.snip.window.webContents;
      contents.sendInputEvent({ type: 'mouseDown', x: 200, y: 200, button: 'left', clickCount: 1 });
      contents.sendInputEvent({ type: 'mouseMove', x: 520, y: 430, button: 'left' });
      contents.sendInputEvent({ type: 'mouseUp', x: 520, y: 430, button: 'left', clickCount: 1 });
    }
    const picked = await Promise.race([picking, sleep(4000).then(() => 'timeout')]);
    if (picked === 'timeout') b.snip.cancel();
    report.solve.snip = picked;

    // Changing mood announces itself and never leaves the prefs in an invalid state.
    b.prefs.set('mode', 'helpful');
    b.prefs.set('mode', 'nonsense');
    report.solve.mode = b.prefs.get('mode');
    report.solve.screenPlayLive = b.screenPlay.enabled;
    b.prefs.set('mode', 'troll');
  });

  await step('roaming', async () => {
    // Forced wanders: each should pick a goal, travel, and come to rest on
    // the floor or on top of a window, never in mid-air.
    const P = require('../core/physics');
    const roaming = b.roaming;
    report.roam = [];
    for (let beat = 0; beat < 3; beat++) {
      const from = { ...bill.frame };
      engine.request('idle', true);
      roaming.triggerNow();
      const goal = roaming.goal ? { kind: roaming.goal.kind, top: roaming.goal.rect ? P.maxY(roaming.goal.rect) : null } : null;
      const states = new Set(); const steps = new Set();
      let travelled = 0; let last = { ...bill.frame };
      const started = Date.now();
      while (roaming.isTicking && Date.now() - started < 14000) {
        await sleep(50);
        states.add(engine.stateMachine.currentState);
        steps.add(roaming.step.kind);
        travelled += Math.hypot(bill.frame.x - last.x, bill.frame.y - last.y);
        last = { ...bill.frame };
      }
      const feet = roaming.feetPosition();
      const floor = roaming.sim.worldBounds.y;
      const onFloor = Math.abs(feet.y - floor) <= 2;
      const half = roaming.sim.halfWidth;
      const onWindow = roaming.sim.solids.some((solid) => Math.abs(feet.y - P.maxY(solid.rect)) <= 2 && feet.x + half > solid.rect.x && feet.x - half < P.maxX(solid.rect));
      report.roam.push({
        goal, ms: Date.now() - started, finished: !roaming.isTicking, travelled: Math.round(travelled),
        from: { x: Math.round(from.x), y: Math.round(from.y) }, feet: { x: Math.round(feet.x), y: Math.round(feet.y) },
        rests: onFloor ? 'floor' : onWindow ? 'window' : 'mid-air', solids: roaming.sim.solids.length,
        states: [...states], steps: [...steps],
      });
      if (beat === 0) await save('screen-roaming', await grabScreen(bill.frame));
    }
    roaming.suspend();
  });

  clearTimeout(watchdog);
  finish();
}

module.exports = { run, describeImage };
