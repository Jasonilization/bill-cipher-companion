// "Bill Wants to Study Your Apps" (port of UI/Personalization/PersonalizationSetupController.swift).
(() => {
  const body = document.getElementById('body');
  let machine = 'computer';

  const el = (tag, className, text) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  };
  const button = (label, action, primary = true) => {
    const b = el('button', `btn wide${primary ? ' primary' : ''}`, label);
    b.addEventListener('click', () => window.bill.send('personalize:action', action));
    return b;
  };

  function appList(model) {
    const list = el('div');
    list.id = 'apps';
    for (const name of model.detectedApps) {
      const done = model.studiedApps[name] || 0;
      const row = el('div', `app${done > 0 ? ' done' : ''}`);
      row.append(el('span', 'mark', done > 0 ? '✓' : '·'), el('span', 'name', name));
      if (done > 0) row.append(el('span', 'lines', `${done} lines`));
      list.append(row);
    }
    return list;
  }

  const views = {
    intro(model) {
      const out = [el('p', '', `Bill will use his ChatGPT connection to write himself commentary about the apps on this ${machine} — a morning line, a midday line, an afternoon line and a night line for each app, plus lines for switching between your most-used apps.`)];
      if (model.detectedApps.length) out.push(el('p', 'caption', `Apps he can see right now (${model.detectedApps.length}):`), appList(model));
      else out.push(el('div', 'spacer'));
      out.push(
        el('p', 'caption', `Everything is written in his voice, on this machine, through the same chat he talks to you with — and takes a few minutes. You can keep using your ${machine} while he studies; the Quotes Manager (in Settings) shows every line the moment it lands.`),
        el('p', 'caption', 'You\'ll need to be signed in to ChatGPT in his chat window once.'),
        button('Let Bill Study Your Apps', 'start'),
      );
      return out;
    },

    generating(model) {
      const progress = el('progress');
      progress.max = 1; progress.value = Math.max(0.02, model.progress);
      const total = Object.values(model.studiedApps).reduce((sum, n) => sum + n, 0);
      const studied = Object.keys(model.studiedApps).length;
      const out = [
        progress,
        el('p', '', model.statusText || 'Bill is writing…'),
        el('p', 'caption', `request ${Math.min(model.batchIndex, model.batchCount)} of ${model.batchCount}`),
        el('p', 'caption', `Studying ${model.appCount} apps. Each batch goes live the moment it lands — no need to wait for the finish.`),
      ];
      if (total > 0) out.push(el('p', 'caption', `${total} lines written across ${studied} apps so far — watch them land live in Settings → Quotes Manager.`));
      out.push(appList(model), button('Hide — Bill keeps studying in the background', 'done', false));
      return out;
    },

    needsLogin() {
      return [
        el('p', '', 'Bill\'s embedded ChatGPT page isn\'t signed in. His browser is separate from yours, so your normal login doesn\'t carry over — sign in once in the window that just opened, then come back and start again.'),
        el('div', 'spacer'),
        button('Open the ChatGPT Login Page', 'login', false),
        button('Let Bill Study Your Apps', 'start'),
      ];
    },

    failed(model) {
      return [
        el('p', '', `Couldn't finish — ${model.failure || 'something went wrong.'}`),
        el('p', 'caption', 'Whatever landed before the problem is already active; re-running later tops it up without losing anything.'),
        el('div', 'spacer'),
        button('Try Again', 'start'),
      ];
    },

    finished(model) {
      return [
        el('p', '', model.finishedApps > 0
          ? `Done. Bill now has his own lines for ${model.finishedApps} of your apps — morning, midday, afternoon and night — plus transition quips for your most-used pairs. He's already using them.`
          : 'No launchable apps were found to study — Bill will keep his usual commentary.'),
        el('p', 'caption', 'Re-run any time from Bill\'s menu — new apps, new lines.'),
        el('div', 'spacer'),
        button('Bye!', 'done'),
      ];
    },
  };

  function render(model) {
    const list = document.getElementById('apps');
    const top = list ? list.scrollTop : 0;
    body.replaceChildren(...(views[model.phase] || views.intro)(model));
    const next = document.getElementById('apps');
    if (next) next.scrollTop = top;
  }

  window.bill.on('personalize:model', render);
  window.bill.invoke('personalize:state').then((state) => { machine = state.machine; render(state.model); });
})();
