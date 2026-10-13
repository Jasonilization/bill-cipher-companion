// The pixel chat bubble (port of UI/ChatWindow/{PixelChatBubble,PixelMessageBubble,
// PixelChatHeader}.swift): a stack of message bubbles above a compose box, all
// in the same layered pixel border as Bill's speech bubbles.
(() => {
  const USER_ACCENT = '#5c94db';
  const THINKING = ['THINKING.', 'THINKING..', 'THINKING...'];
  const { PixelArt } = window;

  const panel = document.getElementById('panel');
  const scroll = document.getElementById('scroll');
  const stack = document.getElementById('stack');
  const input = document.getElementById('input');
  const text = document.getElementById('text');
  const closeButton = document.getElementById('close');
  const title = document.getElementById('title');

  let style = { accent: '#fac726', dark: false, tailSide: 'left' };
  let composing = true;
  let thinkingBubble = null;
  let thinkingTimer = null;
  let thinkingIndex = 0;

  // ------------------------------------------------------------------ chrome
  function drawClose(hover) {
    const ctx = closeButton.getContext('2d');
    ctx.fillStyle = '#000'; ctx.fillRect(0, 0, 14, 14);
    ctx.fillStyle = hover ? '#d94033' : '#fafafa'; ctx.fillRect(2, 2, 10, 10);
    ctx.fillStyle = hover ? '#fff' : '#000';
    const step = 10 / 6;
    for (let i = 0; i < 4; i++) {
      ctx.fillRect(2 + step * (i + 1), 2 + step * (i + 1), step, step);
      ctx.fillRect(12 - step * (i + 2), 2 + step * (i + 1), step, step);
    }
  }
  closeButton.addEventListener('mouseenter', () => drawClose(true));
  closeButton.addEventListener('mouseleave', () => drawClose(false));
  closeButton.addEventListener('click', () => window.bill.send('chat:close'));
  drawClose(false);

  function restyle() {
    document.body.classList.toggle('dark', !!style.dark);
    document.body.style.setProperty('--accent', style.accent);
    PixelArt.attachFrame(panel, { radius: 8, border: 2, ring: 1, accent: style.accent, dark: style.dark });
    PixelArt.attachFrame(input, { radius: 6, border: 1, ring: 1, tail: style.tailSide, accent: style.accent, dark: style.dark });
    for (const bubble of stack.children) paintBubble(bubble);
    if (style.title) PixelArt.drawGrid(title, style.title, PixelArt.palette(style));
  }

  function paintBubble(bubble) {
    const accent = bubble.classList.contains('user') ? USER_ACCENT : style.accent;
    PixelArt.attachFrame(bubble, { radius: 6, border: 1, ring: 1, accent, dark: style.dark });
  }

  // ---------------------------------------------------------------- messages
  function linkify(target, message) {
    const pattern = /https?:\/\/[^\s<>"')\]]+/g;
    let last = 0; let match;
    while ((match = pattern.exec(message)) !== null) {
      if (match.index > last) target.append(document.createTextNode(message.slice(last, match.index)));
      const url = match[0].replace(/[.,;:!?]+$/, '');
      const link = document.createElement('a');
      link.textContent = url;
      link.addEventListener('click', (event) => { event.preventDefault(); window.bill.send('chat:openLink', url); });
      target.append(link);
      last = match.index + url.length;
      pattern.lastIndex = last;
    }
    if (last < message.length) target.append(document.createTextNode(message.slice(last)));
  }

  function makeBubble(message, isFromUser) {
    const bubble = document.createElement('div');
    bubble.className = `bubble pop ${isFromUser ? 'user' : 'bill'}`;
    const body = document.createElement('div');
    body.className = 'body';
    linkify(body, message);
    bubble.append(body);
    return bubble;
  }

  function scrollToBottom() { scroll.scrollTop = scroll.scrollHeight; }

  function append(message, isFromUser) {
    const bubble = makeBubble(message, isFromUser);
    if (thinkingBubble) stack.insertBefore(bubble, thinkingBubble); else stack.append(bubble);
    paintBubble(bubble);
    scrollToBottom();
  }

  function clearThinking() {
    clearInterval(thinkingTimer); thinkingTimer = null;
    if (thinkingBubble) { thinkingBubble.remove(); thinkingBubble = null; }
  }

  function beginComposing(focus = true) {
    composing = true;
    text.contentEditable = 'plaintext-only';
    text.classList.remove('waiting');
    if (focus) text.focus();
  }

  // -------------------------------------------------------------------- input
  function submit() {
    const message = text.innerText.trim();
    if (!message) return;
    text.textContent = '';
    append(message, true);
    window.bill.send('chat:submit', message);
  }

  text.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') { event.preventDefault(); window.bill.send('chat:close'); return; }
    if (!composing) { if (event.key.length === 1 || event.key === 'Enter') event.preventDefault(); return; }
    if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) { event.preventDefault(); submit(); }
  });
  // A lone <br> left behind by the editor would stop the placeholder coming back.
  text.addEventListener('input', () => { if (text.innerText.trim() === '' && text.innerHTML !== '') text.textContent = ''; });
  document.addEventListener('keydown', (event) => { if (event.key === 'Escape') window.bill.send('chat:close'); });
  // Clicking the box's frame should still land the caret.
  input.addEventListener('mousedown', (event) => { if (event.target !== text && composing) { event.preventDefault(); text.focus(); } });
  window.addEventListener('focus', () => { if (composing) text.focus(); });

  // --------------------------------------------------------------------- wire
  window.bill.on('chat:style', (next) => { style = { ...style, ...next }; restyle(); });

  window.bill.on('chat:compose', () => {
    clearThinking();
    beginComposing();
    scrollToBottom();
  });

  window.bill.on('chat:waiting', () => {
    composing = false;
    text.classList.add('waiting');
    clearThinking();
    thinkingIndex = 0;
    thinkingBubble = makeBubble(THINKING[0], false);
    stack.append(thinkingBubble);
    paintBubble(thinkingBubble);
    scrollToBottom();
    thinkingTimer = setInterval(() => {
      thinkingIndex += 1;
      if (thinkingBubble) thinkingBubble.querySelector('.body').textContent = THINKING[thinkingIndex % THINKING.length];
    }, 450);
  });

  window.bill.on('chat:response', (message) => {
    clearThinking();
    append(message, false);
    beginComposing();
  });

  window.bill.on('chat:user', (message) => append(message, true));

  window.bill.on('chat:clear', () => { clearThinking(); stack.textContent = ''; });

  restyle();
  window.bill.send('chat:ready');
})();
