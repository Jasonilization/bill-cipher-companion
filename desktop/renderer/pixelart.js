// Pixel-art drawing shared by every window that shows Bill's chrome
// (port of the raster helpers in Animation/BarkBubble.swift). Nothing here is
// anti-aliased: art is rasterised 1:1 into a tiny canvas and scaled up whole.
(() => {
  const BLACK = [18, 18, 23, 255];
  const WHITE = [250, 250, 250, 255];
  const DARK_FILL = [22, 22, 28, 255];
  const DARK_TEXT = [240, 240, 244, 255];

  function hex(color) {
    const m = /^#?([0-9a-f]{6})$/i.exec(color || '');
    const n = m ? parseInt(m[1], 16) : 0xfac726;
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255, 255];
  }

  /** [clear, black, accent, fill, text] for a bubble. */
  function palette({ accent, dark }) {
    return [[0, 0, 0, 0], BLACK, hex(accent), dark ? DARK_FILL : WHITE, dark ? DARK_TEXT : BLACK];
  }

  /** Paints a `w` x `h` grid of palette indices, each cell `scale` CSS pixels square. */
  function drawGrid(canvas, grid, colors) {
    const dpr = window.devicePixelRatio || 1;
    const cssW = grid.w * grid.scale; const cssH = grid.h * grid.scale;
    canvas.style.width = `${cssW}px`; canvas.style.height = `${cssH}px`;
    canvas.width = Math.max(1, Math.round(cssW * dpr));
    canvas.height = Math.max(1, Math.round(cssH * dpr));

    const source = document.createElement('canvas');
    source.width = grid.w; source.height = grid.h;
    const sctx = source.getContext('2d');
    const data = sctx.createImageData(grid.w, grid.h);
    for (let i = 0; i < grid.cells.length; i++) {
      const c = colors[grid.cells[i]] || colors[0];
      data.data[i * 4] = c[0]; data.data[i * 4 + 1] = c[1]; data.data[i * 4 + 2] = c[2]; data.data[i * 4 + 3] = c[3];
    }
    sctx.putImageData(data, 0, 0);

    const ctx = canvas.getContext('2d');
    ctx.imageSmoothingEnabled = false;
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    ctx.drawImage(source, 0, 0, canvas.width, canvas.height);
  }

  function roundedRect(grid, x0, y0, w, h, r, value) {
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        const hDist = Math.min(x, w - 1 - x);
        const vDist = Math.min(y, h - 1 - y);
        if (hDist < r && vDist < r) {
          const a = r - hDist - 0.5; const b = r - vDist - 0.5;
          if (a * a + b * b > r * r) continue;
        }
        const px = x0 + x; const py = y0 + y;
        if (px >= 0 && py >= 0 && px < grid.w && py < grid.h) grid.cells[py * grid.w + px] = value;
      }
    }
  }

  /**
   * The layered frame every bubble shares: black border, accent ring, fill.
   * `tail` adds the little side spike a compose bubble points at Bill with.
   */
  function frameGrid(wUnits, hUnits, { radius = 6, border = 1, ring = 1, tail = null } = {}) {
    const pad = tail ? 3 : 0;
    const grid = { w: wUnits + pad * 2, h: hUnits, scale: 2, cells: new Uint8Array((wUnits + pad * 2) * hUnits) };
    roundedRect(grid, pad, 0, wUnits, hUnits, radius, 1);
    roundedRect(grid, pad + border, border, wUnits - border * 2, hUnits - border * 2, Math.max(0, radius - border), 2);
    const inset = border + ring;
    roundedRect(grid, pad + inset, inset, wUnits - inset * 2, hUnits - inset * 2, Math.max(0, radius - inset), 3);
    if (tail) {
      const mid = Math.round(hUnits / 2);
      const column = (x, half, value) => { for (let y = mid - half; y < mid + half; y++) if (y >= 0 && y < hUnits) grid.cells[y * grid.w + x] = value; };
      const steps = [[[5, 1], [4, 2], [3, 3]], [[3, 1], [2, 2], [1, 3]], [[1, 1]]];
      steps.forEach((layers, i) => {
        const x = tail === 'left' ? pad - 1 - i : pad + wUnits + i;
        for (const [half, value] of layers) column(x, half, value);
      });
    }
    return grid;
  }

  /**
   * Keeps a pixel frame painted behind `element`, redrawn whenever it resizes.
   * The element needs `position: relative` and transparent background.
   * Options: { radius, border, ring, tail, accent (colour), dark }.
   */
  function attachFrame(element, options) {
    let canvas = element.querySelector(':scope > canvas.pixel-frame');
    if (!canvas) {
      canvas = document.createElement('canvas');
      canvas.className = 'pixel-frame';
      element.prepend(canvas);
    }
    element.pixelFrameOptions = options;
    const paint = () => {
      const opts = element.pixelFrameOptions;
      const w = Math.max(8, Math.round(element.offsetWidth / 2));
      const h = Math.max(8, Math.round(element.offsetHeight / 2));
      const grid = frameGrid(w, h, opts);
      drawGrid(canvas, grid, palette(opts));
      canvas.style.left = opts.tail ? '-6px' : '0';
      canvas.style.width = `${element.offsetWidth + (opts.tail ? 12 : 0)}px`;
      canvas.style.height = `${element.offsetHeight}px`;
    };
    if (!element.pixelFrameObserver) {
      element.pixelFrameObserver = new ResizeObserver(paint);
      element.pixelFrameObserver.observe(element);
    }
    paint();
  }

  window.PixelArt = { drawGrid, frameGrid, attachFrame, palette, hex };
})();
