// D:\Echo\room\echo-room\main.js — state-safe edition
const { app, BrowserWindow, ipcMain, dialog, Menu } = require('electron');
const path = require('path');
const fs = require('fs');
const { pathToFileURL } = require('url');
const chokidar = require('chokidar');

const HOME = process.env.ECHO_HOME && process.env.ECHO_HOME.trim().length > 0 ? process.env.ECHO_HOME : 'D:\\Echo';
const DECOR = path.join(HOME, 'decor');
const UI = path.join(HOME, 'ui');
const INBOXQ = path.join(UI, 'inboxq');
const OUTBOX = path.join(UI, 'outbox.jsonl');
const STATE_PATH = path.join(UI, 'state.json');
const STAND_DIR = path.join(HOME, 'stand');

// --- Guard constants ---
const MAX_STATE_BYTES = 5 * 1024 * 1024; // 5 MB safety cap
const MAX_ITEMS = 100; // cap sticky/note counts

function ensureDir(p) { if (!fs.existsSync(p)) fs.mkdirSync(p, { recursive: true }); }
function ensureFile(p) { if (!fs.existsSync(p)) fs.writeFileSync(p, '', { encoding: 'utf8' }); }
function stripBOM(s) { return s && s.charCodeAt(0) === 0xFEFF ? s.slice(1) : s; }
function fileUrl(p) { return pathToFileURL(p).toString(); }

// --- Default + Safe State Helpers ---
function defaultState() {
  return {
    background: 'file:///D:/Echo/decor/wallpaper.jpg',
    theme: 'dark',
    alwaysOnTop: false,
    clickThrough: false,
    width: 1100,
    height: 700,
    widgets: [],
    stickies: [],
    notes: [],
    stand: { visible: true, current: '', x: 480, y: 280, scale: 100, mirror: false },
    version: 1
  };
}

function rotateState(reason) {
  try {
    const rotated = `${STATE_PATH}.${reason}.${Date.now()}.bak`;
    if (fs.existsSync(STATE_PATH)) fs.renameSync(STATE_PATH, rotated);
    const fresh = defaultState();
    const tmp = STATE_PATH + '.tmp';
    fs.writeFileSync(tmp, JSON.stringify(fresh, null, 2), 'utf8');
    fs.renameSync(tmp, STATE_PATH);
  } catch { /* ignore */ }
}

function compactState(state) {
  state = state && typeof state === 'object' ? state : {};
  // normalize arrays
  const arr = (x) => Array.isArray(x) ? x : [];
  state.stickies = arr(state.stickies).slice(-MAX_ITEMS);
  state.notes = arr(state.notes).slice(-MAX_ITEMS);

  // avoid embedding giant strings/base64 blobs
  state.stickies = state.stickies.map(s => {
    const t = { ...s };
    if (typeof t.body === 'string' && t.body.length > 4000) t.body = t.body.slice(0, 4000);
    if (typeof t.image === 'string' && t.image.startsWith('data:image/')) delete t.image;
    return t;
  });

  state.version ??= 1;
  return state;
}

function readStateSafe() {
  try {
    if (fs.existsSync(STATE_PATH)) {
      const st = fs.statSync(STATE_PATH);
      if (st.size > MAX_STATE_BYTES) {
        rotateState('oversize');
        return defaultState();
      }
      const raw = fs.readFileSync(STATE_PATH, 'utf8');
      const parsed = JSON.parse(stripBOM(raw) || 'null') || {};
      return compactState(parsed);
    } else {
      // create default on first run
      writeStateSafe(defaultState());
      return defaultState();
    }
  } catch {
    rotateState('parsefail');
    return defaultState();
  }
}

function writeStateSafe(st) {
  try {
    const clean = compactState(st || {});
    const tmp = STATE_PATH + '.tmp';
    ensureDir(path.dirname(STATE_PATH));
    fs.writeFileSync(tmp, JSON.stringify(clean, null, 2), 'utf8'); // atomic-ish write
    fs.renameSync(tmp, STATE_PATH);
  } catch (e) {
    // last resort: rotate and rewrite default
    rotateState('writefail');
  }
}

