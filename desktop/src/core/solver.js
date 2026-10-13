// Bill's own head for sums.
//
// When he reads a problem off the screen he tries it himself first: arithmetic,
// percentages, equations in one unknown (linear, quadratic, and numerically
// beyond that) and small linear systems are answered on the spot, with the
// working, with no network and no account. Anything wordier goes to the chat
// brain instead (see app/helper.js).
//
// Nothing here evaluates text as code: it is a tokenizer and a small
// recursive-descent parser over polynomial fractions.

class NotMath extends Error {}
/** It is a sum, but one with no answer (division by zero, a root of a negative…). */
class Trouble extends Error {}

const EPS = 1e-12;
const MAX_LINE = 140;
const MAX_DEGREE = 8;

// ------------------------------------------------------------- polynomials
// A value is a fraction of two multivariate polynomials. A polynomial is a
// Map from a monomial key ("" for the constant, "x^2*y^1"…) to a coefficient.
const parseKey = (key) => (key ? key.split('*').map((part) => { const [v, e] = part.split('^'); return [v, Number(e)]; }) : []);
const makeKey = (pairs) => pairs.filter(([, e]) => e !== 0).sort((a, b) => (a[0] < b[0] ? -1 : 1)).map(([v, e]) => `${v}^${e}`).join('*');
function monoMul(a, b) {
  if (!a) return b;
  if (!b) return a;
  const m = new Map(parseKey(a));
  for (const [v, e] of parseKey(b)) m.set(v, (m.get(v) || 0) + e);
  return makeKey([...m]);
}
const monoDegree = (key) => parseKey(key).reduce((sum, [, e]) => sum + e, 0);

const poly = (n) => new Map(Math.abs(n) > 0 ? [['', n]] : []);
function pTidy(p) { for (const [k, c] of p) if (Math.abs(c) < EPS) p.delete(k); return p; }
function pAdd(a, b, sign = 1) {
  const out = new Map(a);
  for (const [k, c] of b) out.set(k, (out.get(k) || 0) + sign * c);
  return pTidy(out);
}
function pMul(a, b) {
  const out = new Map();
  if (a.size * b.size > 400) throw new NotMath('too big');
  for (const [ka, ca] of a) for (const [kb, cb] of b) { const k = monoMul(ka, kb); out.set(k, (out.get(k) || 0) + ca * cb); }
  return pTidy(out);
}
const pScale = (a, f) => pTidy(new Map([...a].map(([k, c]) => [k, c * f])));
const pIsConst = (p) => p.size === 0 || (p.size === 1 && p.has(''));
const pConst = (p) => p.get('') || 0;
const pVars = (p) => { const s = new Set(); for (const k of p.keys()) for (const [v] of parseKey(k)) s.add(v); return s; };

/** Divides the constant out of the denominator, so "is this a plain number" is one check. */
function value(n, d = poly(1), flags = {}) {
  if (pIsConst(d)) {
    const k = pConst(d);
    if (Math.abs(k) < EPS) throw new Trouble('DIVISION BY ZERO');
    return { n: k === 1 ? n : pScale(n, 1 / k), d: poly(1), ...flags };
  }
  return { n, d, ...flags };
}
const num = (x, flags) => value(poly(x), poly(1), flags);
const isNumber = (v) => pIsConst(v.n) && pIsConst(v.d);
const numberOf = (v) => pConst(v.n);

const add = (a, b, sign = 1) => value(pAdd(pMul(a.n, b.d), pMul(b.n, a.d), sign), pMul(a.d, b.d), { rad: a.rad || b.rad });
const mul = (a, b) => value(pMul(a.n, b.n), pMul(a.d, b.d), { rad: a.rad || b.rad });
function div(a, b) {
  if (b.n.size === 0) throw new Trouble('DIVISION BY ZERO');
  return value(pMul(a.n, b.d), pMul(a.d, b.n), { rad: a.rad || b.rad });
}
function pow(base, exponent) {
  if (!isNumber(exponent)) throw new NotMath('variable exponent');
  const e = numberOf(exponent);
  if (isNumber(base)) {
    const b = numberOf(base);
    if (b === 0 && e < 0) throw new Trouble('DIVISION BY ZERO');
    const out = Math.pow(b, e);
    if (Number.isNaN(out)) throw new Trouble('NOT A REAL NUMBER');
    if (!Number.isFinite(out)) throw new Trouble('TOO BIG EVEN FOR ME');
    return num(out, { rad: base.rad });
  }
  if (!Number.isInteger(e) || Math.abs(e) > MAX_DEGREE) throw new NotMath('unsupported power');
  let n = poly(1); let d = poly(1);
  for (let i = 0; i < Math.abs(e); i++) { n = pMul(n, base.n); d = pMul(d, base.d); }
  return e >= 0 ? value(n, d) : value(d, n);
}

