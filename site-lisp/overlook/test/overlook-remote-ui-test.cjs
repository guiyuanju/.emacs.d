const fs = require('fs');
const vm = require('vm');
const assert = require('assert/strict');
class Element {
  constructor() { this.value=''; this.style={setProperty(){}}; this.dataset={}; this.children=[]; this.events={}; this.scrollHeight=44; }
  setAttribute(name, value) { this[name]=value; }
  addEventListener(name, fn) { this.events[name]=fn; }
  dispatchEvent(e) { this.events[e.type]?.({...e,target:this}); }
  replaceChildren(...children) { this.children=children; }
  append(...children) { this.children.push(...children); }
  getBoundingClientRect() { return {height: this.height ?? 100}; }
  focus() { this.focused=true; }
  closest() { return null; }
  removeAttribute(name) { delete this[name]; }
  remove() { this.removed=true; }
  querySelector() { return null; }
  querySelectorAll(selector) { return selector==='button' ? this.children.filter(child=>child.tagName==='BUTTON') : []; }
  click() { return this.onclick?.(); }
  get classList() { return {add: name => { this.className = (this.className || '') + ' ' + name; }}; }
}
const elements = new Map();
const docEvents = {};
const context = vm.createContext({
  document: { documentElement: {scrollHeight:2000,style:{setProperty(){}}}, body: {scrollHeight:2000, style:{}, classList:{toggle(){}}}, getElementById: id => { if(!elements.has(id)) elements.set(id,new Element()); return elements.get(id); }, createElement: tag => { const el=new Element(); el.tagName=tag.toUpperCase(); return el; }, addEventListener: (name,fn) => docEvents[name]=fn },
  history: {state:null},
  location: {hash:'#test',search:'?agent=original',pathname:'/overlook/'},
  localStorage: {getItem:(key)=>key==='overlook-token'?'test':null, setItem(){}},
  DOMPurify: {addHook(){}, sanitize: text => text}, window: {addEventListener(){}}, URLSearchParams, AbortController, Event: class {constructor(type) {this.type=type;}},
  Framework7: function() {
    const modal = () => ({open(){},close(){}});
    this.views = {create(){}};
    this.toast = {create: options => {
      const instance = {open(){}, close() {
        if (this.destroyed) throw new TypeError("undefined is not an object (evaluating 't.params.animate')");
        options.on?.closed?.(this);
        this.destroyed = true;
      }};
      return instance;
    }};
    this.dialog = {create: options => {
      context.lastDialog = options;
      return {open() { if (!context.deferDialog) options.buttons[context.confirm() ? 1 : 0].onClick(); }};
    }, close(){}};
    this.actions = {create: modal, close(){}};
    this.photoBrowser = {create: modal, get(){}};
  },
  navigator: {onLine:true}, performance: {now:()=>2000}, innerHeight:800, scrollY:0,
  crypto: require("crypto").webcrypto, Uint8Array, clearTimeout(){},setTimeout(){},setInterval(){},confirm:()=>true,
});
let script=fs.readFileSync(process.env.OVERLOOK_UI_HTML || require('path').join(__dirname, '..', 'overlook-remote.html'),'utf8').match(/<script>\s*([\s\S]*?)<\/script>/)[1];
script=script.replace(/\nshow\(\);\s*$/,'');
context.scrollTo = (x,y) => {context.lastScroll = [x,y];};
vm.runInContext(script,context);
vm.runInContext('composeId = "original";',context);
const navigation = vm.createContext({
  window: {}, history: {back() {}}, show() {}, calls: [],
});
// Run the actual history handlers without starting network or rendering work.
navigation.transitionPage = (update, back, animate) => navigation.calls.push([back, animate]);
vm.runInContext('let navigationDepth = 2; let animateHistoryBack = false;\n'
  + script.match(/function goBack\(\) \{[\s\S]*?\n\}/)[0] + '\n'
  + script.match(/window.onpopstate = \(event\) => \{[\s\S]*?\n\};/)[0], navigation);
