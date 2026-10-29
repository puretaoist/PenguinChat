// slider_pc.mjs — 在 PC 上用 Edge(headless) 通过 CDP 处理腾讯滑块/点选验证码
//
// 与 tool/cdp_captcha.mjs 的区别：那份面向真机 WebView（adb forward 9222），
// 这份面向本机 Edge 的 --remote-debugging-port，用于**没有真机时**验证
// 「验证码能不能在 PC 上解开、票能不能拿到、同一条 Dart 连接能不能提交」。
//
// 用法（node 直跑，无第三方依赖）：
//   node tool/slider_pc.mjs open <verifyUrl>   # 起 Edge(headless) 并打开验证页
//   node tool/slider_pc.mjs text               # 页面文字（题干在 body.textContent）
//   node tool/slider_pc.mjs get                # 题干/图片URL + 存图 tmp_capimg.bin
//   node tool/slider_pc.mjs fix                # 图加载失败时把图注入回去、去掉 tc-fail 遮挡
//   node tool/slider_pc.mjs click 0.176 0.3125 # 归一化坐标点 tile，再点“确定”
//   node tool/slider_pc.mjs net                # 已捕获的 postMessage / 含 ticket 的请求
//   node tool/slider_pc.mjs ticket             # 提取票 -> tmp_tk.txt / tmp_randstr.txt
//   node tool/slider_pc.mjs close              # 关掉 Edge
//
// 坑（与真机版相同）：验证码在跨域 iframe https://captcha.gtimg.com，独立
// executionContext，必须按 origin 挑 ctx；题干只在 body.textContent 里；
// 图是 672x480 的 2x3 合成图；模板里嵌 JS 会吞反斜杠，统一用 fromCharCode(34)。

const mode = process.argv[2] || 'text';
const fs = await import('node:fs');
const { spawn } = await import('node:child_process');
const PORT = Number(process.env.SLIDER_PC_PORT || 9333);
const EDGE = process.env.SLIDER_PC_EDGE ||
  'C:/Program Files (x86)/Microsoft/EdgeCore/156.0.4314.50/msedge.exe';
const PROFILE = 'C:/Users/Administrator/AppData/Local/Temp/edge-prof-pc';
const BASE = 'http://127.0.0.1:' + PORT;

const sleep = (ms) => new Promise(r => setTimeout(r, ms));

async function cdpVersion() {
  try { const r = await fetch(BASE + '/json/version'); return r.ok ? await r.json() : null; } catch { return null; }
}

if (mode === 'open') {
  const url = process.argv[3];
  if (!url) { console.log('usage: open <verifyUrl>'); process.exit(1); }
  fs.mkdirSync(PROFILE, { recursive: true });
  if (!(await cdpVersion())) {
    const p = spawn(EDGE, [
      '--headless=new', '--remote-debugging-port=' + PORT,
      '--user-data-dir=' + PROFILE, '--no-first-run', '--no-default-browser-check',
      '--disable-gpu', '--window-size=1000,900',
      // 伪装成手机，避免验证页按桌面 UA 走不同分支
      '--user-agent=Mozilla/5.0 (Linux; Android 13; HA2CSJR5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36',
      'about:blank',
    ], { detached: true, stdio: 'ignore' });
    p.unref();
    for (let i = 0; i < 30 && !(await cdpVersion()); i++) await sleep(300);
  }
  const v = await cdpVersion();
  if (!v) { console.log('EDGE_FAILED'); process.exit(1); }
  console.log('EDGE', v['Browser']);
  await fetch(BASE + '/json/new?about:blank', { method: 'PUT' }).catch(() => {});
  const page = (await (await fetch(BASE + '/json/list')).json()).filter(x => x.type === 'page').pop();
  const w = new WebSocket(page.webSocketDebuggerUrl);
  let i = 0; const pd = new Map();
  w.onmessage = (e) => { const m = JSON.parse(e.data); if (m.id && pd.has(m.id)) { pd.get(m.id)(m); pd.delete(m.id); } };
  await new Promise(r => w.onopen = r);
  const sd = (method, params = {}) => new Promise(res => { const n = ++i; pd.set(n, res); w.send(JSON.stringify({ id: n, method, params })); });
  await sd('Page.enable');
  await sd('Page.navigate', { url });
  await sleep(2500);
  const r = await sd('Runtime.evaluate', { expression: 'location.href', returnByValue: true });
  console.log('TARGET', r.result && r.result.result ? r.result.result.value : '?');
  w.close();
  process.exit(0);
}

