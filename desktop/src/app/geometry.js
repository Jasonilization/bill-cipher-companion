// Screen geometry in the Mac app's coordinate space.
//
// The physics, the roaming planner and the bubble placement were all written
// against Cocoa's screen space: origin at the primary display's bottom-left,
// Y increasing upward. Windows and X11 put the origin top-left with Y down.
// Rather than re-derive every comparison, the port keeps the original space
// internally and flips exactly once, here, at the window boundary.
const { screen } = require('electron');

const primaryHeight = () => screen.getPrimaryDisplay().bounds.height;

/** Electron DIP rect { x, y, width, height } (Y down) → { x, y, w, h } (Y up). */
function toUp(r) {
  return { x: r.x, y: primaryHeight() - r.y - r.height, w: r.width, h: r.height };
}

/** { x, y, w, h } (Y up) → Electron DIP rect (Y down). */
function toDown(r) {
  return { x: r.x, y: primaryHeight() - r.y - r.h, width: r.w, height: r.h };
}

const contains = (r, p) => p.x >= r.x && p.x < r.x + r.w && p.y >= r.y && p.y < r.y + r.h;

/** The display a Y-up point is on: { frame, visible } in Y-up space. */
function screenAt(point) {
  const displays = screen.getAllDisplays();
  let display = displays.find((d) => contains(toUp(d.bounds), point));
  if (!display) {
    display = screen.getDisplayNearestPoint({ x: Math.round(point.x), y: Math.round(primaryHeight() - point.y) });
  }
  return describe(display);
}

function describe(display) {
  return { id: display.id, frame: toUp(display.bounds), visible: toUp(display.workArea), scaleFactor: display.scaleFactor };
}

const primaryScreen = () => describe(screen.getPrimaryDisplay());
const allScreens = () => screen.getAllDisplays().map(describe);

/** The mouse pointer, Y up. */
function cursor() {
  const p = screen.getCursorScreenPoint();
  return { x: p.x, y: primaryHeight() - p.y };
}

module.exports = { primaryHeight, toUp, toDown, contains, screenAt, primaryScreen, allScreens, cursor };
