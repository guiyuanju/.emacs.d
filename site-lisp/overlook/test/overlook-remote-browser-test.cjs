const {chromium, devices}=require('playwright');
const path=require('path'), assert=require('assert/strict');
const root=path.join(__dirname, '..');
const output=require('os').tmpdir();
const scenarios=process.env.OVERLOOK_BROWSER_DEVICE
 ? [[process.env.OVERLOOK_BROWSER_DEVICE,process.env.OVERLOOK_BROWSER_THEME || 'light']]
 : [['iPhone 13','light'],['iPhone 13','dark'],['iPhone SE','light'],['Pixel 5','dark']];
const node=(id,title,extra={})=>({id,hash:id,title,kind:'text',children:[],commands:[],choices:[],...extra});
const section=node('projects','Projects',{kind:'group',heading:true,children:[node('project','Emacs',{kind:'project',heading:true,commands:[{name:'new',label:'New agent',input:'Task',options:['Claude','Codex']},{name:'delete',label:'Delete',confirm:true}],children:[
 node('agent','Review the Framework7 migration',{kind:'agent',agent:'a',provider:'claude',status:'working',subtitle:'Checking the mobile layout '.repeat(50),unreadCount:3,context:24,commands:[{name:'kill',label:'Kill',confirm:true}]}),
 node('todo','Review the mobile interface',{kind:'todo',status:'open',due:'2026-11-20',commands:[{name:'done',label:'Done'},{name:'draft',label:'Work on this',input:'Task'}]}),
 node('diff','overlook-remote.html',{kind:'file',subtitle:'site-lisp/overlook/',added:200,removed:300,diff:true})]})]});
section.children.push(node('writing','Writing',{kind:'project',children:[node('draft','A new essay',{kind:'agent',agent:'b',provider:'codex',status:'idle'})]}));
section.children.push(node('homelab','Home Lab',{kind:'project',children:[node('repo','server',{kind:'repo',children:[node('config','config.json',{kind:'file',diff:true})]})]}));
const usage=node('usage','Usage',{kind:'group',children:[
 node('claude-usage','Claude',{kind:'usage',provider:'claude',windows:[{label:'5h',value:24,reset:'2h 30m'},{label:'7d',value:12}]}),
 node('codex-usage','Codex',{kind:'usage',provider:'codex',windows:[{label:'5h',value:18},{label:'7d',value:92,reset:'3d'}]})]});