// --------------------------------------------------------------- functions
const FUNCTIONS = {
  sqrt: (x) => { if (x < 0) throw new Trouble(`NOT A REAL NUMBER (${fmt(Math.sqrt(-x))}i)`); return Math.sqrt(x); },
  cbrt: Math.cbrt, abs: Math.abs, exp: Math.exp, floor: Math.floor, ceil: Math.ceil, round: Math.round,
  ln: (x) => { if (x <= 0) throw new Trouble('NO LOGARITHM OF ZERO OR LESS'); return Math.log(x); },
  log: (x) => { if (x <= 0) throw new Trouble('NO LOGARITHM OF ZERO OR LESS'); return Math.log10(x); },
  sin: Math.sin, cos: Math.cos, tan: Math.tan,
};
const TRIG = new Set(['sin', 'cos', 'tan']);

function factorial(x) {
  if (!Number.isInteger(x) || x < 0) throw new Trouble('FACTORIALS NEED A WHOLE NUMBER');
  if (x > 170) throw new Trouble('TOO BIG EVEN FOR ME');
  let out = 1;
  for (let i = 2; i <= x; i++) out *= i;
  return out;
}

// --------------------------------------------------------------- tidying up
const LIST_MARKER = /^\s*(?:\(?\d{1,3}[.)]\s+|\(?[a-hA-H][.)]\s+|[Qq]\d{1,3}[.:)]?\s+|[•·▪●○◦*]\s+|-\s+(?=\S))/;
const ASK_PREFIX = /^\s*(?:solve(?: for [a-z])?|simplify|expand|evaluate|calculate|compute|work out|find(?: the value of)?(?: [a-z])?(?: if| when)?|what is|what's|whats|how much is)\b[\s:,]*/i;
const SUPERSCRIPT = { '⁰': '0', '¹': '1', '²': '2', '³': '3', '⁴': '4', '⁵': '5', '⁶': '6', '⁷': '7', '⁸': '8', '⁹': '9' };
const VULGAR = { '½': '1/2', '⅓': '1/3', '⅔': '2/3', '¼': '1/4', '¾': '3/4', '⅕': '1/5', '⅛': '1/8' };
const VULGAR_SET = '½⅓⅔¼¾⅕⅛';

/** What the user sees as "the problem": the line without its list number. */
function tidy(raw) {
  return String(raw || '').replace(/\s+/g, ' ').replace(LIST_MARKER, '').trim();
}

/** Dates, clock times, versions and phone numbers all look like subtraction and division. They are not. */
function looksLikeSomethingElse(s) {
  return /\b\d{1,4}[-/.]\d{1,2}[-/.]\d{2,4}\b/.test(s) || /\b\d{1,2}:\d{2}\b/.test(s) || /\b\d+\.\d+\.\d+/.test(s)
    || /\b\d{3}[-\s]\d{3,4}[-\s]\d{4}\b/.test(s) || /\b\d+\s*-\s*\d+\s+of\s+\d+/i.test(s);
}

/** Turns what a person (or an OCR engine) writes into plain operator text. */
function normalise(source) {
  let s = ` ${source} `;
  const asked = ASK_PREFIX.test(s.trimStart()) || /=\s*(?:\?+|_+|\.{2,}|…|□|▢)?\s*$/.test(s.trimEnd());
  s = s.trimStart().replace(ASK_PREFIX, '');
  s = s.replace(/[$€£¥]/g, '').replace(/[−–—‒﹣－]/g, '-');
  s = s.replace(/[×✕✖⨯∗·⋅∙]/g, '*').replace(/[÷∕⁄]/g, '/').replace(/\*\*/g, '^');
  s = s.replace(/[⁰¹²³⁴⁵⁶⁷⁸⁹]+/g, (run) => `^${[...run].map((ch) => SUPERSCRIPT[ch]).join('')}`);
  s = s.replace(new RegExp(`(\\d+)\\s*([${VULGAR_SET}])`, 'g'), (_m, whole, f) => `(${whole}+${VULGAR[f]})`);
  s = s.replace(new RegExp(`[${VULGAR_SET}]`, 'g'), (f) => `(${VULGAR[f]})`);
  s = s.replace(/∛/g, ' cbrt ').replace(/√/g, ' sqrt ').replace(/π/g, ' pi ');
  s = s.replace(/\bmultiplied by\b|\btimes\b/gi, '*').replace(/\bdivided by\b/gi, '/');
  s = s.replace(/\bplus\b/gi, '+').replace(/\bminus\b/gi, '-');
  s = s.replace(/\b(?:raised )?to the power(?: of)?\b/gi, '^').replace(/\bsquared\b/gi, '^2').replace(/\bcubed\b/gi, '^3');
  s = s.replace(/\b(?:the )?square root of\b/gi, ' sqrt ').replace(/\b(?:the )?cube root of\b/gi, ' cbrt ');
  s = s.replace(/\bpercent\b/gi, '%').replace(/\bmodulo\b/gi, ' mod ');
  // "20% off 50" is fifty with a fifth taken away; "15% of 80" is a product.
  s = s.replace(/(\d+(?:\.\d+)?)\s*%\s*off\s+(?:of\s+)?(\d+(?:\.\d+)?)/gi, '($2*(1-$1/100))');
  s = s.replace(/%\s*of\b/gi, '% *').replace(/\)\s*of\b/gi, ') *');
  // 1,234,567 is one number; 3,5 is how half of Europe writes 3.5.
  s = s.replace(/\b\d{1,3}(?:,\d{3})+\b/g, (m) => m.replace(/,/g, ''));
  s = s.replace(/(\d),(\d{1,2})(?!\d)/g, '$1.$2');
  // The answer blank: "12 x 4 = ?" asks for the left side.
  s = s.replace(/=\s*(?:\?+|_+|\.{2,}|…|□|▢)?\s*$/, '=').replace(/[?.;,:]+\s*$/, '');
  s = s.replace(/==/g, '=');
  // A letter x between two numbers is a multiplication sign someone typed (or OCR read).
  s = s.replace(/(\d)\s*[xX]\s*(?=\d)/g, '$1*');
  const twoSided = /[^=\s]\s*=\s*[^=\s]/.test(s);
  if (!twoSided) s = s.replace(/([\d)])\s*[xX]\s*(?=\()/g, '$1*');
  return { text: s.trim(), asked };
}

