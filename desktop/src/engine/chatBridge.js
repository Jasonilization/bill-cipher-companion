// Port of Chat/ChatBridge.swift + UI/ChatWindow/ChatPanelController.swift.
//
// Bill talks through the real chatgpt.com page in his own browser window,
// with his own cookies: there is no API key and nothing to configure. The
// window stays hidden unless "Open Full Chat View…" asks for it (which is
// also where the user signs in, once).
const path = require('path');
const { EventEmitter } = require('events');
const { BrowserWindow, ipcMain, screen, session, shell } = require('electron');

const CHAT_URL = 'https://chatgpt.com';
const PARTITION = 'persist:billchat';
const PANEL_SIZE = { width: 420, height: 560 };

const PERSONA_PREAMBLE = 'From now on you\'re Bill Cipher: a dimension-hopping dream demon who '
  + 'finds humans amusing. Mischievous, sarcastic, playful, energetic, '
  + 'occasionally dramatic — but still genuinely helpful; the attitude is '
  + 'flavor, not an excuse to dodge the question. Keep it short, a sentence '
  + 'or two like a companion popup, not an essay. For example, if asked '
  + '"why is my code broken", don\'t answer like a generic assistant '
  + '("There could be several reasons for this issue...") — answer like '
  + 'Bill: "Oh, it\'s broken because you\'re a human and humans make '
  + 'mistakes. Also you\'re missing a semicolon on line 12." Same energy '
  + 'every message, not just this one. Here\'s my message:';

const PERSONA_REMINDER = '[Remember: stay in character as Bill Cipher — mischievous, sarcastic, playful, still genuinely helpful, one or two sentences.] ';

const TASK_PREAMBLE = 'You\'re Bill Cipher: a dimension-hopping dream demon who finds humans '
  + 'amusing — mischievous, sarcastic, playful, occasionally dramatic. This is a '
  + 'bulk writing task, not a conversation, so ignore any earlier instruction '
  + 'about keeping replies to one or two sentences. Follow the output format '
  + 'below exactly and output nothing else — no preamble, no commentary, no '
  + 'numbering, no markdown.';

// Sign-in pop-ups stay inside Bill's browser; anything else opens in the user's own.
const SIGN_IN_HOSTS = /(^|\.)(chatgpt\.com|openai\.com|auth0\.com|google\.com|googleusercontent\.com|gstatic\.com|microsoft\.com|microsoftonline\.com|live\.com|apple\.com|icloud\.com)$/i;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

class ChatBridge extends EventEmitter {
  constructor() {
    super();
    this.window = null;
    this.isLoading = false;
    this.isGenerating = false;
    this.wasGenerating = false;
    this.hasInjectedPersona = false;
    this.isShown = false;
    this.pending = new Map();
    this.nextCallId = 1;
    /** What the page's last reply looked like when the current message went out. */
    this.baseline = { count: 0, text: null };
    /** Receives each finished reply (never a stale one). */
    this.onResponseReceived = null;
    /** A line about the mood he is in (troll or helpful), added to every conversational message. */
    this.modeNote = null;

    ipcMain.on('billchat:state', (event, value) => {
      if (!this.window || event.sender !== this.window.webContents) return;
      this.handleBridgeMessage(value);
    });
    ipcMain.on('billchat:result', (event, id, result) => {
      if (!this.window || event.sender !== this.window.webContents) return;
      const resolve = this.pending.get(id);
      if (!resolve) return;
      this.pending.delete(id);
      resolve(result);
    });
  }

  get hasEngine() { return !!this.window && !this.window.isDestroyed(); }

  prepareIfNeeded() {
    if (this.hasEngine) return;
    const chatSession = session.fromPartition(PARTITION);
    // A plain browser identity: the default one advertises the embedding
    // shell, which sign-in providers tend to turn away.
    const chrome = process.versions.chrome.split('.')[0];
    const os = process.platform === 'win32' ? 'Windows NT 10.0; Win64; x64' : 'X11; Linux x86_64';
    chatSession.setUserAgent(`Mozilla/5.0 (${os}) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/${chrome}.0.0.0 Safari/537.36`);

    const win = new BrowserWindow({
      ...PANEL_SIZE,
      show: false,
      title: 'Bill — Chat',
      autoHideMenuBar: true,
      skipTaskbar: true,
      minimizable: false,
      maximizable: false,
      webPreferences: {
        partition: PARTITION,
        preload: path.join(__dirname, '..', '..', 'renderer', 'chat-preload.js'),
        contextIsolation: true,
        nodeIntegration: false,
        sandbox: true,
        // The page has to keep streaming while nobody is looking at it.
        backgroundThrottling: false,
      },
    });
    win.setMenuBarVisibility(false);
    this.window = win;
    this.isLoading = true;

    const settled = () => { this.isLoading = false; this.settledAt = Date.now(); this.emit('loaded'); };
    win.webContents.on('did-finish-load', settled);
    win.webContents.on('did-fail-load', (_e, code, description, _url, isMainFrame) => {
      if (!isMainFrame) return;
      console.error(`ChatBridge: failed to load chatgpt.com: ${description} (${code})`);
      settled();
    });
    win.webContents.setWindowOpenHandler(({ url }) => {
      let host = '';
      try { host = new URL(url).hostname; } catch { return { action: 'deny' }; }
      if (SIGN_IN_HOSTS.test(host)) {
        return { action: 'allow', overrideBrowserWindowOptions: { autoHideMenuBar: true, webPreferences: { partition: PARTITION } } };
      }
      if (/^https?:$/.test(new URL(url).protocol)) shell.openExternal(url);
      return { action: 'deny' };
    });
    // Closing the window puts it away; the conversation stays alive behind it.
    win.on('close', (event) => {
      if (this.isQuitting) return;
      event.preventDefault();
      this.hide();
    });
    win.loadURL(CHAT_URL);
  }

