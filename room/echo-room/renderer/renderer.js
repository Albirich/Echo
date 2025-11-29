// D:\Echo\room\echo-room\renderer\renderer.js
/* global window, document */
const api = window.echoRoom;

const els = {
  bg: document.getElementById('background'),
  standWrap: document.getElementById('stand'),
  standImg: document.getElementById('stand-img'),
  standScale: document.getElementById('stand-scale'),
  gamePrompt: document.getElementById('game-prompt'),
  widgets: document.getElementById('widgets'),
  status: document.getElementById('status'),
  chatLog: document.getElementById('chat-log'),
  chatForm: document.getElementById('chat-form'),
  chatInput: document.getElementById('chat-input'),
};

let roomState = {
  background: 'file:///D:/Echo/decor/wallpaper.jpg',
  theme: 'dark',
  alwaysOnTop: false,
  clickThrough: false,
  width: 1100, height: 700,
  widgets: [],
  stand: { visible: true, current: '', x:480, y:280, scale:100, mirror:false },
  gamePromptFile: ''
};
let gamePromptOptions = [];

function toast(msg) {
  els.status.textContent = msg;
  setTimeout(() => { if (els.status.textContent === msg) els.status.textContent = ''; }, 1500);
}

function toFileUrl(p) {
    if (!p) return '';
    if (p.startsWith('file://')) return p;
    return 'file:///' + p.replace(/\\/g, '/');
}

let saveTimer = null;
function scheduleSave() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(async () => {
    roomState.widgets = getWidgetsFromDom();
    const res = await api.saveState(roomState);
    toast(res.ok ? 'Saved' : 'Save failed');
  }, 300);
}

/* Chat rendering */
const MAX_CHAT_LINES = 100; // Limit chat history to prevent DOM bloat

function addLine(kind, text) {
  if (!text || !text.trim()) return;
  const div = document.createElement('div');
  div.className = `line ${kind}`;
  const who = document.createElement('span');
  who.className = 'who';
  who.textContent = kind === 'user' ? 'You:' : 'Echo:';
  const body = document.createElement('span');
  body.textContent = text;
  div.appendChild(who); div.appendChild(body);
  els.chatLog.appendChild(div);
  
  // Remove old messages to prevent infinite DOM growth
  while (els.chatLog.children.length > MAX_CHAT_LINES) {
    els.chatLog.removeChild(els.chatLog.firstChild);
  }
  
  els.chatLog.scrollTop = els.chatLog.scrollHeight;
}

/* Widgets (sticky notes) */
// Store observers so we can clean them up
let widgetObservers = [];

function renderWidgets(list) {
  // Clean up old observers to prevent memory leaks
  widgetObservers.forEach(obs => obs.disconnect());
  widgetObservers = [];
  
  els.widgets.innerHTML = '';
  (list || []).forEach(n => {
    const el = document.createElement('div');
    el.className = 'note';
    el.style.left = (n.x || 60) + 'px';
    el.style.top = (n.y || 60) + 'px';
    el.style.borderColor = n.color || '#69f';

    const handle = document.createElement('div');
    handle.className = 'handle';
    handle.textContent = 'note';
    const text = document.createElement('div');
    text.className = 'text';
    text.contentEditable = 'true';
    text.textContent = n.text || '';

    el.appendChild(handle);
    el.appendChild(text);
    els.widgets.appendChild(el);

    // drag
    let dragging = false, startX = 0, startY = 0, baseX = n.x || 60, baseY = n.y || 60;
    handle.addEventListener('mousedown', (e) => { dragging = true; startX = e.clientX; startY = e.clientY; baseX = parseInt(el.style.left, 10); baseY = parseInt(el.style.top, 10); e.preventDefault(); });
    window.addEventListener('mousemove', (e) => {
      if (!dragging) return;
      const dx = e.clientX - startX, dy = e.clientY - startY;
      el.style.left = (baseX + dx) + 'px';
      el.style.top = (baseY + dy) + 'px';
    });
    window.addEventListener('mouseup', () => { dragging = false; });

    // persist on blur
    text.addEventListener('blur', () => { n.text = text.textContent; scheduleSave(); });
    // store live position
    const observer = new MutationObserver(() => {
      n.x = parseInt(el.style.left, 10) || 60;
      n.y = parseInt(el.style.top, 10) || 60;
      scheduleSave();
    });
    observer.observe(el, { attributes: true, attributeFilter: ['style'] });
    widgetObservers.push(observer); // Track for cleanup
  });
}
function getWidgetsFromDom() {
  const list = [];
  Array.from(els.widgets.children).forEach((el, idx) => {
    const text = el.querySelector('.text').textContent;
    const x = parseInt(el.style.left, 10) || 60;
    const y = parseInt(el.style.top, 10) || 60;
    list.push({ id: roomState.widgets[idx]?.id || `w_${Math.random().toString(36).slice(2,8)}`, x, y, text, color: '#69f' });
  });
  return list;
}

