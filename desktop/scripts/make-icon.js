// Builds build/icon.png (the app, installer and tray icon) from Bill's rest
// frame. Run with `npm run icon`; it needs Electron only for PNG decoding.
//
// The sprite is pixel art, so it is scaled by a whole number with no
// smoothing: every source pixel becomes a crisp square.
const fs = require('fs');
const path = require('path');
const { app, nativeImage } = require('electron');

const SIZE = 512;
const PADDING = 20;
const source = path.join(__dirname, '..', '..', 'Sources', 'Bill', 'Resources', 'Sprites', 'bill_idle_01.png');
const target = path.join(__dirname, '..', 'build', 'icon.png');

app.whenReady().then(() => {
  const sprite = nativeImage.createFromPath(source);
  if (sprite.isEmpty()) throw new Error(`cannot read ${source}`);
  const { width, height } = sprite.getSize();
  const pixels = sprite.toBitmap();

  // Trim the transparent margin so he fills the icon.
  let minX = width; let minY = height; let maxX = -1; let maxY = -1;
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      if (pixels[(y * width + x) * 4 + 3] === 0) continue;
      if (x < minX) minX = x; if (x > maxX) maxX = x;
      if (y < minY) minY = y; if (y > maxY) maxY = y;
    }
  }
  const w = maxX - minX + 1; const h = maxY - minY + 1;
  const factor = Math.max(1, Math.floor((SIZE - PADDING * 2) / Math.max(w, h)));
  const left = Math.floor((SIZE - w * factor) / 2); const top = Math.floor((SIZE - h * factor) / 2);

  const out = Buffer.alloc(SIZE * SIZE * 4);
  for (let y = 0; y < h * factor; y++) {
    const sy = minY + Math.floor(y / factor);
    for (let x = 0; x < w * factor; x++) {
      const from = (sy * width + minX + Math.floor(x / factor)) * 4;
      pixels.copy(out, ((top + y) * SIZE + left + x) * 4, from, from + 4);
    }
  }

  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, nativeImage.createFromBitmap(out, { width: SIZE, height: SIZE }).toPNG());
  console.log(`wrote ${target} (${w}x${h} sprite at ${factor}x)`);
  app.quit();
}).catch((error) => { console.error(error); app.exit(1); });
