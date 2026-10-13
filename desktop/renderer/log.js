// The dialogue refresh log: every attempt to have ChatGPT write new lines,
// with the prompt that went out, the raw reply and what was kept from it.
(() => {
  const entries = document.getElementById('entries');
  const open = new Set();

  const el = (tag, className, text) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  };
  const block = (title, body) => [el('h3', '', title), el('pre', '', body)];

  async function refresh() {
    const log = await window.bill.invoke('log:state');
    if (!log.length) {
      entries.replaceChildren(el('div', 'empty', 'No refresh has run yet. Bill asks ChatGPT for fresh lines a few times a day, once he has seen you use some apps — or right now, with “Refresh Now”.'));
      return;
    }
    entries.replaceChildren(...log.slice().reverse().map((entry) => {
      const details = el('details', 'entry card');
      details.open = open.has(entry.id);
      details.addEventListener('toggle', () => { if (details.open) open.add(entry.id); else open.delete(entry.id); });
      const summary = el('summary');
      const label = entry.status === 'running' ? 'IN FLIGHT' : entry.status === 'failed' ? 'FAILED' : 'OK';
      summary.append(el('span', 'when', new Date(entry.startedAt).toLocaleString()), el('span', `state ${entry.status}`, label), el('span', '', entry.trigger));
      details.append(summary);
      if (entry.failureReason) details.append(...block('Why it failed', entry.failureReason));
      if (entry.linesAdded && entry.linesAdded.length) details.append(...block('Lines added', entry.linesAdded.join('\n')));
      if (entry.descriptions && entry.descriptions.length) details.append(...block('App descriptions', entry.descriptions.map((d) => `${d.name}: ${d.description}`).join('\n')));
      if (entry.prompt) details.append(...block('Prompt sent', entry.prompt));
      if (entry.rawResponse) details.append(...block('Raw reply', entry.rawResponse));
      return details;
    }));
  }

  document.getElementById('refresh').addEventListener('click', () => window.bill.send('quotes:refresh'));
  document.getElementById('clear').addEventListener('click', () => window.bill.send('log:clear'));
  window.bill.on('log:update', refresh);
  refresh();
})();
