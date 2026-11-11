const {chromium, devices}=require('playwright');
const path=require('path'), assert=require('assert/strict');
const root=path.join(__dirname, '..');
const output=require('os').tmpdir();
const node=(id,title,extra={})=>({id,hash:id,title,kind:'text',children:[],commands:[],choices:[],...extra});
const section=node('projects','Projects',{kind:'group',heading:true,children:[node('project','Emacs',{kind:'project',heading:true,commands:[{name:'new',label:'New agent',input:'Task',options:['Claude','Codex']},{name:'delete',label:'Delete',confirm:true}],children:[
 node('agent','Review the Framework7 migration',{kind:'agent',agent:'a',provider:'claude',status:'working',subtitle:'Checking the mobile layout',context:24,commands:[{name:'kill',label:'Kill',confirm:true}]}),
 node('todo','Review the mobile interface',{kind:'todo',status:'open',due:'2026-11-20',commands:[{name:'done',label:'Done'},{name:'draft',label:'Work on this',input:'Task'}]}),
 node('diff','overlook-remote.html',{kind:'file',subtitle:'site-lisp/overlook/',added:200,removed:300,diff:true})]})]});
section.children.push(node('writing','Writing',{kind:'project',children:[node('draft','A new essay',{kind:'agent',agent:'b',provider:'codex',status:'idle'})]}));
section.children.push(node('homelab','Home Lab',{kind:'project',children:[node('repo','server',{kind:'repo',children:[node('config','config.json',{kind:'file',diff:true})]})]}));
const usage=node('usage','Usage',{kind:'group',children:[
 node('claude-usage','Claude',{kind:'usage',provider:'claude',windows:[{label:'5h',value:24,reset:'2h 30m'},{label:'7d',value:12}]}),
 node('codex-usage','Codex',{kind:'usage',provider:'codex',windows:[{label:'5h',value:18},{label:'7d',value:92,reset:'3d'}]})]});
