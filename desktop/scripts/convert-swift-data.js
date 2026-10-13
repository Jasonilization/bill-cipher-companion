// Regenerates src/data/*.json from the Swift sources, so the Windows/Linux
// app speaks exactly the same lines and draws exactly the same pixel glyphs
// as the Mac app. Run with `npm run convert` after editing the Swift side.
const fs = require('fs');
const path = require('path');

const swiftRoot = path.join(__dirname, '..', '..', 'Sources', 'Bill');
const outDir = path.join(__dirname, '..', 'src', 'data');
fs.mkdirSync(outDir, { recursive: true });

function unescapeSwift(s) {
  return s
    .replace(/\\u\{([0-9a-fA-F]+)\}/g, (_, hex) => String.fromCodePoint(parseInt(hex, 16)))
    .replace(/\\n/g, '\n')
    .replace(/\\t/g, '\t')
    .replace(/\\"/g, '"')
    .replace(/\\'/g, "'")
    .replace(/\\\\/g, '\\');
}

// --- BarkLines ---------------------------------------------------------
const barkSrc = fs.readFileSync(path.join(swiftRoot, 'CharacterEngine', 'BarkLines.swift'), 'utf8').split(/\r?\n/);
const pools = {};
let current = null;
for (const line of barkSrc) {
  const start = line.match(/^\s*static let (\w+)\s*(?::\s*\[String\])?\s*=\s*\[\s*$/);
  if (start) { current = start[1]; pools[current] = []; continue; }
  if (current) {
    if (/^\s*\]\s*$/.test(line)) { current = null; continue; }
    const re = /"((?:[^"\\]|\\.)*)"/g;
    const code = line.replace(/\/\/.*$/, (m, offset) => {
      // keep `//` that lives inside a string literal
      const before = line.slice(0, offset);
      const quotes = (before.match(/(?<!\\)"/g) || []).length;
      return quotes % 2 === 1 ? m : '';
    });
    let m;
    while ((m = re.exec(code)) !== null) pools[current].push(unescapeSwift(m[1]));
  }
}
fs.writeFileSync(path.join(outDir, 'barklines.json'), JSON.stringify(pools, null, 1));

// --- Pixel font glyphs --------------------------------------------------
const bubbleSrc = fs.readFileSync(path.join(swiftRoot, 'Animation', 'BarkBubble.swift'), 'utf8').split(/\r?\n/);
const glyphs = {};
let inGlyphs = false;
for (const line of bubbleSrc) {
  if (/static let glyphs\s*:/.test(line)) { inGlyphs = true; continue; }
  if (!inGlyphs) continue;
  if (/^\s*\]\s*$/.test(line)) break;
  const m = line.match(/^\s*"((?:[^"\\]|\\.)+)"\s*:\s*\[(.*)\]\s*,?\s*$/);
  if (!m) continue;
  const rows = [...m[2].matchAll(/row\("([.#]+)"\)/g)].map((r) => r[1]);
  if (rows.length) glyphs[unescapeSwift(m[1])] = rows;
}
fs.writeFileSync(path.join(outDir, 'glyphs.json'), JSON.stringify(glyphs, null, 0));

const lineCount = Object.values(pools).reduce((n, p) => n + p.length, 0);
console.log(`barklines: ${Object.keys(pools).length} pools, ${lineCount} lines`);
console.log(`glyphs: ${Object.keys(glyphs).length} characters`);
