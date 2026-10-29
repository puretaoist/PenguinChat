
const fs=await import('node:fs');
const url=fs.readFileSync('C:/Users/Administrator/penguis/qqclient/tmp/verify_url.txt','utf8').trim();
const list=await (await fetch('http://127.0.0.1:9333/json/list')).json();
const page=list.filter(x=>x.type==='page')[0];
const ws=new WebSocket(page.webSocketDebuggerUrl);
let i=0;const pd=new Map();
ws.onmessage=e=>{const m=JSON.parse(e.data);if(m.id&&pd.has(m.id)){pd.get(m.id)(m);pd.delete(m.id);}
 if(m.method==='Page.loadEventFired')console.log('LOAD');
 if(m.method==='Network.loadingFailed')console.log('FAIL',m.params.errorText,(m.params.blockedReason||''));};
await new Promise(r=>ws.onopen=r);
const sd=(m,p={})=>new Promise(res=>{const n=++i;pd.set(n,res);ws.send(JSON.stringify({id:n,method:m,params:p}));});
await sd('Page.enable');await sd('Network.enable');
const r=await sd('Page.navigate',{url});
console.log('NAV',JSON.stringify(r.result||r.error));
await new Promise(r=>setTimeout(r,5000));
const t=await sd('Runtime.evaluate',{expression:'document.location.href+" | "+(document.body?document.body.textContent.slice(0,200):"")',returnByValue:true});
console.log('PAGE',JSON.stringify(t.result&&t.result.result&&t.result.result.value));
ws.close();
