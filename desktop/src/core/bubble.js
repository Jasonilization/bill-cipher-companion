// Port of Animation/BarkBubble.swift (+ PixelFont): the hand-built 5x7 pixel
// font and the layered-border speech bubble. Produces a small grid of palette
// indices at "unit" resolution; the renderer paints it and scales it up with
// nearest-neighbour filtering, exactly like the Mac's SKTexture(.nearest).
const GLYPHS = require('../data/glyphs.json');

const PIXEL_SCALE = 3;
const PADDING_X = 7;
const PADDING_Y = 6;
const CORNER_RADIUS = 5;
const BORDER = 1;
const ACCENT = 1;
const TAIL_HEIGHT = 3;
const MAX_TEXT_WIDTH_UNITS = 66;
const MIN_TEXT_WIDTH_UNITS = 20;
const MAX_LINES = 14;

const GLYPH_W = 5;
const GLYPH_H = 7;
const GLYPH_SPACING = 1;
const SPACE_W = 4;
const LINE_SPACING = 2;
const LINE_H = GLYPH_H + LINE_SPACING;

// Palette indices used in the cell grid.
const P = { clear: 0, black: 1, accent: 2, fill: 3, text: 4 };

const advance = (ch) => (ch === ' ' ? SPACE_W : GLYPH_W + GLYPH_SPACING);
function lineWidth(line) {
  if (!line.length) return 0;
  let total = 0;
  for (const ch of line) total += advance(ch);
  return total - GLYPH_SPACING;
}

function normalize(text) {
  return text
    .replace(/[‘’]/g, "'")
    .replace(/[“”]/g, '"')
    .replace(/[–—]/g, '-');
}

function hardBreak(word, maxWidth, lines, state) {
  if (lineWidth(word) <= maxWidth) return word;
  if (state.current) { lines.push(state.current); state.current = ''; }
  let chunk = '';
  for (const ch of word) {
    const candidate = chunk + ch;
    if (lineWidth(candidate) > maxWidth && chunk) { lines.push(chunk); chunk = ch; } else chunk = candidate;
  }
  return chunk;
}

/** Greedy wrap with fixed advances; over-wide words are hard-broken, overflow ends in "...". */
function wrap(text, maxWidthUnits, maxLines) {
  const words = text.split(/\s+/).filter(Boolean);
  let lines = [];
  const state = { current: '' };
  for (const word of words) {
    const piece = hardBreak(word, maxWidthUnits, lines, state);
    const candidate = state.current ? `${state.current} ${piece}` : piece;
    if (lineWidth(candidate) > maxWidthUnits && state.current) {
      lines.push(state.current);
      state.current = piece;
    } else state.current = candidate;
  }
  if (state.current) lines.push(state.current);
  if (!lines.length) lines = [''];
  if (lines.length <= maxLines) return lines;
  const truncated = lines.slice(0, maxLines);
  let last = truncated.pop();
  while (lineWidth(`${last}...`) > maxWidthUnits && last.length) last = last.slice(0, -1);
  truncated.push(`${last}...`);
  return truncated;
}

class Grid {
  constructor(w, h) { this.w = w; this.h = h; this.cells = new Uint8Array(w * h); }
  set(x, y, v) { if (x >= 0 && y >= 0 && x < this.w && y < this.h) this.cells[y * this.w + x] = v; }
  /** Rounded rect with quarter-circle raster corners (same cell test as the Mac renderer). */
  roundedRect(x0, y0, w, h, r, v) {
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        const hDist = Math.min(x, w - 1 - x);
        const vDist = Math.min(y, h - 1 - y);
        if (hDist < r && vDist < r) {
          const a = r - hDist - 0.5; const b = r - vDist - 0.5;
          if (a * a + b * b > r * r) continue;
        }
        this.set(x0 + x, y0 + y, v);
      }
    }
  }
  span(cx, y, width, v, vertical = false) {
    const start = Math.round(cx - width / 2);
    for (let i = 0; i < width; i++) vertical ? this.set(y, start + i, v) : this.set(start + i, y, v);
  }
}

function drawText(grid, lines, rect) {
  const blockH = lines.length * LINE_H - LINE_SPACING;
  let y = Math.round(rect.y + (rect.h - blockH) / 2);
  for (const line of lines) {
    let x = Math.round(rect.x + (rect.w - lineWidth(line)) / 2);
    for (const ch of line) {
      const rows = ch === ' ' ? null : GLYPHS[ch];
      if (rows) {
        for (let r = 0; r < GLYPH_H; r++) for (let col = 0; col < GLYPH_W; col++) if (rows[r][col] === '#') grid.set(x + col, y + r, P.text);
      }
      x += advance(ch);
    }
    y += LINE_H;
  }
}