// ---------------------------------------------------------------- tokenizer
const PAIRS = new Set(['xy', 'yx', 'xz', 'zx', 'yz', 'zy', 'ab', 'ba']);

function tokenize(s) {
  const tokens = [];
  let i = 0;
  while (i < s.length) {
    const ch = s[i];
    if (/\s/.test(ch)) { i += 1; continue; }
    const rest = s.slice(i);
    let m = /^(?:\d+\.\d+|\d+|\.\d+)(?:[eE][+-]?\d+(?![\w.]))?/.exec(rest);
    if (m) { tokens.push({ t: 'num', v: parseFloat(m[0]) }); i += m[0].length; continue; }
    m = /^[a-zA-Z]+/.exec(rest);
    if (m) {
      const word = m[0].toLowerCase();
      i += m[0].length;
      if (FUNCTIONS[word]) tokens.push({ t: 'fn', v: word });
      else if (word === 'pi') tokens.push({ t: 'pi' });
      else if (word === 'mod') tokens.push({ t: 'op', v: 'mod' });
      else if (word === 'e' && /^\s*\^/.test(s.slice(i))) tokens.push({ t: 'e' });
      else if (word.length === 1 || PAIRS.has(word)) {
        for (const letter of word) tokens.push({ t: 'var', v: letter });
        // OCR flattens x² to x2: a lone digit glued to a variable is its exponent.
        if (/^[2-9](?![\d.])/.test(s.slice(i))) { tokens.push({ t: 'op', v: '^' }, { t: 'num', v: Number(s[i]) }); i += 1; }
      } else throw new NotMath(`a word: ${word}`);
      continue;
    }
    if ('+-*/^()=!%|°'.includes(ch)) { tokens.push({ t: 'op', v: ch }); i += 1; continue; }
    throw new NotMath(`unexpected ${ch}`);
  }
  return tokens;
}

// ------------------------------------------------------------------- parser
class Parser {
  constructor(tokens) {
    this.tokens = tokens; this.pos = 0; this.ops = 0; this.bars = 0;
    this.notes = []; this.vars = new Set();
  }
  peek() { return this.tokens[this.pos]; }
  next() { return this.tokens[this.pos++]; }
  isOp(v) { const t = this.peek(); return !!t && t.t === 'op' && t.v === v; }
  expect(v) { if (!this.isOp(v)) throw new NotMath(`expected ${v}`); this.pos += 1; }
  get done() { return this.pos >= this.tokens.length; }