const personas=node('personas','Personas',{kind:'group',children:[node('reviewer','Reviewer',{kind:'persona',persona:'Reviewer',description:'Reviews code and explains tradeoffs.',subtitle:'Reviews code and explains tradeoffs.',status:'idle',commands:[{name:'new',label:'New conversation'}],children:[node('persona-chat','Architecture review',{kind:'agent',persona:'Reviewer',agent:'p',status:'idle',provider:'codex'})]})]});
personas.children.push(node('single-persona','An obscure task title',{kind:'agent',persona:'Helper',agent:'h',provider:'codex',status:'idle',commands:[{name:'open',label:'Open'}]}));
const agent={id:'a',title:'Framework7 migration',agent:'claude',status:'working',brief:'Checking the mobile layout',context:24,choices:[],queued:[],reply:'',transcript:'',controls:{steer:true,actions:['stop','reload','restart','fork','close'],slash:[{name:'compact',description:'Compact context'}]}};
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
 for(const [device,theme] of scenarios) {
  const ctx=await browser.newContext({...devices[device],colorScheme:theme});
  const page=await ctx.newPage();
  const settled = () => page.waitForFunction(() => !document.querySelector('.page-snapshot'));
  const group = () => page.locator('#dashboard-content').getByText('Emacs',{exact:true}); page.setDefaultTimeout(10000); const errors=[];const posts=[]; let failSend=false, failUpload=false, failQueue=false;
  page.on('pageerror',e=>errors.push(e.message));
  await page.route('http://overlook.test/**',async route=>{
   const url=new URL(route.request().url()); const rel=url.pathname.replace(/^\/overlook\/?/,'');
   const json=data=>route.fulfill({json:data});
   if(rel.startsWith('api/')){
    const name=rel.slice(4);
    if(name==='dashboard') return json({known:'one',sections:[usage,section,personas]});
    if(name==='dashboard/stream'||name==='events'&&url.searchParams.get('known')) return;
    const active=url.searchParams.get('id')==='p'?{...agent,id:'p',persona:'Reviewer',description:'Reviews code and explains tradeoffs.'}:agent;
    if(name==='agent') return json(active);
    if(name==='events') return json({known:'one',epoch:'test',seq:12,agent:active,history:{hasMore:true,before:11},items:[{item:11,seq:11,createdAt:'2026-11-12T10:00:00Z',type:'prompt',text:'Please review the migration.',images:[]},{item:12,seq:12,createdAt:'2026-11-12T10:00:05Z',type:'text',offset:0,text:'## Framework7\n\nThe **mobile interface** is ready.\n\n```js\nconst ready = true;\n```',images:[1]}]});
    if(name==='history') return json({epoch:'test',hasMore:false,before:1,items:[{item:1,seq:1,type:'prompt',text:'An earlier question',images:[]},{item:2,seq:2,type:'text',offset:0,text:'Earlier response\n'.repeat(35),images:[]}]});
    if(name==='image') return route.fulfill({contentType:'image/svg+xml',body:'<svg xmlns="http://www.w3.org/2000/svg" width="240" height="180"><rect width="240" height="180" fill="#007aff"/></svg>'});
    if(name==='diff') return json({diff:'@@ -1 +1 @@\n-old interface\n+Framework7 interface'});
    const body=route.request().postDataJSON();posts.push([name,body]);
    if(name==='prompt' && failSend) { failSend=false; return route.fulfill({status:503,json:{detail:'Temporarily unavailable'}}); }
    if(name==='unqueue' && failQueue) { failQueue=false; return route.fulfill({status:409,json:{detail:'Already delivered'}}); }
    if(name==='upload') {
     if(failUpload) { failUpload=false; return route.fulfill({status:503,json:{detail:'Upload interrupted'}}); }
     return json({text:'@uploaded-image'});
    }
    if(name==='session' && body.action==='close') return json(body.confirmations.length?{ok:true,closed:true}:{confirm:'Close this agent?',confirmations:['Close this agent?'],confirmationToken:'close-token'});
    if(name==='command') return json(body.confirmed?{ok:true}:{confirm:'Delete <img src=x onerror=alert(1)>?'});
    return json({ok:true,agent:'a'});
   }
   const file=!rel && process.env.OVERLOOK_BROWSER_HTML
    ? process.env.OVERLOOK_BROWSER_HTML : path.join(root,rel||'overlook-remote.html');
   return route.fulfill({path:file,contentType: file.endsWith('.css')?'text/css':file.endsWith('.js')?'text/javascript':'text/html'});
  });
  await page.goto('http://overlook.test/overlook/#test');
  await group().waitFor();
  const sections=await page.locator('#dashboard-content > .dashboard-section > h2').allTextContents();
  assert(sections.indexOf('Usage')<sections.indexOf('Projects'));
  assert.equal(await page.locator('.usage-disclosure[open]').count(),0);
  assert.equal(await page.locator('#dashboard-content .children, #dashboard-content .twist').count(),0);
  assert.equal(await page.locator('.remote-navbar #conn').count(),0);
  assert.equal(await page.locator('html.ios').count(),1);
  assert.equal(await page.locator('body').evaluate(el=>getComputedStyle(el).fontSize),'17px');
  assert.equal(await page.locator('.usage-window .usage-ring').count(),4);
  assert.equal(await page.locator('.usage-window .usage-ring').first().getAttribute('aria-valuenow'),'24');
  assert((await page.locator('.usage-window .usage-ring').first().getAttribute('style')).includes('24%'));
  assert.equal(await page.locator('.usage-window.warning').count(),1);
  assert.equal(await page.getByText('2h 30m',{exact:true}).count(),1);
  const bars=await page.locator('.usage-window .usage-ring').evaluateAll(els=>els.map(el=>el.getBoundingClientRect().toJSON()));
  assert.equal(bars[1].top, bars[0].top);
  assert(bars.every(bar=>bar.width===16 && bar.height===16 && bar.right<devices[device].viewport.width));
  await page.screenshot({path:`${output}/overlook-${device.replaceAll(' ','-')}-${theme}-dashboard.png`});
  assert.equal(await page.locator('.group-row .group-icon').count(),3);
  assert.equal(await page.locator('.persona-row .row-subtitle').count(),0);
  assert.equal(await page.getByText('Helper',{exact:true}).count(),1);
  assert.equal(await page.getByText('An obscure task title',{exact:true}).count(),0);
  const personaRow=page.locator('.persona-row').first();
  assert.equal(await personaRow.locator('.more').count(),0);
  assert.equal(await personaRow.locator('.item-link').count(),1);
  assert.equal(await personaRow.locator('.persona-count').innerText(),'1 conversation');
  assert.equal(await personaRow.locator('.agent-state').innerText(),'Available');
  assert(await personaRow.evaluate(el=>el.getBoundingClientRect().height>=76));
  await personaRow.scrollIntoViewIfNeeded();
  await personaRow.locator('button').dispatchEvent('contextmenu');
  await page.locator('.actions-modal.modal-in').waitFor();
  assert.equal(await page.locator('.actions-button').filter({hasText:'New conversation'}).count(),1);
  await page.locator('.actions-button').filter({hasText:'Cancel'}).click();
  await page.locator('.actions-modal').waitFor({state:'detached'});
  await page.screenshot({path:`${output}/overlook-${device.replaceAll(' ','-')}-${theme}-personas.png`});
  await group().scrollIntoViewIfNeeded();
  await page.screenshot({path:`${output}/overlook-${device.replaceAll(' ','-')}-${theme}-projects.png`});
  await group().click();
  const snapshot = page.locator('.page-snapshot');
  if (await snapshot.count()) {
    assert.equal(await snapshot.locator('[id]').count(),0);
    assert.equal(await snapshot.evaluate(el=>el.parentElement.classList.contains('view-main')),true);
    assert.equal(await snapshot.locator('[data-snapshot-id="dashboard-content"] .list').first().evaluate(el=>getComputedStyle(el).borderRadius),'12px');
  }
  await settled();
  await page.getByRole('heading',{name:'Conversations',exact:true}).waitFor();
  assert.equal(await page.getByRole('heading',{name:'Code & changes',exact:true}).count(),1);
  assert.equal(await page.locator('.file-row .file-icon').count(),1);
  await page.getByRole('heading',{name:'To do',exact:true}).waitFor();
  assert.equal(await page.locator('.task-check').count(),1);
  assert.equal(await page.locator('.task-row input').count(),0);
  assert.equal(await page.locator('.task-check svg').count(),1);
  assert.equal(await page.locator('.conversation-row .remote-row.item-link').count(),0);
  const rowBounds=await page.locator('.conversation-row').evaluate(el=>({
    text:el.querySelector('.text').getBoundingClientRect().right,
    more:el.querySelector('.more').getBoundingClientRect().left}));
  assert(rowBounds.text<=rowBounds.more);
  assert.equal(await page.locator('.conversation-row .unread-badge').innerText(),'3');
  assert(await page.locator('.conversation-row .row-subtitle').evaluate(el=>el.getBoundingClientRect().height<50));
  await page.getByRole('button',{name:'Complete: Review the mobile interface',exact:true}).click();
  await page.locator('.dialog.modal-in').waitFor();
  await page.locator('.dialog-button').filter({hasText:'Cancel'}).click();
  await page.locator('.dialog').waitFor({state:'detached'});
  await page.screenshot({path:`${output}/overlook-${device.replaceAll(' ','-')}-${theme}-project.png`});
  const centering=await page.locator('.agent-icon').first().evaluate(el=>{const a=el.getBoundingClientRect(),b=el.firstElementChild.getBoundingClientRect();return Math.abs((a.top+a.bottom-b.top-b.bottom)/2);});
  assert(centering<1,`Agent icon is off center by ${centering}px`);
  await page.locator('#session-menu').click();
  await page.locator('.actions-modal.modal-in').waitFor();
  await page.locator('.actions-button').filter({hasText:'New agent'}).click();
  await page.locator('.remote-sheet textarea').fill('Review this migration');
  await page.locator('.actions-modal').waitFor({state:'detached'});
  await page.waitForTimeout(400);
  await page.screenshot({path:`${output}/overlook-${device.replaceAll(' ','-')}-${theme}-sheet.png`});
  await page.locator('.remote-sheet').getByRole('button',{name:'Cancel',exact:true}).click();
  await page.locator('.sheet-modal').waitFor({state:'detached'});
  await page.getByRole('button',{name:'New conversation in Emacs',exact:true}).click();
  assert.equal(await page.locator('.remote-sheet textarea').inputValue(),'Review this migration');
  await page.locator('.remote-sheet').getByRole('button',{name:'Cancel',exact:true}).click();
  await page.locator('.sheet-modal').waitFor({state:'detached'});
  await page.getByText('overlook-remote.html',{exact:true}).click();
  await page.locator('.remote-sheet pre.diff').waitFor();
  await page.getByRole('button',{name:'Close sheet',exact:true}).click();
  await page.locator('.sheet-modal').waitFor({state:'detached'});
  await page.locator('#session-menu').click();
  await page.locator('.actions-button').filter({hasText:'Delete'}).click();
  await page.locator('.dialog.modal-in').waitFor();
  assert.equal(await page.locator('.dialog img').count(),0);
  assert((await page.locator('.dialog').innerText()).includes('<img src=x onerror=alert(1)>'));
  await page.locator('.dialog-button').filter({hasText:'Cancel'}).click();
  await page.locator('.dialog').waitFor({state:'detached'});
  await page.getByText('Review the Framework7 migration',{exact:true}).click();
  await page.locator('#d-feed .markdown').waitFor();
  await settled();
  assert.equal(await page.locator('#d-feed .message-time').count(),2);
  await page.getByRole('button',{name:'Load earlier messages',exact:true}).waitFor();
  const anchorBefore=await page.locator('#d-feed > .prompt').evaluate(el=>el.getBoundingClientRect().top);
  await page.evaluate(()=>loadEarlier(poller));
  const anchorAfter=await page.locator('#d-feed > .prompt').last().evaluate(el=>el.getBoundingClientRect().top);
  assert(Math.abs(anchorBefore-anchorAfter)<2,`History moved reading position ${anchorBefore} -> ${anchorAfter}`);
  assert.equal(await page.getByRole('button',{name:'Load earlier messages',exact:true}).count(),0);
  assert.equal(await page.locator('#d-feed > .prompt').first().innerText(),'An earlier question');
  assert.equal(await page.locator('#d-feed .content-preview').count(),1);
  await page.locator('#d-feed').getByRole('button',{name:'Show full message',exact:true}).click();
  assert.equal(await page.locator('#d-feed .content-preview').count(),0);
  await page.evaluate(()=>{
    const follow={nodes:new Map()};
    renderItems(follow,[{item:500,type:'text',offset:0,text:'Long response '.repeat(250)+'\n\n```js\n'+'const value = 1;\n'.repeat(30)+'```',images:[]}]);
    const node=follow.nodes.get(500); node.id='long-response-test';
  });
  const longReply=page.locator('#long-response-test');
  assert(await longReply.locator('.content-preview').evaluate(el=>el.getBoundingClientRect().height<=340));
  await longReply.getByRole('button',{name:'Show full message',exact:true}).click();
  assert.equal(await longReply.locator('.content-preview').count(),0);
  await longReply.getByRole('button',{name:'Show full code',exact:true}).click();
  assert.equal(await longReply.locator('.code-preview').count(),0);
  const batchCounts = await page.evaluate(()=>{
    const feed=$('d-feed'), saved=[...feed.childNodes];
    feed.replaceChildren();
    const originalGroup=groupCompletedTools;
    let groups=0;
    groupCompletedTools=()=>{groups++; originalGroup();};
    try {
      renderItems({nodes:new Map()},Array.from({length:50},(_,i)=>({item:i+1,type:'prompt',text:'Question',images:[]})));
      return {groups,count:feed.children.length};
    } finally { groupCompletedTools=originalGroup; feed.replaceChildren(...saved); }
  });
  assert.deepEqual(batchCounts,{groups:1,count:50},'Batch loading groups the feed once');
  await page.evaluate(()=>{
    const node=document.getElementById('long-response-test');
    node.source+=' Stream continued'; node.drawn=0; renderReply(node);
  });
  assert.equal(await longReply.locator('.content-preview').count(),0,'Expanded streamed replies must stay expanded');
  assert.equal(await longReply.locator('.code-preview').count(),0,'Expanded code must stay expanded during streaming');
  await longReply.getByRole('button',{name:'Copy full text',exact:true}).click();
  await longReply.getByRole('button',{name:'Copied',exact:true}).waitFor();
  await longReply.evaluate(el=>el.remove());
  await page.locator('#d-feed .code-copy').click();
  await page.getByRole('button',{name:'Copied',exact:true}).waitFor();
  await page.evaluate(()=>{
    const follow={nodes:new Map()}; window.toolTestFollow=follow;
    renderItems(follow,Array.from({length:3},(_,i)=>({item:100+i,type:'tool',status:'completed',title:'Read a file',images:[]})));
  });
  assert.equal(await page.locator('.tool-group summary').innerText(),'3 completed actions');
  await page.locator('.tool-group summary').click();
  assert.equal(await page.locator('.tool-group[open] .tool').count(),3);
  await page.evaluate(()=>renderItems(window.toolTestFollow,[{item:99,type:'tool',status:'completed',title:'An older updated tool',images:[]}]));
  assert.deepEqual(await page.locator('.tool-group .tool').evaluateAll(nodes=>nodes.map(node=>node.itemId)),[99,100,101,102]);
  await page.evaluate(()=>document.querySelector('.tool-group').remove());

  assert.equal(await page.locator('#send').isDisabled(),true);
  await page.locator('#compose-status').getByRole('button',{name:'Stop',exact:true}).waitFor();
  await page.locator('#heading .navigation-info').click();
  await page.locator('.conversation-info').waitFor();
  assert((await page.locator('.conversation-info').innerText()).includes('24% used'));
  await page.getByRole('button',{name:'Close sheet',exact:true}).click();
  await page.locator('.sheet-modal').waitFor({state:'detached'});
  await page.locator('#text').fill('保留这个草稿');
  await page.screenshot({path:`${output}/overlook-${device.replaceAll(' ','-')}-${theme}-agent.png`});
  const header = await page.evaluate(() => {
    const rect = id => document.getElementById(id).getBoundingClientRect().toJSON();
    return {title:rect('heading'),back:rect('back'),menu:rect('session-menu')};
  });
  assert(header.title.left >= header.back.right - 1);
  assert(header.title.right <= header.menu.left + 1);
  const titleLines = await page.locator('#heading').evaluate(el=>Array.from(el.querySelector('.navigation-info').children).map(child=>child.getBoundingClientRect().toJSON()));
  assert(titleLines[0].top >= header.title.top);
  assert(titleLines[1].bottom <= header.title.bottom + 1);
  const layout=await page.evaluate(()=>{const rect=id=>{const r=document.getElementById(id).getBoundingClientRect();return {top:r.top,bottom:r.bottom,height:r.height,width:r.width}};return {compose:rect('compose'),detail:rect('detail'),text:rect('text'),height:innerHeight,body:document.body.scrollWidth,width:innerWidth};});
  console.log(device,theme,layout);
  assert(layout.compose.bottom<=layout.height+1);
  assert(layout.detail.bottom<=layout.compose.top+1);
  assert(layout.text.width>70);
  assert(layout.body<=layout.width);
  assert(await page.locator('#d-live .preloader').innerHTML());
  await page.getByRole('button',{name:'Conversation actions'}).click();
  await page.locator('.actions-modal.modal-in').waitFor();
  await page.locator('.actions-button').filter({hasText:'Cancel'}).click();
  await page.locator('.actions-modal').waitFor({state:'detached'});
  await page.locator('#d-feed img').click();
  await page.locator('.photo-browser').waitFor();
  await page.locator('.photo-browser .popup-close').click();
  await page.locator('.photo-browser').waitFor({state:'detached'});
  await page.waitForFunction(() => photoBrowser === null);
  await page.evaluate(() => {
    const detail=document.getElementById('detail');
    const history=document.createElement('div'); history.id='long-history'; history.style.height='2000px';
    document.getElementById('d-feed').prepend(history);
    detail.scrollTop=0; detail.dispatchEvent(new Event('scroll'));
  });
  await page.getByRole('button',{name:'Jump to latest message'}).click();
  await page.waitForFunction(()=>document.getElementById('latest').hidden);
  assert(await page.evaluate(()=>atBottom()));
  await page.evaluate(()=>document.getElementById('long-history').remove());
  await page.locator('#back').click();
  await settled();
  await page.getByText('Review the Framework7 migration',{exact:true}).click();
  await settled();
  assert.equal(await page.locator('#text').inputValue(),'保留这个草稿');
  await page.locator('#send').click();
  await page.waitForFunction(()=>document.getElementById('text').value==='');
  assert(posts.some(([name,body])=>name==='prompt'&&body.text==='保留这个草稿'));
  failSend=true;
  await page.locator('#text').fill('Keep this retry draft');
  await page.locator('#send').click();
  await page.getByText('Not sent · Temporarily unavailable',{exact:true}).waitFor();
  assert.equal(await page.locator('#text').inputValue(),'Keep this retry draft');
  const firstAttempt=posts.filter(([name])=>name==='prompt').at(-1)[1].requestId;
  await page.getByRole('button',{name:'Retry send',exact:true}).click();
  await page.waitForFunction(()=>document.getElementById('text').value==='');
  assert.equal(posts.filter(([name])=>name==='prompt').at(-1)[1].requestId,firstAttempt);
  await page.evaluate(()=>renderHeader({...shownAgent,choices:[{key:'allow',label:'Allow once'},{key:'deny',label:'Deny'}]}));
  await page.locator('.permission-card').getByRole('button',{name:'Allow once',exact:true}).click();
  await page.getByText('Response sent. Waiting for the agent…',{exact:true}).waitFor();
  assert.equal(await page.locator('.permission-card').getByRole('button',{name:'Deny',exact:true}).isDisabled(),true);
  await page.evaluate(()=>renderLive({...shownAgent,choices:[],queueItems:[{id:'queue-1',text:'Queued task'}]}));
  await page.locator('#text').fill('Existing draft');
  failQueue=true;
  await page.locator('.queued').getByRole('button',{name:'Edit',exact:true}).click();
  await page.getByText('Could not change queue · Already delivered',{exact:true}).waitFor();
  assert.equal(await page.locator('#text').inputValue(),'Existing draft');
  await page.locator('.queued').getByRole('button',{name:'Edit',exact:true}).click();
  await page.waitForFunction(()=>document.getElementById('text').value==='Existing draft\n\nQueued task');
  await page.evaluate(()=>renderHeader({...shownAgent,choices:[],queueItems:[]}));
  failUpload=true;
  await page.locator('#files').setInputFiles({name:'pixel.png',mimeType:'image/png',buffer:Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a7X8AAAAASUVORK5CYII=','base64')});
  await page.locator('.attachment').getByText('Upload interrupted',{exact:true}).waitFor();
  await page.locator('.attachment').getByRole('button',{name:'Retry',exact:true}).click();
  await page.locator('.attachment').getByText('Attached',{exact:true}).waitFor();
  assert((await page.locator('#text').inputValue()).includes('@uploaded-image'));
  await page.getByRole('button',{name:'Remove pixel.png',exact:true}).click();
  assert(!(await page.locator('#text').inputValue()).includes('@uploaded-image'));
  await page.evaluate(()=>{connectionFailure(new TypeError('offline'));});
  assert.equal(await page.locator('#connection').isVisible(),true);
  assert((await page.locator('#text').inputValue()).includes('Existing draft'));
  await page.evaluate(()=>connected());
  await page.locator('#text').fill('');

  await page.locator('#back').click();
  await settled();
  await page.locator('#back').click();
  await settled();
  await group().waitFor();
  await page.goto('http://overlook.test/overlook/?node=project#test');
  await page.getByText('Review the Framework7 migration',{exact:true}).waitFor();
  await page.locator('#back').click();
  await settled();
  await group().waitFor();
  await page.getByText('Reviewer',{exact:true}).click();
  await settled();
  await page.getByText('Architecture review',{exact:true}).click();
  await settled();
  await page.locator('#persona-profile h2').waitFor();
  assert.equal(await page.locator('#persona-profile p').innerText(),'Reviews code and explains tradeoffs.');
  assert.equal(await page.locator('#heading .navigation-title').innerText(),'Framework7 migration');
  assert.equal(await page.locator('#text').getAttribute('placeholder'),'Message Reviewer');
  await page.screenshot({path:`${output}/overlook-${device.replaceAll(' ','-')}-${theme}-persona-chat.png`});
  await page.goto('http://overlook.test/overlook/#test');
  await group().waitFor();
  await page.emulateMedia({reducedMotion:'reduce'});
  await group().click();
  assert.equal(await page.locator('.page-snapshot').count(),0);
  await page.getByText('Review the Framework7 migration',{exact:true}).click();
  await settled();
  await page.getByRole('button',{name:'Conversation actions',exact:true}).click();
  await page.locator('.actions-button').filter({hasText:'Close agent'}).click();
  await page.locator('.dialog.modal-in').waitFor();
  await page.locator('.dialog-button').filter({hasText:'Close agent'}).click();
  await page.waitForURL(url=>!url.searchParams.has('agent'));
  await settled();
  assert.equal(new URL(page.url()).searchParams.get('node'),'project');
  assert(posts.some(([name,body])=>name==='session'&&body.action==='close'&&body.confirmationToken==='close-token'));
  assert(posts.some(([name,body])=>name==='seen'&&body.through===12&&body.epoch==='test'));
  assert.deepEqual(errors,[]);
  await ctx.close();
 }
 await browser.close(); console.log('Framework7 mobile browser smoke checks passed');
})().catch(e=>{console.error(e);process.exit(1)});
