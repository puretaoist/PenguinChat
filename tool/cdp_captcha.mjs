// cdp_captcha.mjs — 通过 Chrome DevTools Protocol 在 WebView 里解腾讯滑块/点选验证码
//
// 前置（真机）：
//   1) 探针 Activity 已调 WebView.setWebContentsDebuggingEnabled(true)（TimCoreProbeActivity.submitWithUrl）
//   2) adb forward --remove-all; adb forward tcp:9222 localabstract:webview_devtools_remote_$(adb shell pidof com.example.qqclient.test)
//
// 用法（node 22 直跑，无第三方依赖）：
//   node tool/cdp_captcha.mjs get            # 打印题干/图片URL，并把合成图存成 tmp_capimg.bin
//   node tool/cdp_captcha.mjs fix            # 图加载失败（.tc-cover.tc-fail 吃点击）时把 fetch 到的图注入回去
//   node tool/cdp_captcha.mjs click 0.176 0.3125   # 按归一化坐标点击 tile，再自动点"确定"
//   node tool/cdp_captcha.mjs text           # 打印页面文字（题干只在 document.body.textContent 里）
//
// 坑：
//   - 验证码在跨域 iframe https://captcha.gtimg.com，是独立 executionContext，必须按 origin 挑 ctx。
//   - #tc-instruction-text 经常不存在，题干要从 body.textContent 读。
//   - 图片是一张 672x480 的 2x3 合成图，作为 .tc-bg-img 的 background-image。
//   - 模板字符串里嵌 JS 会吞反斜杠，统一用 String.fromCharCode(34) 代表引号。

const mode = process.argv[2] || 'get';
const list = await (await fetch('http://127.0.0.1:9222/json/list')).json();
const page = list.find(x => x.type === 'page');
if (!page) { console.log('NO_PAGE'); process.exit(1); }
const ws = new WebSocket(page.webSocketDebuggerUrl);
let id = 0; const pend = new Map(); const ctxs = [];
ws.onmessage = (ev) => {
  const m = JSON.parse(ev.data);
  if (m.id && pend.has(m.id)) { pend.get(m.id)(m); pend.delete(m.id); }
  if (m.method === 'Runtime.executionContextCreated') ctxs.push(m.params.context);
};
await new Promise(r => ws.onopen = r);
const send = (method, params = {}) => new Promise(res => { const i = ++id; pend.set(i, res); ws.send(JSON.stringify({ id: i, method, params })); });
await send('Runtime.enable');
await new Promise(r => setTimeout(r, 400));
const cap = ctxs.find(c => c.origin && c.origin.includes('captcha'));
if (!cap) { console.log('NO_CAPTCHA_CTX', ctxs.map(c => c.origin).join(',')); process.exit(1); }
const ev = async (expr) => {
  const r = await send('Runtime.evaluate', { expression: expr, contextId: cap.id, returnByValue: true, awaitPromise: true });
  return r.result && r.result.result ? r.result.result.value : null;
};
const E_INFO = "(function(){var q=String.fromCharCode(34);var t=(document.body.textContent||'').slice(0,80);var a=document.querySelector('.tc-imgarea');var r=a?a.getBoundingClientRect():null;var d=document.querySelector('.tc-bg-img');var bg=d?getComputedStyle(d).backgroundImage:'';var parts=bg.split(q);var u=parts.length>1?parts[1]:null;var ins=document.querySelector('#tc-instruction-text');return JSON.stringify({txt:t,ins:ins?ins.textContent:null,area:r?[Math.round(r.x),Math.round(r.y),Math.round(r.width),Math.round(r.height)]:null,url:u});})()";
const E_AREA = "(function(){var a=document.querySelector('.tc-imgarea');if(!a)return 'null';var r=a.getBoundingClientRect();return JSON.stringify([r.x,r.y,r.width,r.height]);})()";
const E_BTN = "(function(){var b=document.querySelector('.tc-verify-button');if(!b)return 'null';var r=b.getBoundingClientRect();return JSON.stringify([r.x+r.width/2,r.y+r.height/2]);})()";
const clickAt = async (x, y) => {
  for (const type of ['mousePressed', 'mouseReleased']) {
    await send('Input.dispatchMouseEvent', { type, x, y, button: 'left', clickCount: 1 });
  }
};
if (mode === 'get') {
  const info = await ev(E_INFO);
  console.log('INFO', info);
  const u = JSON.parse(info).url;
  if (u) {
    await ev("window.__i='p';fetch('" + u + "').then(r=>r.blob()).then(b=>{var f=new FileReader();f.onload=function(){window.__i=f.result};f.readAsDataURL(b)}).catch(e=>window.__i='ERR')");
    await new Promise(r => setTimeout(r, 2500));
    const d = await ev('window.__i');
    if (d && d.startsWith('data:image')) {
      const fs = await import('node:fs');
      fs.writeFileSync('C:/Users/Administrator/penguis/qqclient/tmp_capimg.bin', Buffer.from(d.split(',')[1], 'base64'));
      console.log('IMG_SAVED');
    } else console.log('IMG_FAIL', String(d).slice(0, 60));
  }
} else if (mode === 'click') {
  const nx = parseFloat(process.argv[3]), ny = parseFloat(process.argv[4]);
  const a = JSON.parse(await ev(E_AREA));
  const x = a[0] + nx * a[2], y = a[1] + ny * a[3];
  await clickAt(x, y);
  console.log('CLICKED', Math.round(x), Math.round(y));
  await new Promise(r => setTimeout(r, 1200));
  const b = await ev(E_BTN);
  if (b !== 'null') {
    const p = JSON.parse(b);
    await clickAt(p[0], p[1]);
    console.log('CONFIRM_CLICKED', Math.round(p[0]), Math.round(p[1]));
  } else console.log('NO_CONFIRM_BTN');
} else if (mode === 'fix') {
  const info = JSON.parse(await ev(E_INFO));
  const u = info.url;
  await ev("window.__i='p';fetch('" + u + "').then(r=>r.blob()).then(b=>{var f=new FileReader();f.onload=function(){window.__i=f.result};f.readAsDataURL(b)}).catch(e=>window.__i='ERR')");
  await new Promise(r => setTimeout(r, 2000));
  const res = await ev("(function(){var q=String.fromCharCode(34);var d=document.querySelector('.tc-bg-img');if(!d)return 'no-tile';if(!window.__i||window.__i.length<100)return 'no-data';d.style.backgroundImage='url('+q+window.__i+q+')';d.style.backgroundSize='100% 100%';var n=0;document.querySelectorAll('.tc-cover').forEach(function(c){if(c.className.indexOf('tc-fail')>=0){c.style.display='none';n++;}});document.querySelectorAll('.tc-fail-text').forEach(function(c){c.style.display='none'});return 'patched covers='+n;})()");
  console.log('FIX', res);
} else if (mode === 'text') {
  console.log('TEXT', await ev("(document.body.textContent||'').slice(0,120)"));
}
ws.close();
