// Injected into the real chatgpt.com page (port of Chat/ChatGPTBridgeScripts.swift).
//
// Runs in Electron's isolated world, the counterpart of the Mac app's private
// WKContentWorld: it shares the page's DOM but none of its JavaScript, so the
// site cannot see or tamper with the bridge. Everything here is best-effort
// and fails soft — chatgpt.com's markup can change at any time.
const { ipcRenderer } = require('electron');

const HIDE_CHROME_CSS = `
nav[aria-label="Chat history"], #sidebar, [data-testid="sidebar"],
#page-header, header[data-testid="page-header"] {
    display: none !important;
}
body, html { background: transparent !important; }
`;

const composer = () => document.querySelector('#prompt-textarea') || document.querySelector('[contenteditable="true"]');
const sendButton = () => document.querySelector('[data-testid="send-button"]') || document.querySelector('button[aria-label="Send prompt"]');
const stopButton = () => document.querySelector('[data-testid="stop-button"]') || document.querySelector('button[aria-label="Stop streaming"]') || document.querySelector('button[aria-label="Stop generating"]');
const assistantTurns = () => document.querySelectorAll('[data-message-author-role="assistant"]');

// ------------------------------------------------- "is it generating" signal
// Rather than depend on one button's markup, treat any sustained burst of DOM
// mutations in the main content area as "streaming", debounced back to idle
// after a quiet period.
let debounceTimer = null;
let isGenerating = false;

function post(value) {
  if (value === isGenerating) return;
  isGenerating = value;
  try { ipcRenderer.send('billchat:state', value ? 'generating' : 'idle'); } catch { /* window closing */ }
}

function settle() {
  // A reply that pauses mid-stream is not finished while the stop button is up.
  if (stopButton()) { debounceTimer = setTimeout(settle, 900); return; }
  post(false);
}

function onMutation() {
  post(true);
  if (debounceTimer) clearTimeout(debounceTimer);
  debounceTimer = setTimeout(settle, 900);
}

function attach() {
  try {
    const style = document.createElement('style');
    style.textContent = HIDE_CHROME_CSS;
    document.documentElement.appendChild(style);
  } catch { /* no document element yet */ }
  const target = document.querySelector('main') || document.body;
  if (!target) return;
  new MutationObserver(onMutation).observe(target, { childList: true, subtree: true, characterData: true });
}

if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', attach);
else attach();

// ------------------------------------------------------------------ actions
function setComposerText(el, text) {
  el.focus();
  if (el.tagName === 'TEXTAREA' || el.tagName === 'INPUT') {
    const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), 'value');
    if (setter && setter.set) setter.set.call(el, text); else el.value = text;
    el.dispatchEvent(new InputEvent('input', { bubbles: true }));
    return;
  }
  // A paste is the one input a rich-text composer always handles itself, and
  // it keeps line breaks as line breaks instead of as "Enter" (which sends).
  let handled = false;
  try {
    const data = new DataTransfer();
    data.setData('text/plain', text);
    const event = new ClipboardEvent('paste', { clipboardData: data, bubbles: true, cancelable: true });
    el.dispatchEvent(event);
    handled = event.defaultPrevented && (el.innerText || '').trim().length > 0;
  } catch { handled = false; }
  if (handled) return;
  el.innerText = text;
  el.dispatchEvent(new InputEvent('input', { bubbles: true }));
}

function sendMessage(text) {
  try {
    const el = composer();
    if (!el) return false;
    setComposerText(el, text);
    // The send button enables a moment after the composer sees the text.
    let attempts = 0;
    const trySend = () => {
      attempts += 1;
      const button = sendButton();
      if (button && !button.disabled) { button.click(); return; }
      if (attempts < 12) { setTimeout(trySend, 120); return; }
      el.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true }));
    };
    setTimeout(trySend, 80);
    return true;
  } catch {
    return false;
  }
}

function lastResponse() {
  try {
    const turns = assistantTurns();
    if (!turns.length) return { count: 0, text: null };
    const last = turns[turns.length - 1];
    return { count: turns.length, text: last.innerText || last.textContent || null };
  } catch {
    return { count: 0, text: null };
  }
}

function diagnose() {
  const r = {};
  r.url = location.href;
  r.title = document.title;
  r.hasComposer = !!composer();
  r.hasSend = !!sendButton();
  r.assistantTurns = assistantTurns().length;
  r.bridgeInstalled = true;
  const t = (document.body ? document.body.innerText : '') || '';
  r.looksLoggedOut = /log in|sign up|welcome back|create an account/i.test(t.slice(0, 4000));
  r.bodyChars = t.length;
  return JSON.stringify(r);
}

ipcRenderer.on('billchat:call', (_event, id, op, arg) => {
  let result = null;
  try {
    if (op === 'send') result = sendMessage(String(arg || ''));
    else if (op === 'lastResponse') result = lastResponse();
    else if (op === 'signedIn') result = !!composer();
    else if (op === 'diagnose') result = diagnose();
  } catch (e) {
    result = { error: String(e && e.message) };
  }
  ipcRenderer.send('billchat:result', id, result);
});
