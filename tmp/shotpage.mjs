
const fs=await import('node:fs');
const out=process.argv[2]||'C:/Users/Administrator/penguis/qqclient/tmp/shot.png';
const list=await (await fetch('http://127.0.0.1:9333/json/list')).json();
const page=list.find(x=>x.type==='page'&&x.url!=='about:blank');
const ws=new WebSocket(page.webSocketDebuggerUrl);
let i=0;const pd=new Map();
ws.onmessage=e=>{const m=JSON.parse(e.data);if(m.id&&pd.has(m.id)){pd.get(m.id)(m);pd.delete(m.id);}};
await new Promise(r=>ws.onopen=r);
const sd=(mm,p={})=>new Promise(res=>{const n=++i;pd.set(n,res);ws.send(JSON.stringify({id:n,method:mm,params:p}));});
await sd('Page.enable');
const r=await sd('Page.captureScreenshot',{format:'png'});
fs.writeFileSync(out,Buffer.from(r.result.data,'base64'));
console.log('SHOT',out);
ws.close();
