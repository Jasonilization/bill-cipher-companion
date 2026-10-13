// Settings (port of UI/Settings/SettingsView.swift). A plain view over the
// preferences the main process owns: every control writes straight through.
(() => {
  const SECTIONS = ['Appearance', 'Behaviour', 'Animations', 'Test Triggers', 'Chat & Prompts', 'Weather', 'About'];
  const sidebar = document.getElementById('sidebar');
  const detail = document.getElementById('detail');
  let state = null;
  let section = 'Appearance';

  // ------------------------------------------------------------------ helpers
  function h(tag, props = {}, ...children) {
    const el = document.createElement(tag);
    for (const [key, value] of Object.entries(props || {})) {
      if (key === 'class') el.className = value;
      else if (key.startsWith('on')) el.addEventListener(key.slice(2).toLowerCase(), value);
      else if (key in el) el[key] = value;
      else el.setAttribute(key, value);
    }
    for (const child of children.flat()) if (child !== null && child !== undefined && child !== false) el.append(child);
    return el;
  }
  const set = (key, value) => { state.prefs[key] = value; window.bill.send('settings:set', key, value); };
  const act = (name, arg) => window.bill.send('settings:action', name, arg);
  const header = (title, subtitle) => h('div', { class: 'section-header' }, h('h1', {}, title), subtitle ? h('p', {}, subtitle) : null);
  const card = (title, ...children) => h('div', { class: 'card' }, title ? h('h2', {}, title) : null, ...children);
  const caption = (text) => h('p', { class: 'caption' }, text);

  function toggle(label, key, { disabled = false, onChange } = {}) {
    const input = h('input', { type: 'checkbox', checked: !!state.prefs[key], disabled });
    input.addEventListener('change', () => { set(key, input.checked); if (onChange) onChange(input.checked); });
    return h('label', { class: `toggle${disabled ? ' disabled' : ''}` }, input, h('span', {}, label));
  }

  function slider(label, key, { min, max, step, format, onInput }) {
    const value = h('span', { class: 'value' }, format(state.prefs[key]));
    const input = h('input', { type: 'range', min, max, step, value: state.prefs[key] });
    input.addEventListener('input', () => {
      const v = Number(input.value);
      value.textContent = format(v);
      set(key, v);
      if (onInput) onInput(v);
    });
    return h('div', { class: 'row' }, label ? h('span', { class: 'label' }, label) : null, input, value);
  }

  function stepper(key, { min, max, step, label }) {
    const text = h('span', {}, label(state.prefs[key]));
    const bump = (delta) => {
      const next = Math.min(max, Math.max(min, state.prefs[key] + delta));
      set(key, next);
      text.textContent = label(next);
    };
    return h('div', { class: 'stepper' },
      h('button', { class: 'btn', onClick: () => bump(-step) }, '−'),
      h('button', { class: 'btn', onClick: () => bump(step) }, '+'),
      text);
  }

  function picker(label, current, onPick) {
    const select = h('select', {}, h('option', { value: '' }, 'Automatic'), state.states.map((s) => h('option', { value: s }, s)));
    select.value = current || '';
    select.addEventListener('change', () => onPick(select.value));
    return h('div', { class: 'row' }, h('span', { class: 'label' }, label), select);
  }

  const percent = (v) => `${Math.round(v * 100)}%`;

  // ----------------------------------------------------------------- sections
  const preview = h('canvas');
  async function paintPreview() {
    const grid = await window.bill.invoke('settings:bubblePreview', state.prefs.bubbleTextScale);
    if (!grid) return;
    window.PixelArt.drawGrid(preview, grid, window.PixelArt.palette({ accent: `#${state.prefs.bubbleAccentColorHex}`, dark: state.prefs.darkModeChrome }));
  }

  const render = {
    Appearance() {
      const colour = h('input', { type: 'color', value: `#${state.prefs.bubbleAccentColorHex}` });
      colour.addEventListener('input', () => { set('bubbleAccentColorHex', colour.value.replace('#', '')); paintPreview(); });
      paintPreview();
      return [
        header('Appearance', 'How Bill looks on your desktop'),
        card('Character',
          slider('Bill\'s size', 'characterScale', { min: 0.5, max: 2, step: 0.05, format: percent }),
          toggle('Dark mode chrome', 'darkModeChrome', { onChange: paintPreview }),
          caption('Uses a darker fill inside the pixel borders for the chat window and bark panels — better for dark desktops.')),
        card('Speech Bubbles',
          h('div', { class: 'preview' }, preview),
          h('div', { class: 'row' }, h('span', { class: 'label' }, 'Bubble colour'), colour),
          slider('Text size', 'bubbleTextScale', { min: 0.6, max: 2.4, step: 0.05, format: percent, onInput: paintPreview }),
          slider('Chat width', 'chatBubbleMaxWidth', { min: 320, max: 900, step: 20, format: (v) => `${Math.round(v)}px` }),
          caption('Changes apply on the next speech bubble.')),
      ];
    },

    Behaviour() {
      const titlesOn = !!state.prefs.windowAwareness;
      const troll = state.prefs.mode !== 'helpful';
      const ocr = state.ocr || { available: false, detail: '' };
      return [
        header('Behaviour', 'What Bill does on his own'),
        card('Personality',
          h('div', { class: 'row' },
            h('button', { class: `btn${troll ? ' primary' : ''}`, onClick: () => { set('mode', 'troll'); show('Behaviour'); } }, 'Troll'),
            h('button', { class: `btn${troll ? '' : ' primary'}`, onClick: () => { set('mode', 'helpful'); show('Behaviour'); } }, 'Helpful')),
          caption(troll
            ? 'Troll: he snatches your cursor, shakes the window he lands on and presses minimize buttons. Everything goes back where it was.'
            : 'Helpful: no pranks. When the window you are in looks like it is showing an error, he offers to read it and help.'),
          toggle('Cursor snatching', 'cursorPranks', { disabled: !troll || !state.canMoveCursor }),
          toggle('Window shaking', 'windowPranks', { disabled: !troll }),
          toggle('Offer help when something looks broken', 'helpOffers', { disabled: troll }),
          h('div', { class: 'row' },
            h('button', { class: 'btn primary', onClick: () => act('solveRegion') }, 'Solve something on screen…'),
            h('button', { class: 'btn', onClick: () => act('undoMischief') }, 'Undo Bill\'s mischief')),
          caption(`${state.activeSolveHotkey ? `Press ${state.activeSolveHotkey.replace(/\+/g, ' + ')} anywhere, ` : 'Right-click Bill and pick Solve Something On Screen, '}drag a box around a problem, and he answers it. Sums and equations he does himself; wordier questions go to his chat brain.${state.canReadScreen ? '' : ' His screen reader is missing from this install.'}`)),
        card('Activity',
          toggle('Bill roams the screen', 'roaming'),
          toggle('Minimize-button mischief', 'minimizeMischief', { disabled: !troll }),
          caption('Every so often he lands on a background window\'s minimize button and presses it. Never the window you are using.'),
          toggle('Launch Bill at login', 'launchAtLogin'),
          caption(state.activeHotkey
            ? `Talk to Bill from anywhere: ${state.activeHotkey.replace(/\+/g, ' + ')}. Right-click him for everything else.`
            : 'Right-click Bill, or his tray icon, to talk to him. (The keyboard shortcut is in use by another app.)')),
        card('Speech frequency',
          slider('How often Bill speaks', 'speakingFrequency', { min: 0.25, max: 2.5, step: 0.05, format: percent }),
          h('div', { class: 'ends' }, h('span', {}, 'Quiet'), h('span', {}, 'Chatty'))),
        card('Awareness',
          toggle('Read window titles', 'windowAwareness', { onChange: () => show(section) }),
          caption('Lets Bill react to what the focused window is showing — a pull request, a search, a late-night video. Titles are read on this computer and are never sent anywhere.'),
          h('div', { class: 'status ok' }, '✓', h('span', {}, `No permission needed on ${state.platformName}.`)),
          toggle('Read window contents (OCR)', 'screenOCR', { disabled: !titlesOn }),
          caption('Only when a title is not enough, at most a few times a minute, and entirely on this computer.'),
          h('div', { class: `status ${ocr.available ? 'ok' : 'warn'}` }, ocr.available ? '✓' : '⚠', h('span', {}, ocr.detail || (ocr.available ? 'Text recognition is available.' : 'Text recognition is not available.')))),
      ];
    },

    Animations() {
      const custom = state.prefs.customAnimationMap || {};
      const perApp = state.prefs.perAppAnimations || {};
      const write = (key, map, id, value) => {
        const next = { ...map };
        if (value) next[id] = value; else delete next[id];
        set(key, next);
      };
      return [
        header('Animations', 'Pacing and per-trigger overrides'),
        card('Idle pacing',
          slider('Time between idle animations', 'ambientAnimationSpacing', { min: 0.25, max: 4, step: 0.05, format: (v) => `${v.toFixed(2)}×` }),
          h('div', { class: 'ends' }, h('span', {}, 'Twitchy'), h('span', {}, 'Lazy'))),
        card('Per-trigger animations',
          state.animationTriggers.map(([key, label]) => picker(label, custom[key], (value) => write('customAnimationMap', state.prefs.customAnimationMap || {}, key, value)))),
        card('Per-app animations',
          state.apps.length
            ? state.apps.map((app) => picker(app.name, perApp[app.id], (value) => write('perAppAnimations', state.prefs.perAppAnimations || {}, app.id, value)))
            : caption('Open a few apps and Bill will list them here.')),
      ];
    },

    'Test Triggers'() {
      return [
        header('Test Triggers', 'Fire any reaction live to verify it works'),
        card('Reaction triggers',
          caption('Press any button — Bill should react on your desktop immediately.'),
          h('div', { class: 'grid' }, state.testTriggers.map(([key, label]) => h('button', { class: 'btn', onClick: () => act('testTrigger', key) }, label))),
          h('div', {}, h('button', { class: 'btn primary', onClick: () => act('testWeather') }, 'Test Weather'))),
      ];
    },

    'Chat & Prompts'() {
      const notes = h('textarea', { value: state.prefs.promptExtraInstructions || '', spellcheck: false });
      notes.addEventListener('input', () => set('promptExtraInstructions', notes.value));
      return [
        header('Chat & Prompts', 'Dialogue management and persona'),
        card('Quotes',
          h('div', {}, h('button', { class: 'btn', onClick: () => act('openQuotes') }, 'Open the Quotes Manager…')),
          caption('Every pool, every line, where each came from — plus one-click refresh.')),
        card('Refresh cadence',
          stepper('promptRefreshesPerDay', { min: 1, max: 6, step: 1, label: (v) => `Refresh Bill's lines ${v}x per day` }),
          caption('Spread across the day, never while you\'re mid-conversation.')),
        card('Extra persona instructions',
          notes,
          caption('Appended to every prompt — e.g. "call me Pine Tree", "mention the journals more".')),
        card('Chat account',
          h('div', { class: 'row' },
            h('button', { class: 'btn', onClick: () => act('openChat') }, 'Open Full Chat View…'),
            h('button', { class: 'btn danger', onClick: () => act('signOut') }, 'Sign out of ChatGPT')),
          caption('Bill talks through the real ChatGPT page in his own browser window, with his own cookies. Sign in there once; there is no API key.')),
      ];
    },

    Weather() {
      return [
        header('Weather', 'Bill comments on the sky'),
        card('Weather commentary',
          toggle('Bill talks about the weather', 'weatherEnabled'),
          stepper('weatherAnnounceMinutes', { min: 0, max: 240, step: 15, label: (v) => (v === 0 ? 'Report only on changes' : `Mention current weather every ${v} min`) }),
          caption('Pulls keyless Open-Meteo nowcast every 5 minutes.'),
          h('div', {}, h('button', { class: 'btn', onClick: () => act('testWeather') }, 'Test weather now'))),
      ];
    },

    About() {
      const days = state.daysKnown;
      return [
        header('About', ''),
        card('',
          h('p', { style: 'font-size:15px;font-weight:650' }, 'Bill Cipher — Desktop Companion'),
          h('p', { class: 'muted' }, `Version ${state.version} · ${state.platformName}`)),
        card('Memory',
          h('p', {}, `Bill has known you for ${days} day${days === 1 ? '' : 's'}.`),
          h('div', {}, h('button', { class: 'btn danger', onClick: () => act('resetMemory') }, 'Reset memory'))),
        card('Credits',
          h('p', { style: 'font-weight:600' }, 'Bill Cipher sprite artwork'),
          h('p', {}, 'Original artwork: Kelly Nora (@kiernenking)'),
          h('p', {}, 'Sprite sheet: JayHyperstarX — ', h('a', { onClick: () => act('openLink', 'https://www.deviantart.com/jayhyperstarx/art/Bill-Cipher---Sprite-Sheet-910916786') }, 'DeviantArt')),
          h('p', {}, 'Original macOS app: Jasonilization — ', h('a', { onClick: () => act('openLink', 'https://github.com/Jasonilization/bill-cipher-companion') }, 'GitHub')),
          caption('Unofficial, non-commercial fan project. Bill Cipher and Gravity Falls are © Disney. Code is MIT.')),
      ];
    },
  };

  function show(name) {
    section = SECTIONS.includes(name) ? name : 'Appearance';
    for (const button of sidebar.children) button.classList.toggle('active', button.dataset.section === section);
    const top = detail.scrollTop;
    detail.replaceChildren(...render[section]());
    detail.scrollTop = top;
  }

  async function load(resetScroll) {
    state = await window.bill.invoke('settings:state');
    if (resetScroll) detail.scrollTop = 0;
    show(section);
  }

  SECTIONS.forEach((name) => {
    const button = h('button', { onClick: () => { detail.scrollTop = 0; set('selectedSettingsSection', name); show(name); } }, name);
    button.dataset.section = name;
    sidebar.append(button);
  });

  // Something else changed a preference (the tray menu, a reset): redraw, but
  // never under a control the user is in the middle of dragging.
  window.bill.on('settings:prefs', (prefs) => {
    if (!state) return;
    const changed = Object.keys(prefs).some((key) => JSON.stringify(prefs[key]) !== JSON.stringify(state.prefs[key]));
    state.prefs = prefs;
    if (changed && !document.activeElement.matches('input, textarea, select')) show(section);
  });
  window.bill.on('settings:reload', () => load(false));
  window.bill.on('settings:section', (name) => show(name));

  window.bill.invoke('settings:state').then((initial) => {
    state = initial;
    show(state.prefs.selectedSettingsSection);
  });
})();