function listStand() {
  const exts = new Set(['.png', '.jpg', '.jpeg', '.gif', '.webp']);
  const items = [];
  function walk(dir, rel) {
    const entries = fs.readdirSync(dir, { withFileTypes: true });
    for (const ent of entries) {
      const abs = path.join(dir, ent.name);
      const relPath = rel ? path.join(rel, ent.name) : ent.name;
      if (ent.isDirectory()) {
        walk(abs, relPath);
      } else {
        const ext = path.extname(ent.name).toLowerCase();
        if (exts.has(ext)) {
          items.push({
            name: ent.name,
            path: abs,
            url: fileUrl(abs),
            rel: rel || ''
          });
        }
      }
    }
  }
  if (fs.existsSync(STAND_DIR)) walk(STAND_DIR, '');
  return items;
}

// --- Ensure dirs/files & preflight the state file ---
ensureDir(HOME); ensureDir(DECOR); ensureDir(UI); ensureDir(INBOXQ); ensureDir(STAND_DIR);
if (!fs.existsSync(STATE_PATH)) {
  writeStateSafe(defaultState());
} else {
  try {
    const st = fs.statSync(STATE_PATH);
    if (st.size > MAX_STATE_BYTES) rotateState('oversize');
  } catch { rotateState('statfail'); }
}
ensureFile(OUTBOX);

let mainWindow;
let tailPos = 0;

function enforceOnTop(on) {
  if (!mainWindow) return;

  // 1) try normal unpin/pin
  try { mainWindow.setAlwaysOnTop(false); } catch {}
  if (on) {
    // give WM a beat on Windows before re-pinning
    if (process.platform === 'win32') {
      mainWindow.blur();
      setTimeout(() => {
        try { mainWindow.setAlwaysOnTop(true, 'normal'); } catch {}
      }, 30);
    } else {
      try { mainWindow.setAlwaysOnTop(true, 'normal'); } catch {}
    }
  }

  // 2) verify later; if still wrong on Windows, hard reset
  setTimeout(() => {
    const isTop = mainWindow && mainWindow.isAlwaysOnTop && mainWindow.isAlwaysOnTop();
    if (!on && isTop && process.platform === 'win32') {
      hardUnpinRecreate();
    }
  }, 80);
}

function hardUnpinRecreate() {
  if (!mainWindow) return;
  const bounds = mainWindow.getBounds();
  const wasFocused = mainWindow.isFocused();
  // destroy & recreate without any alwaysOnTop option
  mainWindow.destroy();
  createWindow();
  if (mainWindow) {
    mainWindow.setBounds(bounds);
    try { mainWindow.setAlwaysOnTop(false); } catch {}
    if (wasFocused) mainWindow.focus();
  }
}

function createWindow() {
  const state = readStateSafe();
  mainWindow = new BrowserWindow({
    width: Number(state.width) || 1100,
    height: Number(state.height) || 700,
    backgroundColor: '#111111',
    webPreferences: {
      contextIsolation: true,
      preload: path.join(__dirname, 'preload.js'),
    }
  });
  enforceOnTop(!!state.alwaysOnTop);

  const menu = Menu.buildFromTemplate([
    {
      label: 'File',
      submenu: [
        {
          label: 'Pick Background…',
          click: async () => {
            const res = await dialog.showOpenDialog(mainWindow, {
              title: 'Choose Background',
              properties: ['openFile'],
              filters: [{ name: 'Images', extensions: ['jpg', 'jpeg', 'png', 'webp'] }]
            });
            if (!res.canceled && res.filePaths.length > 0) {
              const src = res.filePaths[0];
              const ext = path.extname(src) || '.jpg';
              const dest = path.join(DECOR, 'wallpaper' + ext);
              fs.copyFileSync(src, dest);
              mainWindow.webContents.send('room:background', fileUrl(dest));
            }
          }
        },
        // { label: 'Toggle DevTools', click: () => mainWindow.webContents.toggleDevTools() }
      ]
    }
  ]);
  Menu.setApplicationMenu(menu);

  mainWindow.loadFile(path.join(__dirname, 'renderer', 'index.html'));
}