if (mode === 'close') {
  const t = await (await fetch(BASE + '/json/list')).json().catch(() => []);
  for (const x of t) await fetch(BASE + '/json/close/' + x.id).catch(() => {});
  console.log('CLOSED', t.length);
  process.exit(0);
}

// ---------- attach ----------
const list = await (await fetch(BASE + '/json/list')).json();
// 验证码本体在跨域 iframe（OOPIF）里，是独立 target；优先连它，
// 这样 .tc-imgarea 的坐标就是它自己的视口坐标，点击精确。
const capTarget = list.find(x => x.type === 'iframe' && /captcha/.test(String(x.url)));
const pages = list.filter(x => x.type === 'page');
const page = capTarget || pages.find(p => p.url && p.url !== 'about:blank') || pages[pages.length - 1];
if (!page) { console.log('NO_PAGE'); process.exit(1); }
const ws = new WebSocket(page.webSocketDebuggerUrl);
let id = 0; const pend = new Map(); const ctxs = [];
const msgs = []; const reqs = [];
ws.onmessage = (ev) => {
  const m = JSON.parse(ev.data);
  if (m.id && pend.has(m.id)) { pend.get(m.id)(m); pend.delete(m.id); }
  if (m.method === 'Runtime.executionContextCreated') ctxs.push(m.params.context);
  if (m.method === 'Runtime.bindingCalled') msgs.push(String(m.params.payload));
  if (m.method === 'Runtime.consoleAPICalled') {
    const s = (m.params.args || []).map(a => a.value !== undefined ? a.value : a.description).join(' ');
    if (s) msgs.push('console: ' + s.slice(0, 400));
  }
  if (m.method === 'Network.requestWillBeSent') {
    const u = m.params.request.url;
    if (/ticket=|randstr=|cap_union|verify/i.test(u)) reqs.push(u.slice(0, 400));
  }
};
await new Promise(r => ws.onopen = r);
const send = (method, params = {}) => new Promise(res => { const i = ++id; pend.set(i, res); ws.send(JSON.stringify({ id: i, method, params })); });
await send('Runtime.enable');
await send('Network.enable');
try { await send('Runtime.addBinding', { name: '__pcMsg' }); } catch {}
// 之后新开的文档都装一个 message 监听（验证码把 ticket postMessage 给父页）
try {
  await send('Page.enable');
  await send('Page.addScriptToEvaluateOnNewDocument', {
    source: "(function(){window.addEventListener('message',function(e){try{window.__pcMsg(JSON.stringify(e.data))}catch(_){}});})();",
  });
} catch {}
await sleep(600);

const cap = ctxs.find(c => c.origin && c.origin.includes('captcha'));
const evIn = async (expr, ctxId) => {
  const r = await send('Runtime.evaluate', { expression: expr, contextId: ctxId, returnByValue: true, awaitPromise: true });
  return r.result && r.result.result ? r.result.result.value : null;
};
// 直接连到 iframe target 时不需要 contextId（那里只有一个主 frame）；
// 只有从 page target 里找 iframe 的 executionContext 才需要。
const ev = async (expr) => evIn(expr, undefined);
const evTop = async (expr) => evIn(expr, undefined);

const E_INFO = "(function(){var q=String.fromCharCode(34);var t=(document.body.textContent||'').slice(0,90);var a=document.querySelector('.tc-imgarea');var r=a?a.getBoundingClientRect():null;var d=document.querySelector('.tc-bg-img');var bg=d?getComputedStyle(d).backgroundImage:'';var parts=bg.split(q);var u=parts.length>1?parts[1]:null;return JSON.stringify({txt:t,area:r?[Math.round(r.x),Math.round(r.y),Math.round(r.width),Math.round(r.height)]:null,url:u});})()";
const E_AREA = "(function(){var a=document.querySelector('.tc-imgarea');if(!a)return 'null';var r=a.getBoundingClientRect();return JSON.stringify([r.x,r.y,r.width,r.height]);})()";
const E_BTN = "(function(){var b=document.querySelector('.tc-verify-button');if(!b)return 'null';var r=b.getBoundingClientRect();return JSON.stringify([r.x+r.width/2,r.y+r.height/2]);})()";
const clickAt = async (x, y) => {
  for (const type of ['mousePressed', 'mouseReleased'])
    await send('Input.dispatchMouseEvent', { type, x, y, button: 'left', clickCount: 1 });
};

