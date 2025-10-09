// D:\Echo\room\echo-room\preload.js
const { contextBridge, ipcRenderer } = require('electron');

function on(channel, handler) {
  const listener = (_event, data) => handler && handler(data);
  ipcRenderer.on(channel, listener);
  return () => ipcRenderer.removeListener(channel, listener);
}

contextBridge.exposeInMainWorld('echoRoom', {
  // chat
  send: (text) => ipcRenderer.invoke('chat:send', text),

  // outbox append lines -> renderer
  onAppend: (handler) => on('chat:append', handler),

  // room pushes from main
  onRoom: (channel, handler) => on(channel, handler),

  // env & state
  getEnv: () => ipcRenderer.invoke('room:getEnv'),
  getState: () => ipcRenderer.invoke('room:getState'),
  saveState: (st) => ipcRenderer.invoke('room:saveState', st),

  // stand
  listStand: () => ipcRenderer.invoke('stand:list'),
  importStand: () => ipcRenderer.invoke('stand:import'),
  deleteStand: (filename) => ipcRenderer.invoke('stand:delete', filename),
});
