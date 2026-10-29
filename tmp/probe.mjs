
const list=await (await fetch('http://127.0.0.1:9333/json/list')).json();
async function probe(target,expr){
  const ws=new WebSocket(target.webSocketDebuggerUrl);
  let i=0;const pd=new Map();
  ws.onmessage=e=>{const m=JSON.parse(e.data);if(m.id&&pd.has(m.id)){pd.get(m.id)(m);pd.delete(m.id);}};
  await new Promise(r=>ws.onopen=r);
  const sd=(mm,p={})=>new Promise(res=>{const n=++i;pd.set(n,res);ws.send(JSON.stringify({id:n,method:mm,params:p}));});
  const r=await sd('Runtime.evaluate',{expression:expr,returnByValue:true,awaitPromise:true});
  ws.close();
  return r.result&&r.result.result?r.result.result.value:JSON.stringify(r.error||'nil');
}
const EXPR="(function(){var out=[];for(var k in window){try{var v=window[k];if(typeof v==='string'&&v.length>40&&v.length<600)out.push(k+'='+v.slice(0,50));}catch(e){}}return JSON.stringify({url:location.href,keys:out.slice(0,20)});})()";
for(const t of list.filter(x=>x.type==='page'||x.type==='iframe')){
  console.log('==',t.type,t.url.slice(0,60));
  console.log(await probe(t,EXPR));
}
