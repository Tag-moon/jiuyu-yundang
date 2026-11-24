/*
 * 一键打包纯静态演示版：node scripts/build-static.mjs
 * 产物 dist-static/ 可直接双击 index.html 打开，也可整体上传到任意静态托管。
 */
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const WEB_DIR = path.join(ROOT, 'web');
const OUT_DIR = path.join(ROOT, 'dist-static');
const DATA_FILE = path.join(ROOT, 'harmony-app/entry/src/main/resources/rawfile/heritages.json');
const IMAGE_DIR = path.join(ROOT, 'harmony-app/entry/src/main/resources/rawfile/images');
const STATIC_API = path.join(ROOT, 'apps/api/static-api.js');
const PORT = 9333;
const MAX_WIDTH = 960;
const JPEG_QUALITY = 0.8;
const CHROME_CANDIDATES = [
  process.env.CHROME_PATH,
  'C:/Program Files/Google/Chrome/Application/chrome.exe',
  'C:/Program Files (x86)/Google/Chrome/Application/chrome.exe',
  'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
  'C:/Program Files/Microsoft/Edge/Application/msedge.exe'
].filter(Boolean);

const kb = (bytes) => `${(bytes / 1024).toFixed(0)}KB`;
const dirSize = (dir) => fs.readdirSync(dir, { withFileTypes: true })
  .reduce((sum, entry) => sum + (entry.isDirectory() ? dirSize(path.join(dir, entry.name)) : fs.statSync(path.join(dir, entry.name)).size), 0);

function connectChrome() {
  const exe = CHROME_CANDIDATES.find((candidate) => fs.existsSync(candidate));
  if (!exe) return null;
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'jiuyu-build-'));
  const child = spawn(exe, [
    '--headless=new', `--remote-debugging-port=${PORT}`, `--user-data-dir=${profile}`,
    '--no-first-run', '--no-default-browser-check', '--disable-gpu', '--allow-file-access-from-files', 'about:blank'
  ], { stdio: 'ignore' });
  return { child, profile };
}

async function openPage() {
  for (let attempt = 0; attempt < 50; attempt += 1) {
    try {
      const list = await (await fetch(`http://127.0.0.1:${PORT}/json/list`)).json();
      const page = list.find((target) => target.type === 'page');
      if (page) return page.webSocketDebuggerUrl;
    } catch (error) { /* Chrome 尚未就绪 */ }
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  throw new Error('无法连接无头 Chrome');
}

async function resizeAll(images) {
  const chrome = connectChrome();
  if (!chrome) {
    console.warn('未找到 Chrome/Edge，图片按原图复制。');
    images.forEach((name) => fs.copyFileSync(path.join(IMAGE_DIR, name), path.join(OUT_DIR, 'images', name)));
    return { resized: 0, bytes: images.reduce((sum, name) => sum + fs.statSync(path.join(IMAGE_DIR, name)).size, 0) };
  }
  let ws;
  try {
    ws = new WebSocket(await openPage());
    await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject; });
    let seq = 0;
    const pending = new Map();
    ws.onmessage = (event) => {
      const message = JSON.parse(event.data);
      if (message.id && pending.has(message.id)) { pending.get(message.id)(message); pending.delete(message.id); }
    };
    const send = (method, params = {}) => new Promise((resolve, reject) => {
      const id = ++seq;
      const timer = setTimeout(() => { pending.delete(id); reject(new Error(`CDP 超时：${method}`)); }, 60000);
      pending.set(id, (message) => { clearTimeout(timer); resolve(message); });
      ws.send(JSON.stringify({ id, method, params }));
    });

    let resized = 0;
    let total = 0;
    for (const name of images) {
      const source = fs.readFileSync(path.join(IMAGE_DIR, name));
      const dataUrl = `data:image/jpeg;base64,${source.toString('base64')}`;
      const reply = await send('Runtime.evaluate', {
        awaitPromise: true,
        expression: `(async () => {
          const img = new Image();
          img.src = ${JSON.stringify(dataUrl)};
          await img.decode();
          const scale = Math.min(1, ${MAX_WIDTH} / img.naturalWidth);
          const canvas = document.createElement('canvas');
          canvas.width = Math.round(img.naturalWidth * scale);
          canvas.height = Math.round(img.naturalHeight * scale);
          canvas.getContext('2d').drawImage(img, 0, 0, canvas.width, canvas.height);
          return canvas.toDataURL('image/jpeg', ${JPEG_QUALITY}).split(',')[1];
        })()`
      });
      const encoded = reply.result?.result?.value;
      if (!encoded) throw new Error(`压图失败：${name} ${JSON.stringify(reply).slice(0, 300)}`);
      const buffer = Buffer.from(encoded, 'base64');
      const useOriginal = buffer.length >= source.length;
      if (useOriginal) fs.writeFileSync(path.join(OUT_DIR, 'images', name), source);
      else { fs.writeFileSync(path.join(OUT_DIR, 'images', name), buffer); resized += 1; }
      total += useOriginal ? source.length : buffer.length;
    }
    return { resized, bytes: total };
  } finally {
    try { ws && ws.close(); } catch (error) { /* 忽略 */ }
    chrome.child.kill();
    await new Promise((resolve) => setTimeout(resolve, 500));
    try { fs.rmSync(chrome.profile, { recursive: true, force: true }); } catch (error) { /* 文件被占用时留给系统清理 */ }
  }
}

async function main() {
  const data = JSON.parse(fs.readFileSync(DATA_FILE, 'utf8'));
  const images = [...new Set(data.map((item) => item.image).filter(Boolean))];
  const missing = images.filter((name) => !fs.existsSync(path.join(IMAGE_DIR, name)));
  if (missing.length) throw new Error(`缺少图片：${missing.join(', ')}`);

  fs.rmSync(OUT_DIR, { recursive: true, force: true });
  fs.cpSync(WEB_DIR, OUT_DIR, {
    recursive: true,
    filter: (src) => !/[\\/]assets[\\/](textures|photos|incoming)([\\/]|$)/.test(src)
  });
  fs.mkdirSync(path.join(OUT_DIR, 'data'), { recursive: true });
  fs.mkdirSync(path.join(OUT_DIR, 'images'), { recursive: true });

  fs.writeFileSync(path.join(OUT_DIR, 'data/heritages.js'), `window.__JIUYU_DATA__ = ${JSON.stringify(data)};\n`);
  fs.copyFileSync(STATIC_API, path.join(OUT_DIR, 'static-api.js'));

  const htmlFile = path.join(OUT_DIR, 'index.html');
  const html = fs.readFileSync(htmlFile, 'utf8');
  const marker = '<script src="hero.js"></script>';
  if (!html.includes(marker)) throw new Error('index.html 中未找到 hero.js 引用，无法接入静态接口层');
  fs.writeFileSync(htmlFile, html.replace(marker, '<script src="data/heritages.js"></script>\n  <script src="static-api.js"></script>\n  ' + marker));

  console.log(`档案 ${data.length} 条已内置，开始压缩 ${images.length} 张图片…`);
  const result = await resizeAll(images);
  console.log(`图片完成：压缩 ${result.resized} 张，合计 ${kb(result.bytes)}。`);
  console.log(`产物：${OUT_DIR}（总计 ${(dirSize(OUT_DIR) / 1024 / 1024).toFixed(1)}MB）`);
}

main().then(() => process.exit(0)).catch((error) => {
  console.error('[打包失败]', error instanceof Error ? error.message : error);
  process.exit(1);
});
