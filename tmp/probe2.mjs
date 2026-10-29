
const list=await (await fetch('http://127.0.0.1:9333/json/list')).json();
const t=list.find(x=>x.type==='page'&&x.url.includes('sms-verify-login'));
if(!t){console.log('no page');process.exit(0);}
const ws=new WebSocket(t.webSocketDebuggerUrl);
let i=0;const pd=new Map();
ws.onmessage=e=>{const m=JSON.parse(e.data);if(m.id&&pd.has(m.id)){pd.get(m.id)(m);pd.delete(m.id);}};
await new Promise(r=>ws.onopen=r);
const sd=(mm,p={})=>new Promise(res=>{const n=++i;pd.set(n,res);ws.send(JSON.stringify({id:n,method:mm,params:p}));});
const ev=async(x)=>{const r=await sd('Runtime.evaluate',{expression:x,returnByValue:true,awaitPromise:true});return r.result&&r.result.result?r.result.result.value:JSON.stringify(r.error||'nil');};
console.log('PERF:',await ev("JSON.stringify(performance.getEntriesByType('resource').filter(e=>/verify|login|sms|cap_/i.test(e.name)).map(e=>e.name.slice(0,120)))"));
console.log('TEXT:',await ev("(document.body.innerText||'').replace(/\\s+/g,' ').slice(0,300)"));
console.log('HTMLHINT:',await ev("(document.body.innerHTML.match(/短信|手机|验证码/g)||[]).slice(0,10).join(',')"));
ws.close();