  startsPrimary() {
    const t = this.peek();
    if (!t) return false;
    if (t.t === 'num') {
      // "2 3" is two numbers, not six.
      const before = this.tokens[this.pos - 1];
      if (before && before.t === 'num') throw new NotMath('two numbers in a row');
      return true;
    }
    if (t.t === 'var' || t.t === 'fn' || t.t === 'pi' || t.t === 'e') return true;
    return t.t === 'op' && (t.v === '(' || (t.v === '|' && this.bars === 0));
  }

  expression() {
    let left = this.term();
    while (this.isOp('+') || this.isOp('-')) {
      const op = this.next().v;
      let right = this.term();
      this.ops += 1;
      // "80 + 15%" means fifteen percent *of the eighty*, as on any calculator.
      if (right.percent && !left.percent && isNumber(left)) right = mul(left, right);
      left = add(left, right, op === '+' ? 1 : -1);
    }
    return left;
  }

  term() {
    let left = this.unary();
    for (;;) {
      if (this.isOp('*') || this.isOp('/')) {
        const op = this.next().v;
        const right = this.unary();
        this.ops += 1;
        left = op === '*' ? mul(left, right) : div(left, right);
      } else if (this.isOp('mod')) {
        this.next();
        const right = this.unary();
        this.ops += 1;
        if (!isNumber(left) || !isNumber(right)) throw new NotMath('mod of a variable');
        if (numberOf(right) === 0) throw new Trouble('DIVISION BY ZERO');
        left = num(((numberOf(left) % numberOf(right)) + numberOf(right)) % numberOf(right));
      } else if (this.startsPrimary()) {
        // Implicit multiplication: 2x, 3(4 + 1), (a)(b), 2 sqrt 9.
        const right = this.power();
        this.ops += 1;
        left = mul(left, right);
      } else return left;
    }
  }

  unary() {
    if (this.isOp('-')) { this.next(); return mul(num(-1), this.unary()); }
    if (this.isOp('+')) { this.next(); return this.unary(); }
    return this.power();
  }

  power() {
    let base = this.postfix();
    if (this.isOp('^')) {
      this.next();
      const exponent = this.unary();
      this.ops += 1;
      base = pow(base, exponent);
    }
    return base;
  }

  postfix() {
    let v = this.primary();
    for (;;) {
      if (this.isOp('!')) {
        this.next(); this.ops += 1;
        if (!isNumber(v)) throw new NotMath('factorial of a variable');
        v = num(factorial(numberOf(v)));
      } else if (this.isOp('%')) {
        this.next(); this.ops += 1;
        if (!isNumber(v)) throw new NotMath('percent of a variable');
        v = num(numberOf(v) / 100, { percent: true });
      } else if (this.isOp('°')) {
        this.next();
        if (!isNumber(v)) throw new NotMath('degrees of a variable');
        v = num(numberOf(v) * Math.PI / 180, { rad: true });
      } else return v;
    }
  }

  primary() {
    const tok = this.next();
    if (!tok) throw new NotMath('incomplete');
    if (tok.t === 'num') return num(tok.v);
    if (tok.t === 'pi') return num(Math.PI, { rad: true });
    if (tok.t === 'e') return num(Math.E);
    if (tok.t === 'var') { this.vars.add(tok.v); return value(new Map([[`${tok.v}^1`, 1]])); }
    if (tok.t === 'fn') {
      let arg;
      if (this.isOp('(')) { this.next(); arg = this.expression(); this.expect(')'); } else arg = this.unary();
      this.ops += 1;
      return this.apply(tok.v, arg);
    }
    if (tok.t === 'op' && tok.v === '(') {
      const inner = this.expression();
      this.expect(')');
      return value(inner.n, inner.d, { rad: inner.rad });
    }
    if (tok.t === 'op' && tok.v === '|' && this.bars === 0) {
      this.bars += 1;
      const inner = this.expression();
      this.expect('|');
      this.bars -= 1;
      this.ops += 1;
      return this.apply('abs', inner);
    }
    throw new NotMath('unexpected token');
  }