app.whenReady().then(() => {
  createWindow();

  // Watch wallpaper changes
  const decorWatcher = chokidar.watch(path.join(DECOR, 'wallpaper.*'), {
    ignoreInitial: false,
    awaitWriteFinish: { stabilityThreshold: 300, pollInterval: 100 }
  });
  decorWatcher.on('add', p => mainWindow.webContents.send('room:background', fileUrl(p)));
  decorWatcher.on('change', p => mainWindow.webContents.send('room:background', fileUrl(p)));

  // Watch state.json with safety
  const stateWatcher = chokidar.watch(STATE_PATH, {
    ignoreInitial: false,
    awaitWriteFinish: { stabilityThreshold: 200, pollInterval: 100 }
  });

  function pushStateFromDisk() {
    const st = readStateSafe();
    if (!mainWindow) return;
    if (st.width && st.height) {
      mainWindow.setSize(Number(st.width) || 1100, Number(st.height) || 700);
    }
    enforceOnTop(!!st.alwaysOnTop);
    mainWindow.webContents.send('room:state', st);
  }

  stateWatcher.on('add', pushStateFromDisk);
  stateWatcher.on('change', pushStateFromDisk);

  // Tail outbox.jsonl
  tailPos = 0;
  const outboxWatcher = chokidar.watch(OUTBOX, {
    ignoreInitial: false,
    awaitWriteFinish: { stabilityThreshold: 150, pollInterval: 80 }
  });
  function readNewLines() {
    try {
      const stats = fs.statSync(OUTBOX);
      let start = tailPos;
      if (stats.size < start) start = 0; // truncated
      if (stats.size === start) return;
      const fd = fs.openSync(OUTBOX, 'r');
      const length = stats.size - start;
      const buffer = Buffer.alloc(length);
      fs.readSync(fd, buffer, 0, length, start);
      fs.closeSync(fd);
      tailPos = stats.size;
      const text = stripBOM(buffer.toString('utf8'));
      const lines = text.split(/\r?\n/).filter(l => l.trim().length > 0);
      for (const l of lines) {
        try {
          const obj = JSON.parse(stripBOM(l));
          mainWindow.webContents.send('chat:append', obj);
        } catch (e) {
          console.warn('Bad JSONL line:', e);
        }
      }
    } catch (e) { /* ignore */ }
  }
  outboxWatcher.on('add', readNewLines);
  outboxWatcher.on('change', readNewLines);

  // Watch stand directory
  const standWatcher = chokidar.watch(STAND_DIR, { ignoreInitial: false });
  const pushStandList = () => mainWindow.webContents.send('stand:list', listStand());
  standWatcher.on('add', pushStandList);
  standWatcher.on('unlink', pushStandList);
  pushStandList();

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
    const st = readStateSafe();
    enforceOnTop(!!st.alwaysOnTop);
  });
});

app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });

/* IPC exposed to renderer */
ipcMain.handle('chat:send', async (_evt, text) => {
  try {
    ensureDir(INBOXQ);
    const slug = Date.now().toString() + '-' + Math.random().toString(36).slice(2, 7);
    const file = path.join(INBOXQ, `${slug}.txt`);
    fs.writeFileSync(file, text ?? '', 'utf8');
    return { ok: true };
  } catch (e) {
    return { ok: false, error: String(e.message || e) };
  }
});

ipcMain.handle('room:getEnv', async () => {
  const wpCandidates = fs.readdirSync(DECOR)
    .filter(n => /^wallpaper\./i.test(n))
    .map(n => fileUrl(path.join(DECOR, n)));
  return {
    ECHO_HOME: HOME,
    WALLPAPER: wpCandidates[0] || 'file:///D:/Echo/decor/wallpaper.jpg',
    STATE_PATH
  };
});

ipcMain.handle('room:getState', async () => readStateSafe());
ipcMain.handle('room:saveState', async (_evt, st) => {
  try { writeStateSafe(st || {}); return { ok: true }; }
  catch (e) { return { ok: false, error: String(e.message || e) }; }
});

ipcMain.handle('stand:list', async () => listStand());
ipcMain.handle('stand:import', async () => {
  try {
    const res = await dialog.showOpenDialog(mainWindow, {
      title: 'Import Stand Images',
      properties: ['openFile', 'multiSelections'],
      filters: [{ name: 'Images', extensions: ['png', 'jpg', 'jpeg', 'gif', 'webp'] }]
    });
    if (res.canceled) return { ok: true, items: listStand() };
    for (const src of res.filePaths) {
      const base = path.basename(src);
      fs.copyFileSync(src, path.join(STAND_DIR, base));
    }
    return { ok: true, items: listStand() };
  } catch (e) {
    return { ok: false, items: listStand(), error: String(e.message || e) };
  }
});
ipcMain.handle('stand:delete', async (_evt, filename) => {
  try {
    const p = path.join(STAND_DIR, filename);
    if (fs.existsSync(p)) fs.unlinkSync(p);
    return { ok: true, items: listStand() };
  } catch (e) {
    return { ok: false, items: listStand(), error: String(e.message || e) };
  }
});
