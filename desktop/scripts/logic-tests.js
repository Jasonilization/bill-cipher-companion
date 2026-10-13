// `npm test`: the parts of Bill that need no display, checked in plain Node.
const assert = require('assert');
const path = require('path');
const src = (name) => require(path.join(__dirname, '..', 'src', name));

const { solveText, plain } = src('core/solver');
const { pick, LINES, MODE_NOTES } = src('core/modeLines');
const { TROUBLE } = (() => {
  // screenPlay pulls in Electron; the pattern is all that is needed here.
  const text = require('fs').readFileSync(path.join(__dirname, '..', 'src', 'app', 'screenPlay.js'), 'utf8');
  const match = /const TROUBLE = (\/.*\/i);/.exec(text);
  return { TROUBLE: match ? eval(match[1]) : null }; // eslint-disable-line no-eval
})();

let passed = 0;
const answers = (text, options) => solveText(text, options).problems.map((p) => p.answer);
const check = (text, expected, options) => {
  assert.deepStrictEqual(answers(text, options), expected, `solve "${text}"`);
  passed += 1;
};

// Arithmetic, the way people (and OCR) write it.
check('2 + 2', ['= 4']);
check('12 x 4 = ?', ['= 48']);
check('What is 45 × 12?', ['= 540']);
check('15% of 80', ['= 12']);
check('80 + 15%', ['= 92']);
check('20% off 50', ['= 40']);
check('3(4 + 1)', ['= 15']);
check('sqrt(144) + 3²', ['= 21']);
check('7!', ['= 5040']);
check('sin 30', ['= 0.5']);
check('1,234 + 1', ['= 1235']);
check('5 ÷ 0', ['DIVISION BY ZERO']);
check('1e5 + 1', ['= 100001']);

// Equations.
check('2x + 3 = 11', ['x = 4']);
check('3x - 7 = 2x + 5', ['x = 12']);
check('x² - 5x + 6 = 0', ['x = 2  or  x = 3']);
check('x2 + 2x + 1 = 0', ['x = -1']);
check('x^3 - 6x^2 + 11x - 6 = 0', ['x = 1  or  x = 2  or  x = 3']);
check('x/(x-2) = 2/(x-2)', ['NO SOLUTION']);
check('Solve for y: 4y + 2 = 18', ['y = 4']);
check('x + y = 10, x - y = 2', ['x = 6,  y = 4']);
check('2 + 2 = 5', ['FALSE. THE LEFT SIDE IS 4, THE RIGHT IS 5']);
check('(x + 2)(x - 3)', ['= x² − x − 6']);

// Things that only look like sums.
for (const text of ['2024-10-11', '12:30', 'version 1.2.3', '555-123-4567', 'File 3 - 4 of 20', 'hello world', 'page 3', 'x = 5']) check(text, []);

// A whole window: only lines that are plainly problems count.
check('Homework 4\nPage 3 - 4\n1. 12 x 4 =\n2. 3x + 2 = 14\nSaved 10-11-2026\nTotal 5 - 2', ['= 48', 'x = 4'], { strict: true });

assert.strictEqual(plain('x² − 5x ≈ 3 → ok'), 'x^2 - 5x ~ 3 -> ok'); passed += 1;

// Every mood line fits the bubble font: capitals, digits and plain punctuation.
for (const [key, pool] of Object.entries(LINES)) {
  assert.ok(pool.length > 0, `${key} has lines`);
  for (const line of pool) assert.ok(/^[A-Z0-9 .,!?'":;()\-]+$/.test(line), `${key}: "${line}"`);
  assert.ok(pick(key));
  passed += 1;
}
assert.ok(MODE_NOTES.troll && MODE_NOTES.helpful); passed += 1;

assert.ok(TROUBLE, 'the trouble pattern was found');
for (const title of ['Error: build failed', 'Microsoft Excel (Not Responding)', 'Traceback - Terminal', '404 Not Found']) assert.ok(TROUBLE.test(title), title);
for (const title of ['Inbox - Mail', 'main.js - Editor', 'Holiday photos']) assert.ok(!TROUBLE.test(title), title);
passed += 2;

console.log(`${passed} checks passed`);
