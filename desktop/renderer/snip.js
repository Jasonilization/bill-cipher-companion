// The "show Bill the problem" overlay: drag a box, and its rectangle goes back
// to the main process. Nothing is captured here.
(() => {
  const box = document.getElementById('box');
  const hint = document.getElementById('hint');
  let start = null;
  let finished = false;

  const rectFrom = (a, b) => ({ x: Math.min(a.x, b.x), y: Math.min(a.y, b.y), width: Math.abs(a.x - b.x), height: Math.abs(a.y - b.y) });
  const finish = (channel, payload) => { if (finished) return; finished = true; window.bill.send(channel, payload); };

  function draw(r) {
    box.style.display = 'block';
    box.style.left = `${r.x}px`; box.style.top = `${r.y}px`;
    box.style.width = `${r.width}px`; box.style.height = `${r.height}px`;
  }

  document.addEventListener('mousedown', (event) => {
    if (event.button !== 0) { finish('snip:cancel'); return; }
    start = { x: event.clientX, y: event.clientY };
    hint.style.display = 'none';
    draw(rectFrom(start, start));
  });
  document.addEventListener('mousemove', (event) => { if (start) draw(rectFrom(start, { x: event.clientX, y: event.clientY })); });
  document.addEventListener('mouseup', (event) => {
    if (!start || event.button !== 0) return;
    const r = rectFrom(start, { x: event.clientX, y: event.clientY });
    start = null;
    // A click without a drag is not a selection.
    if (r.width < 8 || r.height < 8) { box.style.display = 'none'; hint.style.display = ''; return; }
    finish('snip:done', r);
  });
  document.addEventListener('contextmenu', (event) => { event.preventDefault(); finish('snip:cancel'); });
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') finish('snip:cancel');
    else if (event.key === 'Enter') finish('snip:done', { x: 0, y: 0, width: window.innerWidth, height: window.innerHeight });
  });
  window.bill.send('snip:ready');
})();