navigation.window.onpopstate({state:{overlookDepth:1}});
assert.deepEqual(navigation.calls.pop(), [true, false]);
vm.runInContext('goBack()', navigation);
navigation.window.onpopstate({state:{overlookDepth:0}});
assert.deepEqual(navigation.calls.pop(), [true, true]);
navigation.window.onpopstate({state:{overlookDepth:1}});
assert.deepEqual(navigation.calls.pop(), [false, false]);
navigation.window.onpopstate({state:{overlookDepth:0}});
assert.deepEqual(navigation.calls.pop(), [true, false]);
(async()=>{
  assert.equal(vm.runInContext('checkProtocol({protocolVersion:2}).protocolVersion',context),2);
  assert.throws(()=>vm.runInContext('checkProtocol({protocolVersion:99})',context),error=>error.code==='protocol_mismatch');
  assert.equal(vm.runInContext('formatDuration(125)',context),'2m 5s');
  vm.runInContext('renderLive({id:"original",queueError:null,choices:[],queued:["same","same"],queueItems:[{id:"q1",text:"same"},{id:"q2",text:"same"}],status:"idle"})',context);
  const queueRequests=[];
  context.fetch=async (url,options)=>{queueRequests.push(JSON.parse(options.body));return {ok:true,json:async()=>({ok:true,protocolVersion:2})};};
  await elements.get('d-live').children[1].children[1].children[2].onclick();
  assert.equal(queueRequests[0].queueId,'q2');
  vm.runInContext('renderLive({id:"original",choices:[{key:"allow",label:"Allow"}],queued:[],status:"waiting"})',context);
  await elements.get('d-live').children[0].children[2].children[0].onclick();
  vm.runInContext('renderLive({id:"original",choices:[{key:"allow",label:"Allow"}],queued:[],status:"waiting"})',context);
  assert.equal(elements.get('d-live').children[0].children[2].children[0].disabled,true);
  vm.runInContext('renderLive({id:"original",choices:[],queued:[],status:"idle"});renderLive({id:"original",choices:[{key:"allow",label:"Allow"}],queued:[],status:"waiting"})',context);
  assert.equal(elements.get('d-live').children[0].children[2].children[0].disabled,false);
  assert.equal(vm.runInContext('dashboardDue("2026-11-12",new Date(2026,10,12)).label',context),'Due today');
  assert.equal(vm.runInContext('dashboardDue("2026-11-11",new Date(2026,10,12)).overdue',context),true);
  const sorted=vm.runInContext('stableProjectNodes([{id:"z",title:"Zulu",kind:"project"},{id:"r",title:"Resource",kind:"text"},{id:"a",title:"Alpha",kind:"project"}]).map(node=>node.id).join(",")',context);
  assert.equal(sorted,'a,r,z');
  const projectStates = vm.runInContext(`projectAgentSummary({children:[
    {kind:"agent",agent:"a",status:"working"},
    {kind:"group",children:[{kind:"agent",agent:"b",status:"working"},
      {kind:"agent",agent:"a",status:"working"},
      {kind:"agent",agent:"c",status:"waiting"}]},
    {kind:"saved",status:"working"}, {kind:"agent",agent:"d",status:"idle"}
  ]}).children.map(item=>item.textContent).join(",")`,context);
  assert.equal(projectStates,'2 Working,1 Needs attention');
  assert.equal(vm.runInContext('projectAgentSummary({children:[]}).children.length',context),0);


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
  const seen=[];
  const realFetch=context.fetch;
  context.fetch=async (path,options) => { seen.push([path,options.body]); return {ok:true,status:200,json:async()=>({ok:true})}; };
  vm.runInContext('renderHeader({id:"original",status:"done",agent:"claude",choices:[],queued:[]})',context);
  assert.equal(seen.length,0, 'Header state alone must not mark unseen activity read');
  elements.get('detail').scrollTop=0; elements.get('detail').clientHeight=100;
  vm.runInContext('poller={id:"original",epoch:"test",presentedSeq:12,firstNews:false};markSeen();markSeen()',context);
  assert.deepEqual(seen,[['/overlook/api/seen','{"id":"original","through":12,"epoch":"test"}']]);
  elements.get('detail').scrollHeight=1000;
  vm.runInContext('poller.presentedSeq=14;markSeen()',context);
  assert.equal(seen.length,1, 'Reading old history must not acknowledge new messages');
  elements.get('detail').scrollTop=1000;
  vm.runInContext('markSeen()',context);
  assert.equal(seen.length,2);
  assert.equal(JSON.parse(seen[1][1]).through,14);
  vm.runInContext('poller.presentedSeq=16;poller.nodes=new Map([[1,{timer:1}]]);markSeen();poller.nodes.clear();document.hidden=true;markSeen();document.hidden=false;poller=null',context);
  assert.equal(seen.length,2, 'Hidden pages must not acknowledge messages');
  elements.get('detail').scrollHeight=44;
  context.fetch=realFetch;
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
  context.fetch=async(url,opts)=>{const b=JSON.parse(opts.body);n++; if(n===1)return{ok:true,json:async()=>({confirm:'Restart?',confirmations:['Restart?']})};assert.deepEqual(b.confirmations,['Restart?']);return{ok:true,json:async()=>({ok:true,agent:'forked'})};};
  vm.runInContext('open = (id) => { globalThis.opened = id; }',context);
  await vm.runInContext('sessionAction("fork", $("session-menu"))',context);
  assert.equal(context.opened,'forked');
  assert.equal(n,2);
  let confirmations = 0;
  context.fetch=async(url,opts)=>{
    const body=JSON.parse(opts.body);
    confirmations++;
    if(confirmations===1) return {ok:true,json:async()=>({confirm:'Restart?',confirmations:['Restart?'],confirmationToken:'old'})};
    if(confirmations===2) return {ok:true,json:async()=>({confirm:'Restart?',confirmations:['Restart?'],confirmationToken:'new'})};
    assert.deepEqual(body.confirmations,['Restart?']);
    assert.equal(body.confirmationToken,'new');
    return {ok:true,json:async()=>({ok:true,agent:'forked'})};
  };
  await vm.runInContext('sessionAction("restart", $("session-menu"))',context);
  assert.equal(confirmations,3);

  const reloads=[];
  context.fetch=async(url,opts)=>{reloads.push(JSON.parse(opts.body).requestId);return{ok:true,json:async()=>({ok:true,agent:'original'})};};
  await vm.runInContext('sessionAction("reload", $("session-menu"))',context);
  await vm.runInContext('sessionAction("reload", $("session-menu"))',context);
  assert.notEqual(reloads[0],reloads[1]);
  vm.runInContext('toast("First"); globalThis.expiredToast = toast.current; toast.current.close(); toast("After timeout")', context);
  assert.equal(context.expiredToast.destroyed, true);
  assert.equal(vm.runInContext('toast.current.destroyed', context), undefined);
  vm.runInContext('globalThis.previousToast = toast.current; toast("Replacement"); previousToast.close = () => { throw new Error("Closed twice"); }; toast("Next")', context);
  vm.runInContext('toast.current.destroyed = true; toast("After destruction")', context);
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
  assert.match(elements.get('connection-message').textContent, /Open a fresh link/);
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
  // A failed first request must leave loading, while allowing the poller to retry.
  vm.runInContext('renderLoading("d-feed", "Loading conversation…")', context);
  let replacement;
  const feed = elements.get('d-feed');
  feed.querySelector = selector => selector === '.view-state.loading' ? {replaceWith: state => { replacement = state; }} : null;
  assert.equal(vm.runInContext('connectionFailure({status:500, code:"internal_error"})', context), false);
  assert.equal(replacement.children[0].textContent, 'Unable to load');
  assert.match(replacement.children[1].textContent, /Reconnecting/);
  assert.equal(feed['aria-busy'], undefined);
  feed.querySelector = () => null;
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
  assert.equal(elements.get('d-live').children[0].textContent, 'Queued messages paused: Submission failed');
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
  let sends = 0;
  elements.get('send').click = () => sends++;
  const key = (extra) => { let prevented = false; elements.get('text').events.keydown({key:'Enter', preventDefault: () => { prevented = true; }, ...extra}); return prevented; };
  assert.equal(key({}), false);
  assert.equal(key({metaKey:true, isComposing:true}), false);
  assert.equal(sends, 0);
  assert.equal(key({metaKey:true}), true);
  assert.equal(key({ctrlKey:true}), true);
  assert.equal(sends, 2);
  assert.equal(vm.runInContext('nodeTitle({title:"Full untruncated session title"})',context),'Full untruncated session title');
  const hierarchy = [{id:'projects',children:[{id:'project',children:[{id:'repo',children:[]}]}]}];
  const path = vm.runInContext('dashboardPath', context)('repo', hierarchy);
  assert.equal(path.map(node => node.id).join('/'), 'projects/project/repo');
  assert.equal(vm.runInContext('dashboardPath', context)('removed', hierarchy), null);
  // Closing a dialog without choosing a button must release the pending action.
  context.deferDialog = true;
  const cancelled = vm.runInContext('confirmAction("Delete <file> & retry?")', context);
  assert.equal(context.lastDialog.text, 'Delete &lt;file&gt; &amp; retry?');
  context.lastDialog.on.closed();
  assert.equal(await cancelled, false);
  context.deferDialog = false;
  const previousDialog = context.lastDialog;
  context.fetch = async () => new Promise(resolve => { finish = resolve; });
  const lateAction = vm.runInContext('sessionAction("reload", $("session-menu"))', context);
  vm.runInContext('viewGeneration++', context);
  finish({ok:true,json:async()=>({confirm:'Restart the old session?'})});
  await lateAction;
  assert.equal(context.lastDialog, previousDialog);
  assert.equal(vm.runInContext('sessionPending || draft(composeId).pending', context), false);
  const branchOf = (node, parentBranch) => vm.runInContext(`shownBranch(${JSON.stringify(node)}, ${JSON.stringify(parentBranch)})`, context);
  assert.deepEqual(branchOf({kind:'repo',title:'main',branch:'main'}), null);
  assert.deepEqual(branchOf({kind:'repo',title:'api',branch:'fix'}, 'fix'), null);
  assert.deepEqual(branchOf({kind:'repo',title:'web',branch:'hotfix'}, 'fix'), 'hotfix');
  assert.deepEqual(branchOf({kind:'repo',title:'api',branch:'dev'}), 'dev');
  console.log('Draft isolation, concurrent typing, stable retry IDs; JS syntax, slash filtering/selection, steer routing, cancellation draft retention, confirmation retry, fork navigation, repo branches and Cmd/Ctrl+Enter sending passed');
})().catch(e=>{console.error(e);process.exitCode=1;});