  apply(name, arg) {
    if (!isNumber(arg)) throw new NotMath(`${name} of a variable`);
    let x = numberOf(arg);
    if (TRIG.has(name) && !arg.rad && Number.isInteger(x) && x !== 0 && x % 15 === 0) {
      // sin 30 on a worksheet is thirty degrees; sin(pi/6) says so itself.
      this.notes.push(`TAKING ${fmt(x)} AS DEGREES`);
      x = x * Math.PI / 180;
    }
    let out = FUNCTIONS[name](x);
    if (TRIG.has(name)) {
      if (name === 'tan' && Math.abs(Math.cos(x)) < 1e-12) throw new Trouble('UNDEFINED (TAN OF A RIGHT ANGLE)');
      if (Math.abs(out) < 1e-12) out = 0;
    }
    if (!Number.isFinite(out)) throw new Trouble('NOT A REAL NUMBER');
    return num(out);
  }
}

function parse(text) {
  const parser = new Parser(tokenize(text));
  if (parser.done) throw new NotMath('empty');
  const result = parser.expression();
  if (!parser.done) throw new NotMath('trailing tokens');
  return { result, parser };
}

// ---------------------------------------------------------------- printing
function fmt(n) {
  if (!Number.isFinite(n)) return String(n);
  if (Math.abs(n) < 1e-12) return '0';
  const rounded = Math.round(n);
  if (Math.abs(n - rounded) < 1e-9 * Math.max(1, Math.abs(n)) && Math.abs(rounded) < 1e15) return String(rounded);
  return String(parseFloat(n.toPrecision(10)));
}

/** p/q when the number is a simple fraction that does not print cleanly as a decimal. */
function asFraction(n, maxDenominator = 1000) {
  if (!Number.isFinite(n) || Number.isInteger(n)) return null;
  const sign = n < 0 ? -1 : 1;
  let x = Math.abs(n);
  let [p0, q0, p1, q1] = [0, 1, 1, 0];
  for (let i = 0; i < 24; i++) {
    const a = Math.floor(x);
    [p0, q0, p1, q1] = [p1, q1, a * p1 + p0, a * q1 + q0];
    if (q1 > maxDenominator) return null;
    if (Math.abs(Math.abs(n) - p1 / q1) < 1e-10) return q1 > 1 ? `${sign * p1}/${q1}` : null;
    const frac = x - a;
    if (frac < 1e-12) return null;
    x = 1 / frac;
  }
  return null;
}

/** A number the way an answer should read: exact where it can be, rounded where it cannot. */
function fmtAnswer(n) {
  const text = fmt(n);
  const decimals = (text.split('.')[1] || '').length;
  if (decimals <= 4 || text.includes('e')) return text;
  const fraction = asFraction(n);
  if (fraction) return `${fraction} (≈ ${parseFloat(n.toFixed(4))})`;
  return `≈ ${parseFloat(n.toPrecision(7))}`;
}
const equals = (name, n) => { const a = fmtAnswer(n); return a.startsWith('≈') ? `${name} ${a}` : `${name} = ${a}`; };

const SUPER = ['⁰', '¹', '²', '³', '⁴', '⁵', '⁶', '⁷', '⁸', '⁹'];
const superscript = (e) => String(e).split('').map((d) => SUPER[Number(d)]).join('');

function polyToString(p) {
  const terms = [...p].sort((a, b) => monoDegree(b[0]) - monoDegree(a[0]) || (a[0] < b[0] ? -1 : 1));
  if (!terms.length) return '0';
  let out = '';
  terms.forEach(([key, c], index) => {
    const letters = parseKey(key).map(([v, e]) => (e === 1 ? v : `${v}${superscript(e)}`)).join('');
    const magnitude = Math.abs(c);
    const body = !letters ? fmt(magnitude) : Math.abs(magnitude - 1) < 1e-12 ? letters : `${fmt(magnitude)}${letters}`;
    if (index === 0) out += c < 0 ? `−${body}` : body;
    else out += c < 0 ? ` − ${body}` : ` + ${body}`;
  });
  return out;
}

/** For speech bubbles drawn in the pixel font, which has no ² or ÷. */
function plain(text) {
  return String(text).replace(/−/g, '-').replace(/×/g, 'x').replace(/÷/g, '/').replace(/≈/g, '~').replace(/→/g, '->')
    .replace(/±/g, '+/-').replace(/√/g, 'sqrt ').replace(/π/g, 'pi').replace(/[⁰¹²³⁴⁵⁶⁷⁸⁹]+/g, (run) => `^${[...run].map((ch) => SUPERSCRIPT[ch]).join('')}`);
}