/**
 * Builds a bubble. `maxWidth`/`maxHeight` are on-screen room in DIPs.
 * tailEdge: 'above' (bubble above Bill, tail hangs down) | 'below' | 'leftSide' | 'rightSide' | 'none'.
 */
function makeBubble({ text, maxWidth = Infinity, maxHeight = Infinity, tailEdge = 'above', tailOffsetUnits = 0, textScale = 1, maxLines = MAX_LINES }) {
  const scale = PIXEL_SCALE * textScale;
  const chrome = PADDING_X * 2 + (BORDER + ACCENT) * 2;
  const roomUnits = Number.isFinite(maxWidth) ? Math.floor(maxWidth / scale) - chrome : MAX_TEXT_WIDTH_UNITS;
  const columnUnits = Math.min(MAX_TEXT_WIDTH_UNITS, Math.max(MIN_TEXT_WIDTH_UNITS, roomUnits));
  const heightBudget = Number.isFinite(maxHeight) ? Math.floor(maxHeight / scale) - TAIL_HEIGHT - PADDING_Y * 2 : Infinity;
  const lineBudget = Math.max(1, Math.floor(heightBudget / LINE_H));
  const lines = wrap(normalize(String(text).toUpperCase()), columnUnits, Math.min(maxLines, lineBudget));

  const textW = Math.max(0, ...lines.map(lineWidth));
  const textH = lines.length * LINE_H - LINE_SPACING;
  const bodyW = textW + PADDING_X * 2;
  const bodyH = textH + PADDING_Y * 2;
  const vertical = tailEdge === 'above' || tailEdge === 'below';
  const hasTail = tailEdge !== 'none';
  const w = bodyW + (hasTail && !vertical ? TAIL_HEIGHT : 0);
  const h = bodyH + (hasTail && vertical ? TAIL_HEIGHT : 0);
  // Grid rows run top-down. "above" = bubble sits above Bill, so its tail is on the bottom edge.
  const body = { x: tailEdge === 'leftSide' ? TAIL_HEIGHT : 0, y: tailEdge === 'below' ? TAIL_HEIGHT : 0, w: bodyW, h: bodyH };

  const grid = new Grid(w, h);
  grid.roundedRect(body.x, body.y, body.w, body.h, CORNER_RADIUS, P.black);
  grid.roundedRect(body.x + 1, body.y + 1, body.w - 2, body.h - 2, CORNER_RADIUS - 1, P.accent);
  grid.roundedRect(body.x + 2, body.y + 2, body.w - 4, body.h - 4, CORNER_RADIUS - 2, P.fill);

  if (hasTail) {
    const edgeLength = vertical ? body.w : body.h;
    const limit = Math.max(0, edgeLength / 2 - 5 - CORNER_RADIUS);
    const offset = Math.max(-limit, Math.min(limit, tailOffsetUnits));
    const mid = (vertical ? body.x + body.w / 2 : body.y + body.h / 2) + offset;
    // Rows from the body outward: [black, accent, fill] widths.
    const rows = [[10, 8, 6], [10, 8, 6], [10, 8, 6], [6, 4, 2], [2, 0, 0]];
    const outward = tailEdge === 'above' || tailEdge === 'rightSide' ? 1 : -1;
    const edge = tailEdge === 'above' ? body.y + body.h - 1
      : tailEdge === 'below' ? body.y
      : tailEdge === 'rightSide' ? body.x + body.w - 1 : body.x;
    // The first two rows overlap the body's own border so the tail reads as one shape with it.
    rows.forEach(([black, accent, fill], i) => {
      const pos = edge + outward * (i - 1);
      if (i >= 2) grid.span(mid, pos, black, P.black, !vertical);
      if (i === 0) { grid.span(mid, pos, fill, P.fill, !vertical); return; }
      if (accent) grid.span(mid, pos, accent, P.accent, !vertical);
      if (fill) grid.span(mid, pos, fill, P.fill, !vertical);
    });
  }

  drawText(grid, lines, { x: body.x + 2, y: body.y + 2, w: body.w - 4, h: body.h - 4 });

  return {
    w, h, scale,
    cells: Array.from(grid.cells),
    displayWidth: Math.ceil(w * scale),
    displayHeight: Math.ceil(h * scale),
    lines,
  };
}

module.exports = { makeBubble, wrap, lineWidth, normalize, PIXEL_SCALE, GLYPHS, P };
