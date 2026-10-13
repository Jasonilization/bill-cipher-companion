// `npm run selftest`: launches Bill with BILL_SELFTEST=1 against a throwaway
// profile (your own settings and memory are not touched), waits for him to
// finish, and checks the report he wrote.
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');

const root = path.join(__dirname, '..');
const out = path.resolve(process.env.BILL_SELFTEST_DIR || path.join(os.tmpdir(), 'bill-selftest'));
const profile = path.join(out, 'profile');
fs.rmSync(out, { recursive: true, force: true });
fs.mkdirSync(profile, { recursive: true });

const electron = require('electron'); // the path to the binary, when required from plain Node
const env = { ...process.env, BILL_SELFTEST: '1', BILL_SELFTEST_DIR: out, BILL_USER_DATA: profile };
// Set at all (even empty), this makes Electron behave as plain Node.
delete env.ELECTRON_RUN_AS_NODE;
const child = spawn(electron, [root, ...process.argv.slice(2)], { stdio: 'inherit', env });

child.on('exit', (code) => {
  let report;
  try { report = JSON.parse(fs.readFileSync(path.join(out, 'report.json'), 'utf8')); } catch {
    console.error(`self-test: no report was written (exit code ${code})`);
    process.exit(1);
  }
  const problems = [...report.errors];
  if (!report.sprites || report.sprites.loaded !== report.sprites.expected) problems.push('not every sprite sheet loaded');
  for (const name of ['bill-idle', 'bark', 'chat-response', 'panel-settings']) {
    const image = report.images[name];
    if (!image || image.painted === 0) problems.push(`${name}: nothing was painted`);
  }
  if (!report.os || !report.os.menuItems) problems.push('the menu did not build');
  if (report.solve && report.solve.ocr && report.solve.answers.length < 2) problems.push('screen solving read too little');
  for (const beat of report.roam || []) if (!beat.finished) problems.push('a roaming beat never finished');

  console.log(`self-test: ${report.backend} backend, Electron ${report.electron}, ${Object.keys(report.images).length} captures in ${out}`);
  if (report.solve) console.log(`  screen solving: ${report.solve.ocr ? report.solve.answers.join(' | ') || 'nothing solved' : 'no screen reader on this machine'}`);
  if (problems.length) {
    console.error(`self-test FAILED:\n  - ${problems.join('\n  - ')}`);
    process.exit(1);
  }
  console.log('self-test passed');
});
