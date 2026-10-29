// 常驻 CDP 录制器：抓腾讯点选验证码 verify 响应里的 ticket/randstr
const PORT = process.env.CDP_PORT || '9333';
const OUT  = process.argv[2] || 'tmp/tk.txt';
import fs from 'node:fs';
const seen = new Set();
const attached = new Set();

async function targets(){ try { return await (await fetch('http://127.0.0.1:'+PORT+'/json/list')).json(); } catch(e){ return []; } }

function handle(ws, t){
  let id=0; const pd=new Map(); const reqs=new Map();
  ws.onmessage = async (e)=>{
    const m = JSON.parse(e.data);
    if (m.id && pd.has(m.id)) { pd.get(m.id)(m); pd.delete(m.id); return; }
    if (m.method === 'Network.responseReceived') {
      const r = m.params.response;
      const isVerify = /t\.captcha\.qq\.com\/cap_union_new_verify/.test(r.url);
      if (isVerify) {
        reqs.set(m.params.requestId, r.url);
        console.log('[resp]', r.status, r.url.slice(0,110));
      }
    }
    if (m.method === 'Network.loadingFinished' && reqs.has(m.params.requestId)) {
      const url = reqs.get(m.params.requestId); reqs.delete(m.params.requestId);
      const body = await send('Network.getResponseBody', {requestId: m.params.requestId});
      const txt = body && body.result ? (body.result.body || '') : '';
      if (!txt.trim().startsWith('{')) { console.log('[skip-non-json] len=' + txt.length); return; }
      console.log('[body]', url.slice(0,80), 'len=' + txt.length);
      try {
        const j = JSON.parse(txt);
        const flat = JSON.stringify(j);
        const mt = flat.match(/"ticket"\s*:\s*"([^"]+)"/);
        const mr = flat.match(/"randstr"\s*:\s*"([^"]*)"/);
        if (mt) {
          fs.writeFileSync(OUT, mt[1]);
          fs.writeFileSync(OUT + '.randstr', mr ? mr[1] : '');
          console.log('TICKET len=' + mt[1].length + ' head=' + mt[1].slice(0,40) + ' randstr=' + (mr?mr[1]:''));
        }
      } catch(e) {
        const mt = txt.match(/"ticket"\s*:\s*"([^"]+)"/);
        if (mt) { fs.writeFileSync(OUT, mt[1]); console.log('TICKET(raw) len=' + mt[1].length); }
      }
    }
    if (m.method === 'Runtime.consoleAPICalled') {
      const a = (m.params.args||[]).map(x=>x.value===undefined?x.type:x.value).join(' ');
      if (/ticket|jsbridge|verify/i.test(a)) console.log('[console]', String(a).slice(0,200));
    }
  };
  function send(method, params={}){ return new Promise(res=>{ const n=++id; pd.set(n,res); ws.send(JSON.stringify({id:n,method,params})); }); }
  (async()=>{
    await send('Network.enable');
    await send('Runtime.enable');
    console.log('[attach]', t.type, t.url.slice(0,70));
  })();
}

setInterval(async ()=>{
  const list = await targets();
  for (const t of list) {
    if (!t.webSocketDebuggerUrl) continue;
    if (t.type !== 'page' && t.type !== 'iframe') continue;
    if (attached.has(t.id)) continue;
    attached.add(t.id);
    const ws = new WebSocket(t.webSocketDebuggerUrl);
    ws.onopen = ()=> handle(ws, t);
    ws.onclose = ()=>{ attached.delete(t.id); console.log('[detach]', t.id); };
  }
}, 800);
console.log('recorder up, out=' + OUT);
