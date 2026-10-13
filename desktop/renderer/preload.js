// Shared preload for Bill's own windows. Every one of them is a dumb view:
// the main process owns all state and tells them what to draw.
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('bill', {
  on: (channel, handler) => { ipcRenderer.on(channel, (_event, ...args) => handler(...args)); },
  send: (channel, ...args) => ipcRenderer.send(channel, ...args),
  invoke: (channel, ...args) => ipcRenderer.invoke(channel, ...args),
});
