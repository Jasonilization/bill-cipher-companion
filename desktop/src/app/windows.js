// Shared plumbing for Bill's own (local-file) windows.
const path = require('path');
const { ipcMain } = require('electron');

const rendererFile = (name) => path.join(__dirname, '..', '..', 'renderer', name);

const localWebPreferences = () => ({
  preload: rendererFile('preload.js'),
  contextIsolation: true,
  nodeIntegration: false,
  sandbox: true,
  backgroundThrottling: false,
});

/** These windows only ever show their own page: no navigation, no pop-ups. */
function lockDown(win) {
  win.webContents.on('will-navigate', (event) => event.preventDefault());
  win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  win.setMenuBarVisibility(false);
}

/** `ipcMain.on`, but only for messages that really came from `getWindow()`. */
function listen(channel, getWindow, handler) {
  ipcMain.on(channel, (event, ...args) => {
    const win = getWindow();
    if (win && !win.isDestroyed() && event.sender === win.webContents) handler(...args);
  });
}

module.exports = { rendererFile, localWebPreferences, lockDown, listen };