const agent={id:'a',title:'Framework7 migration',agent:'claude',status:'working',brief:'Checking the mobile layout',context:24,choices:[],queued:[],reply:'',transcript:'',controls:{steer:true,actions:['stop','reload','restart','fork'],slash:[{name:'compact',description:'Compact context'}]}};
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
 for(const [device,theme] of [['iPhone 13','light'],['iPhone 13','dark'],['iPhone SE','light'],['Pixel 5','dark']]) {
  const ctx=await browser.newContext({...devices[device],colorScheme:theme});
  const page=await ctx.newPage();
  const settled = () => page.waitForFunction(() => !document.querySelector('.page-snapshot'));
  const group = () => page.locator('#dashboard-content').getByText('Emacs',{exact:true}); page.setDefaultTimeout(10000); const errors=[];const posts=[];
  page.on('pageerror',e=>errors.push(e.message));
  await page.route('http://overlook.test/**',async route=>{
   const url=new URL(route.request().url()); const rel=url.pathname.replace(/^\/overlook\/?/,'');
   const json=data=>route.fulfill({json:data});
   if(rel.startsWith('api/')){
    const name=rel.slice(4);
    if(name==='dashboard') return json({known:'one',sections:[usage,section]});
    if(name==='dashboard/stream'||name==='events'&&url.searchParams.get('known')) return;
    if(name==='agent') return json(agent);
    if(name==='events') return json({known:'one',epoch:'test',seq:2,agent,items:[{item:1,type:'prompt',text:'Please review the migration.',images:[]},{item:2,type:'text',offset:0,text:'## Framework7\n\nThe **mobile interface** is ready.\n\n```js\nconst ready = true;\n```',images:[1]}]});
    if(name==='image') return route.fulfill({contentType:'image/svg+xml',body:'<svg xmlns="http://www.w3.org/2000/svg" width="240" height="180"><rect width="240" height="180" fill="#007aff"/></svg>'});
    if(name==='diff') return json({diff:'@@ -1 +1 @@\n-old interface\n+Framework7 interface'});
    const body=route.request().postDataJSON();posts.push([name,body]);
    if(name==='command') return json(body.confirmed?{ok:true}:{confirm:'Delete <img src=x onerror=alert(1)>?'});
    return json({ok:true,agent:'a'});
   }
   const file=path.join(root,rel||'overlook-remote.html');
   return route.fulfill({path:file,contentType: file.endsWith('.css')?'text/css':file.endsWith('.js')?'text/javascript':'text/html'});
  });
  await page.goto('http://overlook.test/overlook/#test');
  await group().waitFor();
  assert.equal(await page.locator('#dashboard-content .children, #dashboard-content .twist').count(),0);
  assert.equal(await page.locator('.remote-navbar #conn').count(),0);
  assert.equal(await page.locator('html.ios').count(),1);
  assert.equal(await page.locator('body').evaluate(el=>getComputedStyle(el).fontSize),'17px');
  assert.equal(await page.locator('.usage-window .progressbar').count(),4);
  assert.equal(await page.locator('.usage-window .progressbar').first().getAttribute('aria-valuenow'),'24');
  assert((await page.locator('.usage-window .progressbar span').first().getAttribute('style')).includes('-76%'));
  assert.equal(await page.locator('.usage-window.warning').count(),1);
  assert.equal(await page.getByText('Reset · 2h 30m',{exact:true}).count(),1);
  const bars=await page.locator('.usage-window .progressbar').evaluateAll(els=>els.map(el=>el.getBoundingClientRect().toJSON()));
  assert(bars[1].top > bars[0].bottom + 20);
  assert(bars.every(bar=>bar.width>200 && bar.right<devices[device].viewport.width));
  await page.screenshot({path:`${output}/overlook-${device.replaceAll(' ','-')}-${theme}-dashboard.png`});
  assert.equal(await page.locator('.group-row .group-icon').count(),3);
  assert.equal(await page.locator('.row-subtitle').count(),0);
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
  await page.getByRole('button',{name:'Complete: Review the mobile interface',exact:true}).click();
  await page.locator('.dialog.modal-in').waitFor();
  await page.locator('.dialog-button').filter({hasText:'Cancel'}).click();
  await page.locator('.dialog').waitFor({state:'detached'});
  await page.screenshot({path:`${output}/overlook-${device.replaceAll(' ','-')}-${theme}-project.png`});
  await page.locator('#session-menu').click();
  await page.locator('.actions-modal.modal-in').waitFor();
  await page.locator('.actions-button').filter({hasText:'New agent'}).click();
  await page.locator('.remote-sheet textarea').fill('Review this migration');
  await page.locator('.actions-modal').waitFor({state:'detached'});
  await page.waitForTimeout(400);
  await page.screenshot({path:`${output}/overlook-${device.replaceAll(' ','-')}-${theme}-sheet.png`});
  await page.locator('.remote-sheet').getByRole('button',{name:'Cancel',exact:true}).click();
  await page.locator('.sheet-modal').waitFor({state:'detached'});
  await page.getByText('overlook-remote.html',{exact:true}).click();
  await page.locator('.remote-sheet pre.diff').waitFor();
  await page.getByRole('button',{name:'Done',exact:true}).click();
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
  await page.locator('#text').fill('保留这个草稿');
  await page.screenshot({path:`${output}/overlook-${device.replaceAll(' ','-')}-${theme}-agent.png`});
  const header = await page.evaluate(() => {
    const rect = id => document.getElementById(id).getBoundingClientRect().toJSON();
    return {title:rect('heading'),back:rect('back'),menu:rect('session-menu')};
  });
  assert(header.title.left >= header.back.right - 1);
  assert(header.title.right <= header.menu.left + 1);
  const titleLines = await page.locator('#heading').evaluate(el=>Array.from(el.children).map(child=>child.getBoundingClientRect().toJSON()));
  assert(titleLines[0].top >= header.title.top);
  assert(titleLines[1].bottom <= header.title.bottom + 1);
  const layout=await page.evaluate(()=>{const rect=id=>{const r=document.getElementById(id).getBoundingClientRect();return {top:r.top,bottom:r.bottom,height:r.height,width:r.width}};return {compose:rect('compose'),detail:rect('detail'),text:rect('text'),height:innerHeight,body:document.body.scrollWidth,width:innerWidth};});
  console.log(device,theme,layout);
  assert(layout.compose.bottom<=layout.height+1);
  assert(layout.detail.bottom<=layout.compose.top+1);
  assert(layout.text.width>70);
  assert(layout.body<=layout.width);
  assert(await page.locator('#d-live .preloader').innerHTML());
  await page.getByRole('button',{name:'Session menu'}).click();
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
  await page.emulateMedia({reducedMotion:'reduce'});
  await group().click();
  assert.equal(await page.locator('.page-snapshot').count(),0);
  assert.deepEqual(errors,[]);
  await ctx.close();
 }
 await browser.close(); console.log('Framework7 mobile browser smoke checks passed');
})().catch(e=>{console.error(e);process.exit(1)});
