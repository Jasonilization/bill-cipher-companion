// The bark bubble: one pixel-art speech bubble, faded in and out.
(() => {
  const canvas = document.getElementById('bubble');

  window.bill.on('bark:show', ({ grid, accent, dark }) => {
    canvas.className = '';
    window.PixelArt.drawGrid(canvas, grid, window.PixelArt.palette({ accent, dark }));
    // Commit the invisible state before starting the fade, or there is nothing to animate from.
    void canvas.offsetWidth;
    setTimeout(() => { canvas.className = 'shown'; }, 0);
  });

  window.bill.on('bark:hide', () => { canvas.className = 'fading'; });
})();
