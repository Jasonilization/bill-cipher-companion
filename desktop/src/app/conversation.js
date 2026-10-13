// Port of the chat half of UI/CharacterWindow/CharacterWindowController.swift:
// talking to Bill, the ChatGPT-written dialogue refresh, and the personalization
// run. All three share one hidden chat page, so they are arbitrated here.
const { memory, refreshLog, clamp } = require('../core/stores');
const { library, emptyPool, mergePool, poolLineCount, BUCKETS } = require('../core/dialogue');
const BarkLines = require('../core/barklines');

const CHAT_TIMEOUT = 20 * 1000;
const CHAT_GENERATING_TIMEOUT = 120 * 1000;
const REFRESH_CHECK_INTERVAL = 30 * 60 * 1000;
const REFRESH_INTERVAL = 24 * 60 * 60;
const REFRESH_TIMEOUT = 150 * 1000;
const MAX_APP_DESCRIPTIONS_PER_REFRESH = 5;
const MAX_SPOKEN_REPLY = 280;

/** A typed question that is really about what is on the screen. */
const SCREEN_QUESTION = /(?:on|at) (?:my|the|this) screen|what am i looking at|(?:look at|read|solve|fix|explain) (?:this|that|my screen|the screen|it)|what(?:'s| is) (?:this|that) error/i;
const MAX_SCREEN_CONTEXT = 4000;

const SIGNED_OUT_BARK = 'I\'M NOT SIGNED IN OVER HERE. OPENING THE LOGIN — SORT IT OUT.';
const SIGNED_OUT_NOTE = 'I have my own browser, and it isn\'t signed in to ChatGPT. Log in in the window I just opened — once is enough.';

/** The pools a refresh may write into. */
const REFRESHABLE_POOLS = [
  'coding', 'gaming', 'browsing', 'music', 'creative', 'productivity', 'communication', 'aiChat', 'tinkering',
  'finder', 'cpuHot', 'networkLost', 'networkRestored', 'network.slow', 'network.fast', 'batteryLow',
  'batteryCharging', 'battery.step', 'charge.step', 'volume.0', 'volume.25', 'volume.50', 'volume.75',
  'volume.100', 'volume.mute', 'volume.unmute', 'weather.clear', 'weather.cloudy', 'weather.fog',
  'weather.rain', 'weather.snow', 'weather.thunder', 'weather.other', 'clock.morning', 'clock.midday',
  'clock.afternoon', 'clock.night', 'userReturned', 'waking', 'gettingSleepy', 'poked', 'poked.annoyed',
  'poked.furious', 'grabbed', 'dropped', 'roamHardLanding', 'roamFellOffWorld', 'chatFailed',
  'stillThinking', 'transition.generic',
];
const POOL_BY_LOWERCASE = new Map(REFRESHABLE_POOLS.map((p) => [p.toLowerCase(), p]));
const VALID_TIMES = new Set(['any', ...BUCKETS]);

const freshMarker = () => `BILL-${100000 + Math.floor(Math.random() * 900000)}`;

function refreshPrompt({ marker, summary, appNames, extra }) {
  let prompt = `${marker}\n`
    + `Recent activity on this computer: ${summary}.\n\n`
    + 'Write 16 short Bill-Cipher quips about it, ONE PER LINE, each in exactly this pipe-separated format and nothing else:\n'
    + 'POOL|TIME|LINE\n\n'
    + `POOL must be exactly one of: ${REFRESHABLE_POOLS.join(', ')}\n`
    + 'TIME must be exactly one of: any, morning, midday, afternoon, night\n'
    + 'LINE must be under 100 characters, no quotes, no numbering.\n\n'
    + 'Spread them across at least 8 different POOLs and at least 3 different TIMEs. TIME is when the line makes sense — '
    + `a "night" line should only work at night. Begin your reply with ${marker} on its own line.`;
  if (appNames.length) {
    prompt += '\n\nThen, one per line, prefixed with "APP:", one short sarcastic-but-informative sentence describing '
      + `what each of these apps is for, formatted exactly as "APP: <name>: <description>", for: ${appNames.join(', ')}.`;
  }
  if (extra) prompt += `\n\nAdditional persona notes from the user — honor them: ${extra}`;
  return prompt;
}

/** `pending` maps an app's display name to its id. */
function parseRefresh(response, pending) {
  const pools = {}; const descriptions = {}; const seen = new Set();
  for (const raw of String(response).split(/\r?\n/)) {
    const line = raw.trim();
    if (line.startsWith('APP:')) {
      const after = line.slice(4).trim();
      const sep = after.indexOf(':');
      if (sep < 0) continue;
      const name = after.slice(0, sep).trim();
      const text = after.slice(sep + 1).trim();
      if (!(name in pending) || !text || text.length > 160) continue;
      descriptions[name] = text;
      continue;
    }
    const parts = line.split('|');
    if (parts.length < 3) continue;
    // Matched case-insensitively and mapped back: the model is told the exact
    // names, but "aichat" for "aiChat" should not cost the line.
    const pool = POOL_BY_LOWERCASE.get(parts[0].trim().toLowerCase());
    const time = parts[1].trim().toLowerCase();
    const text = parts.slice(2).join('|').trim();
    if (!pool || !VALID_TIMES.has(time) || !text || text.length > 120) continue;
    const key = `${pool}|${time}|${text.toLowerCase()}`;
    if (seen.has(key)) continue;
    seen.add(key);
    if (!pools[pool]) pools[pool] = emptyPool();
    pools[pool][time].push(text);
  }
  return { pools, descriptions };
}

class Conversation {
  constructor({ engine, chatBridge, chatBubble, bill, roaming, prefs, weather, personalization }) {
    Object.assign(this, { engine, chatBridge, chatBubble, bill, roaming, prefs, weather, personalization });
    this.isAwaitingChatResponse = false;
    this.isPerformingBackgroundChatWork = false;
    this.hasIncludedActivityContext = false;
    this.wasWanderingBeforeChat = false;
    this.chatWatchdog = null;
    this.chatSentAt = 0;
    this.didBarkStillThinking = false;
    this.replyTimers = [];
    this.refreshTimer = null;
    this.refreshWatchdog = null;
    this.activeRefreshId = null;
    this.refreshMarker = null;
    this.pendingDescriptions = {};
    /** What Bill last read off the screen, so a follow-up question can be about it. */
    this.screenContext = null;
    /** Set by the screen helper: answers a typed question by reading the screen first. */
    this.onScreenQuestion = null;
  }

  start() {
    this.chatBubble.onSubmit = (text) => this.submit(text);
    this.chatBubble.onDismiss = () => this.bubbleDismissed();
    this.chatBridge.onResponseReceived = (text) => this.route(text);
    // Only a conversation animates him: a background job should not make him mouth along.
    this.chatBridge.on('generating', (generating) => {
      if (this.isPerformingBackgroundChatWork) return;
      this.engine.request(generating ? 'talking' : 'idle');
    });
    this.refreshTimer = setInterval(() => this.maybeRefreshDialogue(), REFRESH_CHECK_INTERVAL);
  }

  stop() {
    clearInterval(this.refreshTimer);
    clearInterval(this.chatWatchdog);
    clearTimeout(this.refreshWatchdog);
    this.replyTimers.forEach(clearTimeout);
  }

  /** Whichever job is waiting on the chat page gets the reply. */
  route(text) {
    if (this.personalization.isActive) this.personalization.handleResponse(text);
    else if (this.isPerformingBackgroundChatWork) this.finishDialogueRefresh(text);
    else this.handleChatResponse(text);
  }

  // ------------------------------------------------------------ talk to Bill
  talkToBill() {
    if (this.chatBubble.isVisible) { this.chatBubble.hide(); return; }
    if (this.isAwaitingChatResponse) {
      this.engine.bark(BarkLines.random(BarkLines.POOLS.stillThinking), 'always');
      return;
    }
    this.wasWanderingBeforeChat = true;
    this.roaming.suspend();
    this.hasIncludedActivityContext = false;
    this.chatBridge.prepareIfNeeded();
    this.chatBubble.showCompose(this.bill.frame, this.bill.screen());
  }

  showFullChat() { this.chatBridge.show(); }

  submit(text) {
    if (this.isAwaitingChatResponse) return undefined;
    if (!this.screenContext && this.onScreenQuestion && SCREEN_QUESTION.test(text)) return this.onScreenQuestion(text);
    let outgoing = this.contextualized(text);
    if (this.screenContext) {
      outgoing = `[Earlier I read this off my screen, in case the question is about it: "${this.screenContext.slice(0, MAX_SCREEN_CONTEXT)}"] ${outgoing}`;
      this.screenContext = null;
    }
    return this.ask(outgoing);
  }

  /** Puts the bubble up beside him if it is not already, without the click-away-to-close of a fresh compose. */
  openForScreen() {
    if (!this.chatBubble.isVisible) {
      this.wasWanderingBeforeChat = true;
      this.roaming.suspend();
      this.chatBridge.prepareIfNeeded();
      this.chatBubble.showCompose(this.bill.frame, this.bill.screen());
    }
    this.chatBubble.pinned = true;
  }

  /** Something he read off the screen and worked out himself: no chat brain involved. */
  showScreenAnswer({ excerpt, answer, context }) {
    this.openForScreen();
    if (excerpt) this.chatBubble.showUser(excerpt);
    this.chatBubble.showResponse(answer);
    this.screenContext = context || null;
    this.engine.request('presenting', true);
  }

  /** Something he read off the screen that needs the chat brain. */
  askAboutScreen({ excerpt, prompt }) {
    if (this.isAwaitingChatResponse) return undefined;
    this.openForScreen();
    if (excerpt) this.chatBubble.showUser(excerpt);
    this.hasIncludedActivityContext = true;
    return this.ask(prompt);
  }

  async ask(outgoing) {
    if (this.isAwaitingChatResponse) return;
    this.isAwaitingChatResponse = true;
    this.engine.request('thinking', true);
    this.chatBubble.showWaiting();
    const signedIn = await this.chatBridge.checkSignedIn();
    if (!this.isAwaitingChatResponse) return;
    if (!signedIn) { this.reportSignedOut(); return; }
    this.chatSentAt = Date.now();
    this.didBarkStillThinking = false;
    this.startChatWatchdog();
    const sent = await this.chatBridge.send(outgoing);
    if (!sent && this.isAwaitingChatResponse) this.handleChatResponse('');
  }

  /** The first message of a chat carries what Bill has seen, so the reply can be about it. */
  contextualized(text) {
    if (this.hasIncludedActivityContext) return text;
    this.hasIncludedActivityContext = true;
    const parts = [];
    const summary = memory.recentActivitySummary;
    if (summary) parts.push(`I've recently been using this computer for ${summary}`);
    const weather = this.weather.blurb;
    if (weather) parts.push(`outside the window, ${weather}`);
    const extra = String(this.prefs.get('promptExtraInstructions') || '').trim();
    if (extra) parts.push(`extra persona notes from my user: ${extra}`);
    if (!parts.length) return text;
    return `[For your context, not to repeat verbatim: ${parts.join('; ')}.] ${text}`;
  }

  startChatWatchdog() {
    clearInterval(this.chatWatchdog);
    this.chatWatchdog = setInterval(() => {
      if (!this.isAwaitingChatResponse) { clearInterval(this.chatWatchdog); return; }
      const elapsed = Date.now() - this.chatSentAt;
      // A reply that is visibly streaming gets far longer than one that never started.
      const limit = this.chatBridge.isGenerating ? CHAT_GENERATING_TIMEOUT : CHAT_TIMEOUT;
      if (elapsed >= limit) { this.handleChatResponse(''); return; }
      if (!this.didBarkStillThinking && Math.abs(elapsed - 10000) < 2500) {
        this.didBarkStillThinking = true;
        this.engine.bark(BarkLines.random(BarkLines.POOLS.stillThinking), 'always');
      }
    }, 5000);
  }

  reportSignedOut() {
    this.isAwaitingChatResponse = false;
    clearInterval(this.chatWatchdog);
    this.engine.request('confused', true);
    this.engine.bark(library.line('chat.signedOut') || SIGNED_OUT_BARK, 'always');
    this.chatBubble.showResponse(SIGNED_OUT_NOTE);
    this.showFullChat();
  }

  handleChatResponse(response) {
    if (!this.isAwaitingChatResponse) return;
    this.isAwaitingChatResponse = false;
    clearInterval(this.chatWatchdog);
    const text = String(response || '').trim();
    if (!text) {
      this.engine.request('idle');
      this.engine.bark(BarkLines.random(BarkLines.POOLS.chatFailed), 'always');
      this.chatBubble.hide();
      return;
    }
    if (!this.chatBubble.isVisible) {
      // The bubble was closed while he was thinking: say it out loud instead.
      this.engine.request('idle');
      this.engine.bark(text.length > MAX_SPOKEN_REPLY ? `${text.slice(0, MAX_SPOKEN_REPLY)}…` : text, 'always');
      return;
    }
    this.chatBubble.showResponse(text);
    this.engine.request('happy', true);
    this.replyTimers.forEach(clearTimeout);
    this.replyTimers = [
      setTimeout(() => this.engine.request('talking'), 1000),
      setTimeout(() => { if (this.engine.stateMachine.currentState === 'talking') this.engine.request('idle'); }, 4500),
    ];
  }

  bubbleDismissed() {
    this.engine.request('idle');
    if (!this.wasWanderingBeforeChat) return;
    this.wasWanderingBeforeChat = false;
    this.roaming.resume();
  }

  /** Bill moved: the bubble goes with him. */
  reanchor() { this.chatBubble.reanchor(this.bill.frame, this.bill.screen()); }
  relayout() { this.chatBubble.relayout(this.bill.frame, this.bill.screen()); }

  // -------------------------------------------------------- dialogue refresh
  maybeRefreshDialogue() {
    // Read live, so the Settings stepper applies on the next check.
    const perDay = clamp(this.prefs.get('promptRefreshesPerDay'), 1, 6);
    if (!memory.shouldRefreshDialogue(REFRESH_INTERVAL / perDay)) return;
    this.performDialogueRefresh(`periodic timer (${perDay}x per day)`);
  }

  refreshDialogueNow() { this.performDialogueRefresh('menu: Refresh Bill\'s Context Now'); }

  async performDialogueRefresh(trigger) {
    if (this.isPerformingBackgroundChatWork) {
      refreshLog.recordImmediateFailure(trigger, 'A refresh is already in flight. (If this persists, the previous one is stuck — it will time out on its own.)');
      return;
    }
    if (this.isAwaitingChatResponse || this.chatBubble.isVisible) {
      refreshLog.recordImmediateFailure(trigger, 'Skipped: you were mid-conversation with Bill.');
      return;
    }
    const summary = memory.recentActivitySummary;
    if (!summary) {
      refreshLog.recordImmediateFailure(trigger, 'No recent activity to describe yet — open a few recognised apps first.');
      return;
    }

    const undescribed = memory.undescribedFrequentApps().slice(0, MAX_APP_DESCRIPTIONS_PER_REFRESH);
    this.pendingDescriptions = Object.fromEntries(undescribed.map((a) => [a.name, a.id]));
    const marker = freshMarker();
    this.refreshMarker = marker;
    const prompt = refreshPrompt({
      marker, summary,
      appNames: undescribed.map((a) => a.name),
      extra: String(this.prefs.get('promptExtraInstructions') || '').trim(),
    });
    const id = refreshLog.begin(trigger, prompt);
    this.activeRefreshId = id;
    this.isPerformingBackgroundChatWork = true;

    const signedIn = await this.chatBridge.checkSignedIn();
    if (this.activeRefreshId !== id) return;
    if (!signedIn) {
      this.resolveRefresh(null, 'Not signed in. Bill\'s chat view has its own cookies — open "Open Full Chat View…" and log in to ChatGPT there once.');
      return;
    }
    clearTimeout(this.refreshWatchdog);
    this.refreshWatchdog = setTimeout(() => {
      if (this.activeRefreshId === id) this.resolveRefresh(null, 'Timed out after 150s with no reply. ChatGPT may not be signed in, or the page never finished loading.');
    }, REFRESH_TIMEOUT);
    const sent = await this.chatBridge.sendTask(prompt);
    if (!sent && this.activeRefreshId === id) this.resolveRefresh(null, 'Could not type into the ChatGPT page — its layout may have changed.');
  }

  finishDialogueRefresh(response) {
    const text = String(response || '');
    if (!text.trim()) { this.resolveRefresh(null, 'Empty response.'); return; }
    // Someone else's reply (an older message finishing late): keep waiting for ours.
    if (this.refreshMarker && !text.includes(this.refreshMarker)) return;
    this.resolveRefresh(text, null);
  }

  resolveRefresh(response, failure) {
    clearTimeout(this.refreshWatchdog);
    this.refreshWatchdog = null;
    this.isPerformingBackgroundChatWork = false;
    this.refreshMarker = null;
    const pending = this.pendingDescriptions;
    this.pendingDescriptions = {};
    const id = this.activeRefreshId;
    this.activeRefreshId = null;

    if (response === null) {
      if (id) refreshLog.finish(id, { failureReason: failure });
      return;
    }

    const parsed = parseRefresh(response, pending);
    for (const [name, description] of Object.entries(parsed.descriptions)) memory.setAppDescription(pending[name], description);

    const poolKeys = Object.keys(parsed.pools);
    if (poolKeys.length) {
      const merged = { ...memory.generatedPools };
      for (const key of poolKeys) merged[key] = mergePool(merged[key] ? { ...emptyPool(), ...merged[key] } : emptyPool(), parsed.pools[key], 12);
      memory.setGeneratedPools(merged);
      library.setGenerated(merged);
    }

    const flat = [];
    for (const key of poolKeys) {
      const pool = parsed.pools[key];
      for (const line of [...pool.any, ...pool.morning, ...pool.midday, ...pool.afternoon, ...pool.night]) flat.push(`${key}: ${line}`);
    }
    if (flat.length) {
      const counts = poolKeys.map((key) => [key, poolLineCount(parsed.pools[key])]).sort((a, b) => b[1] - a[1]);
      const total = counts.reduce((sum, [, n]) => sum + n, 0);
      flat.unshift(`= ${total} new lines in ${counts.length} pools: ${counts.slice(0, 8).map(([k, n]) => `${k}×${n}`).join(', ')}`);
    }
    const descriptions = Object.entries(parsed.descriptions).map(([name, description]) => ({ name, description }));
    const failureReason = !flat.length && !descriptions.length ? 'Reply received but nothing matched the POOL|TIME|LINE format.' : null;
    if (id) refreshLog.finish(id, { rawResponse: response, linesAdded: flat, descriptions, failureReason });
  }

  // --------------------------------------------------------- personalization
  wirePersonalization() {
    const p = this.personalization;
    p.send = (prompt) => { this.chatBridge.send(prompt); };
    p.presentLogin = () => this.showFullChat();
    p.weatherBlurbProvider = () => this.weather.blurb;
    p.extraInstructionsProvider = () => this.prefs.get('promptExtraInstructions');
    p.onRunFinished = () => {
      this.isPerformingBackgroundChatWork = false;
      this.roaming.resume();
    };
  }

  /** "Let Bill Study Your Apps" — a long run of requests through the same chat page. */
  async runPersonalizationSetup() {
    if (this.personalization.isActive || this.isAwaitingChatResponse || this.isPerformingBackgroundChatWork) return;
    this.isPerformingBackgroundChatWork = true;
    const signedIn = await this.chatBridge.checkSignedIn();
    if (!signedIn) {
      this.isPerformingBackgroundChatWork = false;
      this.personalization.requireLogin();
      return;
    }
    this.roaming.suspend();
    await this.personalization.begin();
  }
}

module.exports = { Conversation, parseRefresh, refreshPrompt, REFRESHABLE_POOLS };
