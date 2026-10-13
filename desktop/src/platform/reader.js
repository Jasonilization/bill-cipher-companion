// Bill's own eye for reading what is on the screen: Tesseract, compiled to
// WebAssembly and shipped with him (tesseract.js), with its English data. It
// runs on this computer, in a worker thread, and needs nothing installed.
//
// The operating system's reader (win32.js / linux.js `ocr`) is still what the
// background "read window contents" setting uses; this one is for the things
// the user asks him to read, where sums matter. Windows' built-in engine
// drops symbols it does not think are words: "3x + 2 = 14" comes back as "14".
const path = require('path');

const unpacked = (file) => file.replace(`app.asar${path.sep}`, `app.asar.unpacked${path.sep}`);

let available = false;
let tesseractDir = null;
let dataDir = null;
try {
  tesseractDir = path.dirname(require.resolve('tesseract.js/package.json'));
  dataDir = path.join(path.dirname(require.resolve('@tesseract.js-data/eng/package.json')), '4.0.0_best_int');
  available = true;
} catch { /* not installed: the OS reader is used instead */ }

let starting = null;
let queue = Promise.resolve();

function worker() {
  if (starting) return starting;
  starting = (async () => {
    const { createWorker } = require('tesseract.js');
    return createWorker('eng', 1, {
      langPath: unpacked(dataDir),
      workerPath: unpacked(path.join(tesseractDir, 'src', 'worker-script', 'node', 'index.js')),
      cacheMethod: 'none',
      gzip: true,
      errorHandler: () => {},
    });
  })();
  // A failed start is retried the next time he is asked to read.
  starting.catch(() => { starting = null; });
  return starting;
}

/** Text in a PNG: { text, confidence 0..100 } or null. `block` reads it as one paragraph, top to bottom. */
function read(png, { block = false } = {}) {
  if (!available) return Promise.resolve(null);
  const job = queue.then(async () => {
    const w = await worker();
    await w.setParameters({ tessedit_pageseg_mode: block ? '6' : '11', preserve_interword_spaces: '1' });
    const { data } = await w.recognize(png);
    return { text: String(data.text || ''), confidence: Number(data.confidence) || 0 };
  });
  queue = job.catch(() => null);
  return job.catch(() => null);
}

async function dispose() {
  const pending = starting;
  starting = null;
  if (!pending) return;
  try { (await pending).terminate(); } catch { /* never started */ }
}

module.exports = {
  get available() { return available; },
  detail: 'Bill\'s built-in reader (Tesseract)',
  read, dispose,
};