// ------------------------------------------------------------------ solving
function coefficients(p, variable) {
  const out = [];
  for (const [key, c] of p) {
    const pairs = parseKey(key);
    if (pairs.length > 1 || (pairs.length === 1 && pairs[0][0] !== variable)) throw new NotMath('more than one unknown');
    const degree = pairs.length ? pairs[0][1] : 0;
    if (degree > MAX_DEGREE) throw new NotMath('degree too high');
    out[degree] = (out[degree] || 0) + c;
  }
  for (let i = 0; i < out.length; i++) out[i] = out[i] || 0;
  while (out.length > 1 && Math.abs(out[out.length - 1]) < EPS) out.pop();
  return out.length ? out : [0];
}
const evaluate = (coeffs, x) => coeffs.reduceRight((acc, c) => acc * x + c, 0);

/** Every root of a polynomial at once (Durand–Kerner), for degrees with no tidy formula. */
function numericRoots(coeffs) {
  const n = coeffs.length - 1;
  const lead = coeffs[n];
  const c = coeffs.map((k) => k / lead);
  let roots = Array.from({ length: n }, (_v, i) => { const angle = 2 * Math.PI * i / n + 0.4; const r = 1 + Math.max(...c.slice(0, n).map(Math.abs)); return [r * Math.cos(angle) * 0.6, r * Math.sin(angle) * 0.6]; });
  const cmul = (a, b) => [a[0] * b[0] - a[1] * b[1], a[0] * b[1] + a[1] * b[0]];
  const cdiv = (a, b) => { const m = b[0] * b[0] + b[1] * b[1]; return [(a[0] * b[0] + a[1] * b[1]) / m, (a[1] * b[0] - a[0] * b[1]) / m]; };
  for (let iteration = 0; iteration < 400; iteration++) {
    let moved = 0;
    roots = roots.map((root, i) => {
      let top = [0, 0];
      for (let k = n; k >= 0; k--) { top = cmul(top, root); top[0] += c[k]; }
      let bottom = [1, 0];
      for (let j = 0; j < n; j++) if (j !== i) bottom = cmul(bottom, [root[0] - roots[j][0], root[1] - roots[j][1]]);
      if (bottom[0] === 0 && bottom[1] === 0) return root;
      const step = cdiv(top, bottom);
      moved = Math.max(moved, Math.abs(step[0]) + Math.abs(step[1]));
      return [root[0] - step[0], root[1] - step[1]];
    });
    if (moved < 1e-13) break;
  }
  const real = [];
  for (const [re, im] of roots) {
    if (Math.abs(im) > 1e-7 * Math.max(1, Math.abs(re))) continue;
    const polished = Math.abs(re - Math.round(re)) < 1e-7 ? Math.round(re) : re;
    if (!real.some((r) => Math.abs(r - polished) < 1e-6)) real.push(polished);
  }
  return real.sort((a, b) => a - b);
}

function solveForOne(numerator, denominator, variable) {
  const c = coefficients(numerator, variable);
  const dCoeffs = coefficients(denominator, variable);
  const allowed = (x) => Math.abs(evaluate(dCoeffs, x)) > 1e-9;
  const degree = c.length - 1;
  const standard = `${polyToString(numerator)} = 0`;
  const steps = [];
  let roots = [];
  let answer = null;

  if (degree === 0) {
    return { answer: Math.abs(c[0]) < 1e-9 ? `TRUE FOR EVERY ${variable}` : 'NO SOLUTION', steps: [] };
  }
  if (degree === 1) {
    roots = [-c[0] / c[1]];
    steps.push(`COLLECT TERMS: ${standard}`);
    if (Math.abs(c[1] - 1) > EPS) steps.push(`${variable} = ${fmt(-c[0])} ÷ ${fmt(c[1])}`);
  } else if (degree === 2) {
    const [k, b, a] = c;
    const disc = b * b - 4 * a * k;
    steps.push(`STANDARD FORM: ${standard}`);
    steps.push(`DISCRIMINANT: b² − 4ac = ${fmt(disc)}`);
    if (disc < -1e-12) {
      const re = -b / (2 * a); const im = Math.sqrt(-disc) / Math.abs(2 * a);
      const left = Math.abs(re) < 1e-12 ? '' : `${fmt(re)} `;
      answer = `NO REAL SOLUTION (${variable} = ${left}± ${fmt(im)}i)`;
    } else {
      const root = Math.sqrt(Math.max(0, disc));
      steps.push(`${variable} = (${fmt(-b)} ± ${fmt(root)}) ÷ ${fmt(2 * a)}`);
      roots = root < 1e-12 ? [-b / (2 * a)] : [(-b - root) / (2 * a), (-b + root) / (2 * a)].sort((x, y) => x - y);
    }
  } else {
    steps.push(`STANDARD FORM: ${standard}`);
    steps.push('NO TIDY FORMULA AT THIS DEGREE, SO I HUNTED THE ROOTS DOWN NUMERICALLY');
    roots = numericRoots(c);
    if (!roots.length) answer = 'NO REAL SOLUTION';
  }

  if (answer === null) {
    const kept = roots.filter(allowed);
    for (const root of roots) if (!allowed(root)) steps.push(`${variable} = ${fmt(root)} IS OUT: IT DIVIDES BY ZERO`);
    answer = kept.length ? kept.map((root) => equals(variable, root)).join('  or  ') : 'NO SOLUTION';
  }
  return { answer, steps };
}