  // --------------------------------------------------------- full chat view
  positionTopRight() {
    if (!this.hasEngine) return;
    const area = screen.getPrimaryDisplay().workArea;
    this.window.setBounds({
      x: Math.round(area.x + area.width - PANEL_SIZE.width - 20),
      y: Math.round(area.y + 8),
      ...PANEL_SIZE,
    });
  }

  /** "Open Full Chat View…" — also where the user signs in to ChatGPT, once. */
  show() {
    this.prepareIfNeeded();
    if (!this.isShown) this.positionTopRight();
    this.isShown = true;
    this.window.setSkipTaskbar(false);
    this.window.show();
    this.window.focus();
  }

  hide() {
    this.isShown = false;
    if (!this.hasEngine) return;
    this.window.hide();
    this.window.setSkipTaskbar(true);
  }

  toggle() { if (this.isShown) this.hide(); else this.show(); }

  // ------------------------------------------------------------- page calls
  call(op, arg, timeoutMs = 8000) {
    if (!this.hasEngine) return Promise.resolve(null);
    const id = this.nextCallId++;
    return new Promise((resolve) => {
      const timer = setTimeout(() => { this.pending.delete(id); resolve(null); }, timeoutMs);
      this.pending.set(id, (value) => { clearTimeout(timer); resolve(value); });
      try { this.window.webContents.send('billchat:call', id, op, arg); } catch { clearTimeout(timer); this.pending.delete(id); resolve(null); }
    });
  }

  async waitUntilReadyToSend() {
    const deadline = Date.now() + 20000;
    while (this.isLoading && Date.now() < deadline) await sleep(150);
    // The composer mounts a beat after the document itself reports loaded.
    const composerDeadline = (this.settledAt || Date.now()) + 6000;
    while (this.hasEngine && Date.now() < composerDeadline) {
      if (await this.call('signedIn', null, 1500)) return;
      await sleep(300);
    }
  }

  /**
   * The composer only exists once the page is usable, which on chatgpt.com
   * means either signed in or allowed to chat as a guest.
   */
  async checkSignedIn() {
    this.prepareIfNeeded();
    await this.waitUntilReadyToSend();
    if (!this.hasEngine) return false;
    return (await this.call('signedIn')) === true;
  }

  async diagnose() {
    this.prepareIfNeeded();
    await this.waitUntilReadyToSend();
    if (!this.hasEngine) return 'no chat engine constructed';
    const result = await this.call('diagnose');
    return typeof result === 'string' ? result : `page call failed: ${JSON.stringify(result)}`;
  }

  /** A conversational message: the persona preamble once, a short reminder after. */
  send(text) {
    let outgoing;
    const mood = this.modeNote ? String(this.modeNote() || '') : '';
    const body = mood ? `[${mood}] ${text}` : text;
    if (this.hasInjectedPersona) outgoing = `${PERSONA_REMINDER}${body}`;
    else { this.hasInjectedPersona = true; outgoing = `${PERSONA_PREAMBLE} ${body}`; }
    return this.deliver(outgoing);
  }

  /** A bulk writing job, exempt from the "one or two sentences" rule. */
  sendTask(text) { return this.deliver(`${TASK_PREAMBLE}\n\n${text}`); }

  async deliver(outgoing) {
    this.prepareIfNeeded();
    await this.waitUntilReadyToSend();
    if (!this.hasEngine) return false;
    const before = await this.call('lastResponse');
    this.baseline = before && typeof before === 'object' ? before : { count: 0, text: null };
    this.awaitingReply = true;
    const sent = await this.call('send', outgoing);
    if (sent !== true) console.error('ChatBridge: send failed');
    return sent === true;
  }

  handleBridgeMessage(value) {
    const generating = value === 'generating';
    if (generating !== this.isGenerating) {
      this.isGenerating = generating;
      this.emit('generating', generating);
    }
    if (this.wasGenerating && !generating) this.extractLatestResponse();
    this.wasGenerating = generating;
  }

  async extractLatestResponse() {
    if (!this.hasEngine || !this.awaitingReply) return;
    const result = await this.call('lastResponse');
    if (!result || typeof result !== 'object' || !result.text) return;
    // Typing into the composer is itself DOM activity, so the page goes
    // "quiet" once before the reply even starts. Only a reply that is
    // actually new counts.
    if (result.count <= this.baseline.count && result.text === this.baseline.text) return;
    this.awaitingReply = false;
    this.baseline = result;
    if (this.onResponseReceived) this.onResponseReceived(result.text);
  }

  /** Forgets the session entirely: the window, its cookies and its storage. */
  async signOut() {
    if (this.hasEngine) {
      this.isQuitting = true;
      this.window.destroy();
      this.isQuitting = false;
    }
    this.window = null;
    this.isLoading = false;
    this.isShown = false;
    this.hasInjectedPersona = false;
    this.wasGenerating = false;
    this.awaitingReply = false;
    if (this.isGenerating) { this.isGenerating = false; this.emit('generating', false); }
    try {
      const chatSession = session.fromPartition(PARTITION);
      await chatSession.clearStorageData();
      await chatSession.clearCache();
    } catch (e) {
      console.error('ChatBridge: sign-out cleanup failed:', e.message);
    }
  }

  dispose() {
    this.isQuitting = true;
    if (this.hasEngine) this.window.destroy();
    this.window = null;
  }
}

module.exports = { ChatBridge, CHAT_URL };
