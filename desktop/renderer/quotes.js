// Quotes Manager (port of UI/QuotesManager/QuotesManagerController.swift):
// every dialogue pool, every line in it, and where each line came from.
(() => {
  const pools = document.getElementById('pools');
  const lines = document.getElementById('lines');
  const recent = document.getElementById('recent');
  const count = document.getElementById('count');
  const SOURCE = { authored: ['a', 'A', 'Authored'], generated: ['g', 'G', 'Generated'], personalized: ['p', 'P', 'Personalized'] };
  let selected = null;
  let signature = '';

  const el = (tag, className, text) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  };

  async function showPool(key) {
    selected = key;
    for (const row of pools.children) row.classList.toggle('active', row.dataset.key === key);
    const detail = await window.bill.invoke('quotes:detail', key);
    if (selected !== key) return;
    const top = lines.scrollTop;
    lines.replaceChildren(el('h2', '', key));
    if (!detail.length) lines.append(el('p', 'muted', 'No lines in this pool yet.'));
    for (const entry of detail) {
      const row = el('div', 'line');
      const [cls, letter, name] = SOURCE[entry.source] || SOURCE.authored;
      const tag = el('span', `tag ${cls}`, letter);
      tag.title = name;
      row.append(el('span', 'bucket', entry.time), tag, el('span', 'text', entry.text));
      lines.append(row);
    }
    lines.scrollTop = top;
  }

  async function refresh() {
    const state = await window.bill.invoke('quotes:state');
    count.textContent = `${state.pools.length} quote pools · ${state.totalLines} lines`;
    recent.replaceChildren(...(state.recent.length
      ? state.recent.map((line) => el('div', '', line))
      : [el('div', '', 'No refresh has run yet — hit “Refresh Every Quote Now” and watch it land here.')]));

    const next = JSON.stringify(state.pools);
    if (next === signature) return;
    signature = next;
    const top = pools.scrollTop;
    pools.replaceChildren(...state.pools.map((pool) => {
      const row = el('div', `pool${pool.key === selected ? ' active' : ''}`);
      row.dataset.key = pool.key;
      row.append(el('span', 'name', pool.key));
      if (pool.authored) row.append(el('span', 'tag a', `A ${pool.authored}`));
      if (pool.generated) row.append(el('span', 'tag g', `G ${pool.generated}`));
      if (pool.personalized) row.append(el('span', 'tag p', `P ${pool.personalized}`));
      row.append(el('span', 'total', String(pool.total)));
      row.addEventListener('click', () => showPool(pool.key));
      return row;
    }));
    pools.scrollTop = top;
    if (selected) showPool(selected);
  }

  document.getElementById('refresh').addEventListener('click', () => { window.bill.send('quotes:refresh'); setTimeout(refresh, 300); });
  document.getElementById('showLog').addEventListener('click', () => window.bill.send('quotes:showLog'));
  window.bill.on('quotes:update', refresh);
  setInterval(refresh, 3000);
  refresh();
})();