/** One equation in several unknowns, if it is linear: the row it contributes to a system. */
function linearRow(numerator, denominator) {
  if (!pIsConst(denominator)) return null;
  const row = { coeffs: new Map(), constant: 0 };
  for (const [key, c] of numerator) {
    const pairs = parseKey(key);
    if (!pairs.length) { row.constant += c; continue; }
    if (pairs.length > 1 || pairs[0][1] !== 1) return null;
    row.coeffs.set(pairs[0][0], c);
  }
  return row;
}

function solveSystem(pending) {
  const variables = [...new Set(pending.flatMap((p) => [...p.multi.coeffs.keys()]))].sort();
  const n = variables.length;
  if (n !== pending.length || n < 2 || n > 4) return null;
  const m = pending.map((p) => [...variables.map((v) => p.multi.coeffs.get(v) || 0), -p.multi.constant]);
  for (let col = 0; col < n; col++) {
    let pivot = col;
    for (let r = col + 1; r < n; r++) if (Math.abs(m[r][col]) > Math.abs(m[pivot][col])) pivot = r;
    if (Math.abs(m[pivot][col]) < 1e-10) return null;
    [m[col], m[pivot]] = [m[pivot], m[col]];
    for (let r = 0; r < n; r++) {
      if (r === col) continue;
      const f = m[r][col] / m[col][col];
      for (let k = col; k <= n; k++) m[r][k] -= f * m[col][k];
    }
  }
  const answer = variables.map((v, i) => equals(v, m[i][n] / m[i][i])).join(',  ');
  return {
    source: pending.map((p) => p.source).join('   and   '), kind: 'system', answer,
    steps: [`${n} EQUATIONS, ${n} UNKNOWNS: ELIMINATE ONE AT A TIME`],
  };
}

/**
 * One line of text as a problem. Returns null when it is not one,
 * `{ source, kind, answer, steps }` when it is, or `{ source, multi }` for an
 * equation that needs its siblings (a system).
 */
function solveLine(raw, { strict = false, ocr = false } = {}) {
  const source = tidy(ocr ? repairOcr(raw) : raw);
  if (!source || source.length > MAX_LINE || !/\d/.test(source) || looksLikeSomethingElse(source)) return null;
  const symbolic = /[×÷√^²³∛]|\bsqrt\b|\*/.test(source);
  const { text, asked } = normalise(source);
  const sides = text.split('=');
  if (sides.length > 2 || !sides[0].trim()) return null;
  const isEquation = sides.length === 2 && sides[1].trim() !== '';
  try {
    if (!isEquation) {
      const { result, parser } = parse(sides[0]);
      if (parser.ops < 1) return null;
      if (isNumber(result)) {
        if (strict && !asked && !symbolic) return null;
        return { source, kind: 'arithmetic', answer: fmtAnswer(numberOf(result)).replace(/^(?!≈)/, '= '), steps: [...parser.notes] };
      }
      // Something with a letter in it and no equals sign: all there is to do is tidy it.
      if (strict || !pIsConst(result.d) || (parser.ops < 2 && !symbolic)) return null;
      const simplified = polyToString(result.n);
      if (simplified.replace(/\s/g, '') === source.replace(/\s/g, '')) return null;
      return { source, kind: 'simplify', answer: `= ${simplified}`, steps: [] };
    }

    const left = parse(sides[0]); const right = parse(sides[1]);
    const ops = left.parser.ops + right.parser.ops;
    const notes = [...left.parser.notes, ...right.parser.notes];
    const numerator = pAdd(pMul(left.result.n, right.result.d), pMul(right.result.n, left.result.d), -1);
    const denominator = pMul(left.result.d, right.result.d);
    const unknowns = [...new Set([...pVars(numerator), ...pVars(denominator)])];
    const written = new Set([...left.parser.vars, ...right.parser.vars]);

    if (written.size === 0) {
      if (ops < 1 || (strict && !symbolic && !asked)) return null;
      const a = numberOf(left.result); const b = numberOf(right.result);
      const same = Math.abs(a - b) < 1e-9 * Math.max(1, Math.abs(a), Math.abs(b));
      // A reader turns the blank in "7 x 8 = ?" into a 7: give the value rather than a verdict.
      if (!same && ocr) return { source, kind: 'check', answer: `= ${fmt(a)}  (NOT ${fmt(b)}, IF THAT IS WHAT IT SAYS)`, steps: notes };
      return { source, kind: 'check', answer: same ? `TRUE. BOTH SIDES ARE ${fmt(a)}` : `FALSE. THE LEFT SIDE IS ${fmt(a)}, THE RIGHT IS ${fmt(b)}`, steps: notes };
    }
    if (ops < 1) return null;
    if (unknowns.length > 1) {
      const row = linearRow(numerator, denominator);
      return row ? { source, multi: row } : null;
    }
    const variable = unknowns[0] || [...written][0];
    const solved = solveForOne(numerator, denominator, variable);
    return { source, kind: 'equation', answer: solved.answer, steps: [...notes, ...solved.steps] };
  } catch (error) {
    if (error instanceof Trouble) return { source, kind: 'undefined', answer: error.message, steps: [] };
    if (error instanceof NotMath) return null;
    throw error;
  }
}