if (mode === 'text') {
  console.log('URL', page.url);
  console.log('TOP', await evTop("(document.body.textContent||'').slice(0,150)"));
  console.log('CTX', ctxs.map(c => c.origin).join(' | '));
  if (cap) console.log('CAP', await ev("(document.body.textContent||'').slice(0,150)"));
} else if (mode === 'get') {
  const info = await ev(E_INFO);
  console.log('INFO', info);
  const u = info && JSON.parse(info).url;
  if (u) {
    await ev("window.__i='p';fetch('" + u + "').then(r=>r.blob()).then(b=>{var f=new FileReader();f.onload=function(){window.__i=f.result};f.readAsDataURL(b)}).catch(e=>window.__i='ERR')");
    await sleep(2500);
    const d = await ev('window.__i');
    if (d && String(d).startsWith('data:image')) {
      fs.writeFileSync('C:/Users/Administrator/penguis/qqclient/tmp_capimg.bin', Buffer.from(String(d).split(',')[1], 'base64'));
      console.log('IMG_SAVED');
    } else console.log('IMG_FAIL', String(d).slice(0, 60));
  } else console.log('NO_IMG_URL');
} else if (mode === 'fix') {
  const info = JSON.parse(await ev(E_INFO));
  if (!info.url) { console.log('NO_IMG_URL'); process.exit(0); }
  await ev("window.__i='p';fetch('" + info.url + "').then(r=>r.blob()).then(b=>{var f=new FileReader();f.onload=function(){window.__i=f.result};f.readAsDataURL(b)}).catch(e=>window.__i='ERR')");
  await sleep(2000);
  const res = await ev("(function(){var q=String.fromCharCode(34);var d=document.querySelector('.tc-bg-img');if(!d)return 'no-tile';if(!window.__i||window.__i.length<100)return 'no-data';d.style.backgroundImage='url('+q+window.__i+q+')';d.style.backgroundSize='100% 100%';var n=0;document.querySelectorAll('.tc-cover').forEach(function(c){if(c.className.indexOf('tc-fail')>=0){c.style.display='none';n++;}});document.querySelectorAll('.tc-fail-text').forEach(function(c){c.style.display='none'});return 'patched covers='+n;})()");
  console.log('FIX', res);
} else if (mode === 'click') {
  const nx = parseFloat(process.argv[3]), ny = parseFloat(process.argv[4]);
  const a = JSON.parse(await ev(E_AREA));
  const x = a[0] + nx * a[2], y = a[1] + ny * a[3];
  await clickAt(x, y);
  console.log('CLICKED', Math.round(x), Math.round(y));
  await sleep(1200);
  const b = await ev(E_BTN);
  if (b !== 'null') { const p = JSON.parse(b); await clickAt(p[0], p[1]); console.log('CONFIRM', Math.round(p[0]), Math.round(p[1])); }
  else console.log('NO_CONFIRM_BTN');
} else if (mode === 'btn') {
  console.log('BTN', await ev(E_BTN));
} else if (mode === 'clickxy') {
  const x = parseFloat(process.argv[3]), y = parseFloat(process.argv[4]);
  await clickAt(x, y);
  console.log('CLICKED', x, y);
} else if (mode === 'shot') {
  const out = process.argv[3] || 'C:/Users/Administrator/penguis/qqclient/tmp/shot.png';
  const r = await send('Page.captureScreenshot', { format: 'png' });
  const d = r.result && r.result.data;
  if (d) { fs.writeFileSync(out, Buffer.from(d, 'base64')); console.log('SHOT', out); }
  else console.log('NO_SHOT', JSON.stringify(r).slice(0, 200));
} else if (mode === 'net') {
  console.log('MSGS', msgs.length); msgs.slice(-8).forEach(m => console.log('  M ' + m.slice(0, 300)));
  console.log('REQS', reqs.length); reqs.slice(-8).forEach(u => console.log('  R ' + u));
} else if (mode === 'ticket') {
  const blob = msgs.join('\n') + '\n' + reqs.join('\n');
  const mT = blob.match(/ticket[\"'=:]+([A-Za-z0-9_\-%\.]{20,})/g) || [];
  const mR = blob.match(/randstr[\"'=:]+([A-Za-z0-9_\-%\.]{4,})/g) || [];
  const last = (arr) => arr.length ? arr[arr.length - 1].replace(/^ticket[\"'=:]+|^randstr[\"'=:]+/, '') : '';
  const t = decodeURIComponent(last(mT)), rnd = decodeURIComponent(last(mR));
  if (!t) { console.log('NO_TICKET'); process.exit(1); }
  fs.writeFileSync('tmp_tk.txt', t); fs.writeFileSync('tmp_randstr.txt', rnd);
  console.log('TICKET len=' + t.length + ' head=' + t.slice(0, 12) + ' randstr=' + rnd);
}
ws.close();
