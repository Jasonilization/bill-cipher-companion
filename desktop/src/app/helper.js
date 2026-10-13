// Bill reads the screen and does something about it.
//
// "Solve Something On Screen": the user drags a box around a problem; Bill
// reads it on this computer (OCR) and answers. Sums and equations he works
// out himself (core/solver.js), with the working and with no network; anything
// wordier goes to his chat brain. "Help With This Window" does the same for
// the whole window the user was last working in.
const fs = require('fs');
const platform = require('../platform');
const { solveText, describe, plain } = require('../core/solver');
const { pick } = require('../core/modeLines');

const MAX_PROMPT_TEXT = 6000;
const MAX_EXCERPT = 600;
const MAX_LOCAL_PROBLEMS = 12;
const ASKS_SOMETHING = /\?|\b(?:solve|find|calculate|compute|how (?:many|much|far|long|do|does|can)|what|why|which|explain|prove|determine|evaluate|simplify|error|exception|failed|cannot|unable)\b/i;

const clip = (text, max) => (text.length > max ? `${text.slice(0, max)}…` : text);
const squash = (text) => String(text || '').split(/\r?\n/).map((l) => l.trim()).filter(Boolean).join('\n');

class ScreenHelper {
  constructor({ engine, conversation, snip, prefs, bill, barkWindow, monitor }) {
    Object.assign(this, { engine, conversation, snip, prefs, bill, barkWindow, monitor });
    this.busy = false;
  }

  get mode() { return this.prefs.get('mode'); }
  say(key) { const line = pick(key); if (line) this.engine.bark(line, 'always'); }

  canRead() {
    if (platform.canReadScreen) return true;
    this.engine.request('confused', true);
    this.say('noReader');
    return false;
  }

  /** Bill and his speech bubble should not be in the picture he is trying to read. */
  async photograph(rect) {
    const windows = [this.bill.window, this.barkWindow && this.barkWindow.window].filter((w) => w && !w.isDestroyed());
    const hide = process.platform === 'win32';
    if (hide) for (const w of windows) { try { w.setContentProtection(true); } catch { /* older Windows: he is in the shot */ } }
    try {
      if (hide) await new Promise((resolve) => setTimeout(resolve, 60));
      return await platform.captureRegion(rect);
    } finally {
      if (hide) for (const w of windows) { try { if (!w.isDestroyed()) w.setContentProtection(false); } catch { /* gone */ } }
    }
  }

  // ------------------------------------------------------------ entry points
  /** Menu / hot key: drag a box around a problem and he solves it. */
  async solveRegion() {
    if (this.busy || this.snip.isOpen) { this.say('busy'); return; }
    if (this.conversation.isAwaitingChatResponse) { this.say('busy'); return; }
    if (!this.canRead()) return;
    this.busy = true;
    try {
      this.say('snipStart');
      const rect = await this.snip.pick();
      if (!rect) { this.say('snipCancelled'); return; }
      this.engine.request('scanning', true);
      const image = await this.photograph(rect);
      const text = squash(image ? await platform.readImage(image, { block: true }) : '');
      if (text.replace(/\s/g, '').length < 2) { this.engine.request('confused', true); this.say('nothingToRead'); return; }
      await this.present(text, { strict: false });
    } finally {
      this.busy = false;
    }
  }

  /** Menu / an accepted offer / a typed "what's on my screen": read a whole window. */
  async helpWithWindow(target, { question = null } = {}) {
    if (this.busy) { this.say('busy'); return; }
    if (this.conversation.isAwaitingChatResponse) { this.say('busy'); return; }
    if (!this.canRead()) return;
    const app = target || this.monitor.current;
    if (!app || app.windowId === undefined || app.windowId === null) { this.engine.request('confused', true); this.say('noWindow'); return; }
    this.busy = true;
    try {
      this.engine.request('scanning', true);
      if (!question) this.say('reading');
      const shot = await platform.captureWindow(app.windowId, 2000);
      let text = '';
      if (shot) {
        text = squash(await platform.readImage(shot.image, { block: false }));
        fs.promises.unlink(shot.file).catch(() => {});
      }
      if (text.replace(/\s/g, '').length < 2) { this.engine.request('confused', true); this.say('nothingToRead'); return; }
      const title = platform.windowTitle(app.windowId) || app.title || '';
      await this.present(text, { strict: true, app, title, question });
    } finally {
      this.busy = false;
    }
  }

  // ---------------------------------------------------------------- answering
  async present(text, { strict, app = null, title = '', question = null }) {
    const result = solveText(text, { strict, ocr: true });
    const problems = result.problems.slice(0, MAX_LOCAL_PROBLEMS);
    const wordy = result.leftovers.filter((l) => /[a-zA-Z]{3,}/.test(l)).join('\n');
    // A whole window always has more to say than its sums; a snipped box only
    // needs the chat brain when it holds a question he could not do himself.
    const needsBrain = !!question || !!app || (wordy.length > 12 && (!problems.length || ASKS_SOMETHING.test(wordy)));

    if (problems.length && !question) {
      const flavour = pick(this.mode === 'helpful' ? 'solvedHelpful' : 'solvedTroll');
      const answer = `${problems.map(describe).join('\n\n')}\n\n${flavour}`;
      this.conversation.showScreenAnswer({
        excerpt: clip(problems.map((p) => p.source).join('\n'), MAX_EXCERPT), answer, context: text,
      });
      const first = problems[0];
      this.engine.bark(plain(clip(`${first.source}  ${first.answer}`, 110)).toUpperCase(), 'always');
      // He has shown his own answers; the rest is not worth a second trip unless asked.
      return;
    }

    if (!needsBrain) {
      this.conversation.showScreenAnswer({
        excerpt: clip(text, MAX_EXCERPT),
        answer: 'I READ IT, BUT THERE IS NO PROBLEM IN THERE FOR ME TO SOLVE. ASK ME SOMETHING ABOUT IT.',
        context: text,
      });
      return;
    }

    const where = app ? `the "${clip(title || app.name || 'unknown', 120)}" window of ${app.name || 'an app'} on my screen` : 'a part of my screen I selected';
    const ask = question
      ? `My question: ${question}`
      : app
        ? 'If there is an error or a problem in it, say what is wrong and how to fix it; otherwise say what I am looking at and the most useful next step.'
        : 'Solve or answer what it asks.';
    const prompt = `[This overrides the one-or-two-sentence rule for this reply: give the answer first, then at most five short numbered steps, still in character. `
      + `The text below was read off ${where} by OCR, so silently fix obvious recognition errors.] ${ask}\n\n"""\n${clip(text, MAX_PROMPT_TEXT)}\n"""`;
    await this.conversation.askAboutScreen({ excerpt: question ? null : clip(text, MAX_EXCERPT), prompt });
    this.conversation.screenContext = null;
  }
}

module.exports = { ScreenHelper };