/** A reader sees a small raised 2 as a star or a question mark, and reads "= ?" on a sum as "= 7". */
function repairOcr(line) {
  return String(line || '').replace(/([a-zA-Z])[*?](?=\s*[-+=])/g, '$1^2');
}

/**
 * "1.12x4 =" under "2.3x+2=14": a reader often glues the question number to
 * the question. When the numbers count up line after line, they are numbering.
 */
function stripNumbering(lines) {
  const marker = /^\(?(\d{1,2})[.)]\s*(?=\S)/;
  const numbers = lines.map((line) => { const m = marker.exec(line); return m ? Number(m[1]) : null; });
  const found = numbers.filter((n) => n !== null);
  if (found.length < 2 || !found.every((n, i) => i === 0 || n === found[i - 1] + 1)) return lines;
  return lines.map((line, i) => (numbers[i] === null ? line : line.replace(marker, '')));
}

/** A line can hold two equations: "x + y = 10, x - y = 2" or "… and …". */
function splitLines(text) {
  const out = [];
  for (const line of String(text || '').split(/\r?\n|;/)) {
    const equalsSigns = (line.match(/=/g) || []).length;
    if (equalsSigns >= 2) out.push(...line.split(/,|\band\b/i)); else out.push(line);
  }
  return out.map((l) => l.trim()).filter(Boolean);
}

/**
 * Everything in a block of text that Bill can do in his head.
 * `strict` is for text swept off a whole window, where most lines that look
 * like subtraction are really page counts and file names.
 */
function solveText(text, options = {}) {
  const lines = stripNumbering(splitLines(text));
  const problems = []; const leftovers = [];
  let pending = [];
  const flush = () => {
    if (!pending.length) return;
    const system = solveSystem(pending);
    if (system) problems.push(system); else leftovers.push(...pending.map((p) => p.source));
    pending = [];
  };
  for (const line of lines) {
    const result = solveLine(line, options);
    if (result && result.multi) { pending.push(result); continue; }
    flush();
    if (result) problems.push(result); else leftovers.push(tidy(line));
  }
  flush();
  // A sum that OCR broke across lines still reads as one when put back together.
  if (!problems.length && lines.length > 1 && lines.length <= 4) {
    const joined = solveLine(lines.join(' '), options);
    if (joined && !joined.multi) return { problems: [joined], leftovers: [], allMath: true };
  }
  const wordy = leftovers.filter((l) => /[a-zA-Z]{3,}/.test(l));
  return { problems, leftovers, allMath: problems.length > 0 && wordy.length === 0 };
}

/** The lines Bill puts in his chat bubble for one solved problem. */
function describe(problem) {
  const lines = [problem.source, `→ ${problem.answer}`];
  for (const step of problem.steps) lines.push(`   · ${step}`);
  return lines.join('\n');
}

module.exports = { solveText, solveLine, describe, plain, fmt, fmtAnswer, asFraction, polyToString, tidy };
