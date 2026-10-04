// Optional local browser automation bridge for NOVA.
// Uses only Node's built-in HTTP/WebSocket APIs; no npm package is required.
const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawn } = require('child_process');

const query = process.argv.slice(2).join(' ').trim();
const port = 9222;

function wait(ms) { return new Promise(resolve => setTimeout(resolve, ms)); }
async function getJson(url) {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return response.json();
}
async function waitFor(fn, timeoutMs = 15000, intervalMs = 400) {
  const until = Date.now() + timeoutMs;
  while (Date.now() < until) {
    try { const value = await fn(); if (value) return value; } catch (_) {}
    await wait(intervalMs);
  }
  return null;
}

function findBrowser() {
  const configured = process.env.NOVA_BROWSER_PATH;
  const candidates = [
    configured,
    'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
    'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
    'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
    'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe'
  ].filter(Boolean);
  return candidates.find(candidate => fs.existsSync(candidate));
}

async function ensureBrowser(url) {
  try { await getJson(`http://127.0.0.1:${port}/json/version`); return; } catch (_) {}
  const browser = findBrowser();
  if (!browser) throw new Error('找不到 Chrome 或 Edge。');
  const profile = path.join(process.env.LOCALAPPDATA || os.tmpdir(), 'NOVA', 'BrowserProfile');
  fs.mkdirSync(profile, { recursive: true });
  const child = spawn(browser, [
    `--remote-debugging-port=${port}`,
    `--user-data-dir=${profile}`,
    '--no-first-run',
    '--no-default-browser-check',
    '--new-window',
    url
  ], { detached: true, stdio: 'ignore', windowsHide: true });
  child.unref();
  await waitFor(async () => { try { return await getJson(`http://127.0.0.1:${port}/json/version`); } catch (_) { return null; } }, 15000);
}

function createCdpClient(wsUrl) {
  const ws = new WebSocket(wsUrl);
  const pending = new Map();
  let nextId = 1;
  ws.addEventListener('message', event => {
    const message = JSON.parse(event.data);
    if (message.id && pending.has(message.id)) {
      const { resolve, reject } = pending.get(message.id);
      pending.delete(message.id);
      if (message.error) reject(new Error(message.error.message)); else resolve(message.result);
    }
  });
  const open = new Promise((resolve, reject) => {
    ws.addEventListener('open', resolve, { once: true });
    ws.addEventListener('error', reject, { once: true });
  });
  return {
    async send(method, params = {}) {
      await open;
      const id = nextId++;
      return new Promise((resolve, reject) => {
        pending.set(id, { resolve, reject });
        ws.send(JSON.stringify({ id, method, params }));
      });
    },
    close() { try { ws.close(); } catch (_) {} }
  };
}

async function evaluate(cdp, expression) {
  const result = await cdp.send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
  return result && result.result ? result.result.value : null;
}

async function main() {
  if (!query) throw new Error('缺少 YouTube 搜尋詞。');
  const encoded = encodeURIComponent(query);
  const searchUrl = `https://www.youtube.com/results?search_query=${encoded}`;
  await ensureBrowser(searchUrl);
  await wait(1800);
  const target = await waitFor(async () => {
    const pages = await getJson(`http://127.0.0.1:${port}/json/list`);
    return pages.find(page => page.type === 'page' && page.webSocketDebuggerUrl);
  });
  if (!target) throw new Error('瀏覽器 DevTools 連線未就緒。');
  const cdp = createCdpClient(target.webSocketDebuggerUrl);
  try {
    await cdp.send('Page.enable');
    await cdp.send('Page.navigate', { url: searchUrl });
    const videoUrl = await waitFor(() => evaluate(cdp, `(() => {
      const links = [...document.querySelectorAll('a[href*="/watch?v="]')];
      const link = links.find(item => item.href && !item.href.includes('shorts'));
      return link ? link.href : null;
    })()`), 20000, 700);
    if (!videoUrl) throw new Error('找不到 YouTube 搜尋結果，可能需要先處理 cookie 或登入提示。');
    await cdp.send('Page.navigate', { url: videoUrl });
    await wait(5000);
    const rect = await waitFor(() => evaluate(cdp, `(() => {
      const button = document.querySelector('.ytp-play-button');
      if (!button) return null;
      const r = button.getBoundingClientRect();
      return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
    })()`), 12000, 500);
    if (rect) {
      await cdp.send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: rect.x, y: rect.y });
      await wait(350);
      await cdp.send('Input.dispatchMouseEvent', { type: 'mousePressed', x: rect.x, y: rect.y, button: 'left', clickCount: 1 });
      await wait(180);
      await cdp.send('Input.dispatchMouseEvent', { type: 'mouseReleased', x: rect.x, y: rect.y, button: 'left', clickCount: 1 });
      await wait(1200);
    }
    const paused = await evaluate(cdp, 'document.querySelector("video") ? document.querySelector("video").paused : true');
    process.stdout.write(JSON.stringify({ ok: true, videoUrl, clicked: !!rect, playing: paused === false }));
  } finally { cdp.close(); }
}

main().catch(error => {
  process.stdout.write(JSON.stringify({ ok: false, error: error.message }));
  process.exitCode = 1;
});
