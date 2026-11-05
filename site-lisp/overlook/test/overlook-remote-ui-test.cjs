const fs = require('fs');
const vm = require('vm');
const assert = require('assert/strict');
class Element {
  constructor() { this.value=''; this.style={}; this.children=[]; this.events={}; this.scrollHeight=44; }
  addEventListener(name, fn) { this.events[name]=fn; }
  dispatchEvent(e) { this.events[e.type]?.({...e,target:this}); }
  replaceChildren(...children) { this.children=children; }
  append(...children) { this.children.push(...children); }
  getBoundingClientRect() { return {height: this.height ?? 100}; }
  focus() { this.focused=true; }
  closest() { return null; }
  get classList() { return {add: name => { this.className = (this.className || '') + ' ' + name; }}; }
}
const elements = new Map();
const docEvents = {};
const context = vm.createContext({
  document: { documentElement: {scrollHeight:2000,style:{setProperty(){}}}, body: {scrollHeight:2000, style:{}, classList:{toggle(){}}}, getElementById: id => { if(!elements.has(id)) elements.set(id,new Element()); return elements.get(id); }, createElement: () => new Element(), addEventListener: (name,fn) => docEvents[name]=fn },
  location: {hash:'#test',search:'?agent=original',pathname:'/overlook/'},
  localStorage: {getItem:(key)=>key==='overlook-token'?'test':null, setItem(){}},
  DOMPurify: {addHook(){}}, window: {addEventListener(){}}, URLSearchParams, AbortController, Event: class {constructor(type) {this.type=type;}},
  performance: {now:()=>2000}, innerHeight:800, scrollY:0,
  crypto: require("crypto").webcrypto, Uint8Array, clearTimeout(){},setTimeout(){},setInterval(){},confirm:()=>true,
});
let script=fs.readFileSync(require('path').join(__dirname, '..', 'overlook-remote.html'),'utf8').match(/<script>\s*([\s\S]*?)<\/script>/)[1];
script=script.replace(/\nshow\(\);\nsetInterval\(refresh, 2500\);\s*$/,'');
context.scrollTo = (x,y) => {context.lastScroll = [x,y];};
vm.runInContext(script,context);
vm.runInContext('composeId = "original";',context);
(async()=>{
  vm.runInContext('agentControls = {steer:true, actions:["fork","reload","restart"], slash:[{name:"compact",description:"Compact context"},{name:"help",description:"Help"}]}',context);
  elements.get('text').value='/';
  vm.runInContext('renderSlashCommands()',context);
  assert.equal(elements.get('slash-commands').children.length,3);
  elements.get('text').value='/co';
  vm.runInContext('renderSlashCommands()',context);
  assert.equal(elements.get('slash-commands').children.length,2);
  elements.get('slash-commands').children[1].onclick();
  assert.equal(elements.get('text').value,'/compact ');
  assert.equal(elements.get('slash-commands').children.length,0);
  vm.runInContext('agentControls.slash.push({name:"$find-skills",description:"Find skills"})',context);
  elements.get('text').value='/find';
  vm.runInContext('renderSlashCommands()',context);
  const skillRows = elements.get('slash-commands').children;
  assert.equal(skillRows.length,2);
  assert.equal(skillRows[0].textContent,'Skills');
  assert.equal(skillRows[1].children[0].textContent,'find-skills');
  skillRows[1].onclick();
  assert.equal(elements.get('text').value,'/$find-skills ');
  const requests=[];
  context.fetch=async (url,opts)=>{requests.push(JSON.parse(opts.body));return {ok:true,json:async()=>({ok:true,agent:'original'})};};
  elements.get('text').value='change direction';
  await vm.runInContext('sessionAction("steer", $("steer"))',context);
  assert.equal(requests[0].action,'steer');
  assert.equal(requests[0].text,'change direction');
  assert.equal(elements.get('text').value,'');
  elements.get('text').value='keep draft';
  context.confirm=()=>false;
  context.fetch=async()=>({ok:true,json:async()=>({confirm:'Proceed?'})});
  await vm.runInContext('sessionAction("steer", $("steer"))',context);
  assert.equal(elements.get('text').value,'keep draft');
  context.confirm=()=>true;
  let n=0;
  context.fetch=async(url,opts)=>{const b=JSON.parse(opts.body);n++; if(n===1)return{ok:true,json:async()=>({confirm:'Restart?'})};assert.deepEqual(b.confirmations,['Restart?']);return{ok:true,json:async()=>({ok:true,agent:'forked'})};};
  vm.runInContext('open = (id) => { globalThis.opened = id; }',context);
  await vm.runInContext('sessionAction("fork", $("session-menu"))',context);
  assert.equal(context.opened,'forked');
  assert.equal(n,2);
  const reloads=[];
  context.fetch=async(url,opts)=>{reloads.push(JSON.parse(opts.body).requestId);return{ok:true,json:async()=>({ok:true,agent:'original'})};};
  await vm.runInContext('sessionAction("reload", $("session-menu"))',context);
  await vm.runInContext('sessionAction("reload", $("session-menu"))',context);
  assert.notEqual(reloads[0],reloads[1]);
  let finish;
  context.fetch = async () => new Promise(resolve => { finish = resolve; });
  elements.get('text').value = 'first';
  elements.get('text').dispatchEvent(new context.Event('input'));
  const sending = elements.get('send').onclick();
  elements.get('text').value = 'new typing';
  elements.get('text').dispatchEvent(new context.Event('input'));
  finish({ok:true,json:async()=>({queued:false})});
  await sending;
  assert.equal(elements.get('text').value, 'new typing');
  elements.get('text').value = 'A draft';
  vm.runInContext('saveCompose(); composeId = "other"; syncCompose()', context);
  assert.equal(elements.get('text').value, '');
  elements.get('text').value = 'B draft';
  vm.runInContext('saveCompose(); composeId = "original"; syncCompose()', context);
  assert.equal(elements.get('text').value, 'A draft');
  const ids = [];
  context.fetch = async (url, opts) => { ids.push(JSON.parse(opts.body).requestId); throw new TypeError('offline'); };
  await elements.get('send').onclick();
  await elements.get('send').onclick();
  assert.equal(ids[0], ids[1]);
  assert.equal(elements.get('text').value, 'A draft');
  context.URL = {createObjectURL: () => 'blob:test', revokeObjectURL() {}};
  vm.runInContext('prepare = async file => file; base64 = async () => "data";', context);
  let uploaded;
  context.fetch = async (url, opts) => {
    uploaded = JSON.parse(opts.body);
    return new Promise(resolve => { finish = resolve; });
  };
  const attaching = vm.runInContext('attach({type:"image/png"})', context);
  await new Promise(resolve => setImmediate(resolve));
  vm.runInContext('saveCompose(); composeId = "other"; syncCompose()', context);
  assert.equal(elements.get('text').value, 'B draft');
  finish({ok:true,json:async()=>({text:'@image'})});
  await attaching;
  assert.equal(uploaded.id, 'original');
  assert.equal(elements.get('text').value, 'B draft');
  vm.runInContext('saveCompose(); composeId = "original"; syncCompose()', context);
  assert.equal(elements.get('text').value, 'A draft @image ');
  vm.runInContext('connected()', context);
  assert.equal(elements.get('connection').hidden, true);
  assert.match(elements.get('conn').title, /Last synced/);
  vm.runInContext('connectionFailure({status:401})', context);
  assert.equal(vm.runInContext('connectionBlocked', context), true);
  assert.match(elements.get('connection-message').textContent, /Credential expired/);
  vm.runInContext('connectionFailure({status:404, code:"agent_missing"})', context);
  assert.equal(elements.get('return-dashboard').hidden, false);
  vm.runInContext('connectionFailure(new TypeError("offline"))', context);
  assert.equal(vm.runInContext('connectionBlocked', context), false);
  assert.match(elements.get('connection-message').textContent, /Reconnecting/);
  let stopBody;
  context.fetch = async (url, opts) => {
    stopBody = JSON.parse(opts.body);
    return {ok:true,json:async()=>({ok:true,agent:'original'})};
  };
  context.opened = null;
  await vm.runInContext('sessionAction("stop", $("session-menu"))', context);
  assert.equal(stopBody.action, 'stop');
  assert.equal(context.opened, null);
  assert.equal(elements.get('text').value, 'A draft @image ');
  let attempts = 0;
  context.fetch = async () => {
    attempts++;
    return {ok:false,status:401,json:async()=>({error:'expired'})};
  };
  await vm.runInContext('poll({url: () => "events", news() {}})', context);
  assert.equal(attempts, 1);
  assert.equal(vm.runInContext('connectionBlocked', context), true);
  context.fetch = async () => ({ok:false,status:404,json:async()=>({error:'gone',code:'agent_missing'})});
  await vm.runInContext('poll({url: () => "events", news() {}})', context);
  assert.equal(elements.get('return-dashboard').hidden, false);
  vm.runInContext('renderLive({queueError:{}, choices:[], queued:[], status:"idle"})', context);
  assert.equal(elements.get('d-live').children.length, 0);
  vm.runInContext('renderLive({queueError:null, choices:[], queued:[], status:"idle"})', context);
  assert.equal(elements.get('d-live').children.length, 0);
  vm.runInContext('renderLive({queueError:"Submission failed", choices:[], queued:[], status:"idle"})', context);
  assert.equal(elements.get('d-live').children.length, 1);
  assert.equal(elements.get('d-live').children[0].textContent, 'Not sent: Submission failed');
  const pieces = code => vm.runInContext(code, context).children.map(node => [node.textContent, node.className || '', node.style.flex]);
  assert.deepEqual(pieces('meterPiece([{text:"a ━━ ",styles:[]}])'),
    [['a ','',undefined],['━━',' meter','2 1 0'],[' ','',undefined]]);
  assert.deepEqual(pieces('metricPiece([{text:"used  10%  ",styles:[]}])'),
    [['used','',undefined],['  ',' metric-gap',undefined],['10%','',undefined],['  ','','none']]);
  elements.get('text').scrollHeight = 0;
  vm.runInContext('syncCompose()', context);
  assert.equal(elements.get('text').style.height, '44px');
  elements.get('text').scrollHeight = 500;
  vm.runInContext('resizeCompose()', context);
  assert.equal(elements.get('text').style.overflowY, 'auto');
  elements.get('text').scrollHeight = 44;
  vm.runInContext('resizeCompose()', context);
  assert.equal(elements.get('text').style.overflowY, 'hidden');
  const startup = [];
  context.fetch = async url => {
    startup.push(url);
    return {ok:true,json:async()=>({known:'first',sections:[]})};
  };
  vm.runInContext('listen = async () => { globalThis.streamStarted = true; stopPolling(); };', context);
  await vm.runInContext('poll({known:"", url:()=>"dashboard?known=", stream:()=>"dashboard/stream", news(data) {this.known=data.known;}})', context);
  assert.deepEqual(startup, ['/overlook/api/dashboard?known=']);
  assert.equal(context.streamStarted, true);
  const page = context.document.body;
  context.window.visualViewport = {height:500, offsetTop:20};
  vm.runInContext('fitShell()', context);
  assert.equal(page.style.height, '500px');
  assert.equal(page.style.top, '20px');
  context.window.visualViewport = {height:400, offsetTop:300, scale:2};
  vm.runInContext('fitShell()', context);
  assert.equal(page.style.height, '500px');
  assert.equal(vm.runInContext('keyboardOpen()', context), false);
  const drag = (target) => {
    let blocked = false;
    docEvents.touchmove({target, preventDefault() { blocked = true; }});
    return blocked;
  };
  const scroller = (scrollHeight) => ({closest: () => ({scrollHeight, clientHeight:400})});
  context.window.visualViewport = {height:500, offsetTop:0};
  assert.equal(drag({closest: () => null}), true);
  assert.equal(drag(scroller(400)), true);
  assert.equal(drag(scroller(900)), false);
  context.window.visualViewport = {height:800, offsetTop:0};
  assert.equal(drag({closest: () => null}), false);
  const detail = elements.get('detail');
  Object.assign(detail, {scrollHeight:2000, clientHeight:800, scrollTop:0});
  assert.equal(vm.runInContext('atBottom()', context), false);
  detail.scrollTop = 1200;
  assert.equal(vm.runInContext('atBottom()', context), true);
  vm.runInContext('scrollToBottom()', context);
  assert.equal(detail.scrollTop, 2000);
  elements.get('text').value = 'pinyin';
  elements.get('text').dispatchEvent(new context.Event('compositionstart'));
  vm.runInContext('draft(composeId).text="stale"; syncCompose()', context);
  assert.equal(elements.get('text').value, 'pinyin');
  const before = elements.get('text').style.height;
  elements.get('text').scrollHeight = 600;
  elements.get('text').dispatchEvent(new context.Event('input'));
  assert.equal(elements.get('text').style.height, before);
  elements.get('text').value = '中文';
  elements.get('text').dispatchEvent(new context.Event('compositionend'));
  assert.equal(elements.get('text').value, '中文');
  assert.equal(vm.runInContext('draft(composeId).text', context), '中文');
  console.log('Draft isolation, concurrent typing, stable retry IDs; JS syntax, slash filtering/selection, steer routing, cancellation draft retention, confirmation retry and fork navigation passed');
})().catch(e=>{console.error(e);process.exitCode=1;});