/* Stand controls */
function applyStand(st) {
  const show = (st.visible !== false);
  els.standImg.style.display = show ? 'block' : 'none';

  if (st.current) els.standImg.src = st.current;
  els.standImg.style.left = (st.x || 480) + 'px';
  els.standImg.style.top = (st.y || 280) + 'px';
  const scale = (st.scale || 100) / 100;
  const flip = st.mirror ? -1 : 1;
  els.standImg.style.transform = `scale(${flip}, 1) scale(${scale})`;
  els.standScale.value = String(st.scale || 100);
}

/* Drag the stand */
(function setupStandDrag() {
  let dragging = false, startX=0, startY=0, baseX=0, baseY=0;
  els.standImg.addEventListener('mousedown', (e) => {
    dragging = true; startX = e.clientX; startY = e.clientY;
    baseX = parseInt(els.standImg.style.left, 10) || 480;
    baseY = parseInt(els.standImg.style.top, 10) || 280;
    e.preventDefault();
  });
  window.addEventListener('mousemove', (e) => {
    if (!dragging) return;
    const dx = e.clientX - startX, dy = e.clientY - startY;
    const x = baseX + dx, y = baseY + dy;
    els.standImg.style.left = x + 'px';
    els.standImg.style.top = y + 'px';
    roomState.stand.x = x; roomState.stand.y = y;
  });
  window.addEventListener('mouseup', () => { if (dragging) { dragging = false; scheduleSave(); } else { dragging = false; } });
})();

/* Wire toolbar */
els.standScale.addEventListener('input', () => {
  const v = Math.max(40, Math.min(200, parseInt(els.standScale.value,10)||100));
  roomState.stand.scale = v;
  applyStand(roomState.stand);
  scheduleSave();
});
els.gamePrompt.addEventListener('change', () => {
  roomState.gamePromptFile = els.gamePrompt.value || '';
  scheduleSave();
});

function renderGamePromptOptions() {
  if (!els.gamePrompt) return;
  const selected = roomState.gamePromptFile || '';
  els.gamePrompt.innerHTML = '';
  const defaultOpt = document.createElement('option');
  defaultOpt.value = '';
  defaultOpt.textContent = 'No game selected';
  els.gamePrompt.appendChild(defaultOpt);
  (gamePromptOptions || []).forEach(name => {
    const opt = document.createElement('option');
    opt.value = name;
    opt.textContent = name;
    els.gamePrompt.appendChild(opt);
  });
  els.gamePrompt.value = selected;
}

/* Chat */
els.chatForm.addEventListener('submit', async (e) => {
  e.preventDefault();
  const text = (els.chatInput.value || '').trim();
  if (!text) return;
  els.chatInput.value = '';
  // do not echo locally; PS daemon will round-trip user lines
  const res = await api.send(text);
  if (!res.ok) toast('Send failed');
});

/* Boot */
(async function boot() {
  const env = await api.getEnv();
  if (env.WALLPAPER) {
    els.bg.style.backgroundImage = `url("${env.WALLPAPER}")`;
  } else {
    els.bg.style.backgroundImage = 'none';
  }
  const st = await api.getState();
  roomState = Object.assign(roomState, st || {});
  renderWidgets(roomState.widgets || []);
  applyStand(roomState.stand || {});
  renderGamePromptOptions();

  // load game prompt options after state to set selection
  try {
    const promptNames = await api.listGamePrompts();
    if (Array.isArray(promptNames)) {
      gamePromptOptions = promptNames;
      renderGamePromptOptions();
    }
  } catch (e) {
    console.error('Failed to load game prompts', e);
  }

  // subscriptions
  api.onRoom('room:background', (url) => {
    els.bg.style.backgroundImage = `url("${url}")`;
  });
  api.onRoom('room:state', (state) => {
    roomState = Object.assign(roomState, state || {});
    renderWidgets(roomState.widgets || []);
    applyStand(roomState.stand || {});
    renderGamePromptOptions();
  });

    // NEW: react to stand events emitted by the daemon
    api.onAppend((obj) => {
        if (!obj || !obj.kind) return;

        // Chat bubbles
        if (obj.kind === 'user' || obj.kind === 'assistant') {
            addLine(obj.kind, obj.text || '');
        }

        // react to stand events
        if (obj.kind === 'system' && obj.channel === 'stand') {
            if (obj.event === 'stand.set') {
                const url = (obj.url || toFileUrl(obj.path)) + '?t=' + Date.now(); // cache-bust
                roomState.stand.current = url;
                if (typeof obj.visible === 'boolean') roomState.stand.visible = obj.visible;
                if (typeof obj.scale === 'number') roomState.stand.scale = obj.scale;
                if (typeof obj.mirror === 'boolean') roomState.stand.mirror = obj.mirror;
                applyStand(roomState.stand);
                return;
            }
        }

        // (optional) if you decide to emit tools instead of system events:
        if (obj.kind === 'tool' && obj.name === 'stand.set') {
            const a = obj.args || {};
            const url = (a.url || toFileUrl(a.path) || roomState.stand.current || '') + '?t=' + Date.now();
            roomState.stand.current = url;
            if (a.outfit && a.name) {
                // if you ever pass rel path instead of absolute url
                // roomState.stand.current = toFileUrl(`D:\\Echo\\stand\\${a.outfit}\\${a.name}`) + '?t=' + Date.now();
            }
            applyStand(roomState.stand);
        }
    });
})();
