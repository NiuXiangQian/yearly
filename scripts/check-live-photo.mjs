import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { resolve, extname } from 'node:path';
// Run against a built /yearly/ frontend using synthetic fixtures only. See docs/live-photo-preview.md.
import { pathToFileURL } from 'node:url';
const [distArg, fixtureArg, playwrightModule] = process.argv.slice(2);
if (!distArg || !fixtureArg) throw new Error('Usage: node scripts/check-live-photo.mjs <dist> <synthetic-fixtures> [playwright/index.mjs]');
const dist = resolve(distArg), fixtures = resolve(fixtureArg);
const { webkit, devices } = await import(playwrightModule ? pathToFileURL(resolve(playwrightModule)).href : 'playwright');
const motion = await readFile(resolve(fixtures, 'motion.mp4'));
const still = await readFile(resolve(fixtures, 'still.webp'));
const calls = { video: 0, original: 0 };
const media = { id: 1, kind: 'media', media_type: 'live_photo', title: '合成实况预览', taken_at_local: '2026-11-08T10:00:00', time_source:'exif', timeline_date:'2026-11-08', child_ids:[], children:[], tags:[], files: [{id:2,file_role:'original',mime_type:'image/heic',file_size:3000000},{id:3,file_role:'live_video',mime_type:'video/quicktime',file_size:6000000}] };
const data = { share: {title:'合成素材验收', start_date:'2026-11-08', end_date:'2026-11-08', expires_at:new Date(Date.now()+3600000).toISOString()}, dates:['2026-11-08'], days:[{day:'2026-11-08',total:1,items:[media]}], next_before:null };
const server=createServer(async(req,res)=>{
 try {
  const url=new URL(req.url,'http://localhost');
  const path=url.pathname.replace(/^\/yearly/,'');
  if(path.startsWith('/api/')) {
    let value=data;
    if(path.endsWith('/auth/me')) value={id:1,role:'member',username:'mock',csrf_token:'mock'};
    else if(path.endsWith('/children')) value=[];
    else if(path.endsWith('/stats')) value={media:1,children:0,people:0,pets:0,events:0,bytes:9000000};
    else if(path==='/api/media/1') value=media;
    else if(path==='/api/timeline') value={items:[media],total:1,next_cursor:null};
    else if(path.endsWith('/url')) {
      if(url.searchParams.get('purpose')==='original') calls.original++;
      value={url:url.searchParams.get('live')==='true'||path.includes('/files/3/')?'/motion.mp4':'/still.webp',status:'ready'};
    }
    res.writeHead(200,{'content-type':'application/json'}).end(JSON.stringify(value));
  } else if(path==='/motion.mp4') {
    calls.video++;
    const headers={'content-type':'video/mp4','accept-ranges':'bytes'};
    const match=/^bytes=(\d+)-(\d*)$/.exec(req.headers.range||'');
    if(match){const start=+match[1],end=Math.min(match[2]?+match[2]:motion.length-1,motion.length-1); res.writeHead(206,{...headers,'content-range':`bytes ${start}-${end}/${motion.length}`,'content-length':end-start+1}).end(motion.subarray(start,end+1));}
    else res.writeHead(200,{...headers,'content-length':motion.length}).end(motion);
  } else if(path==='/still.webp') res.writeHead(200,{'content-type':'image/webp'}).end(still);
  else {const file=path.startsWith('/assets/')?resolve(dist,'.'+path):resolve(dist,'index.html');res.writeHead(200,{'content-type':{'.html':'text/html','.js':'text/javascript','.css':'text/css'}[extname(file)]||'application/octet-stream'}).end(await readFile(file));}
 } catch(e){res.writeHead(500).end(String(e));}
});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const browser=await webkit.launch();
try {
 for(const mobile of [true,false]) {
  const page=await browser.newPage(mobile?devices['iPhone 13']:{viewport:{width:1440,height:1000}});
  const errors=[];page.on('pageerror',e=>errors.push(e.message));
  for(const shared of [true,false]) {
   const before=calls.video;
   await page.goto(`http://127.0.0.1:${server.address().port}/yearly/${shared?'share/mock':''}`);
   await page.locator(shared?'.shared-card':'.media-card').first().click();
   await page.locator('.live-photo-img').waitFor();
   // Desktop hover may start once a modal appears under its cursor; move to the toolbar.
   await page.mouse.move(0,0);
   if(mobile) assert.equal(calls.video,before,'no video preload');
   await page.getByRole('button',{name:'播放实况',exact:true}).click();
   await page.locator('.live-photo.is-playing').waitFor();
   await page.waitForFunction(()=>document.querySelector('.live-photo-video').currentTime>0.05);
   assert.equal(await page.locator('.live-photo-video').evaluate(v=>v.muted),true);
   await page.getByRole('button',{name:'取消静音',exact:true}).click();
   assert.equal(await page.locator('.live-photo-video').evaluate(v=>v.muted),false);
   await page.locator('.live-photo.is-playing').waitFor({state:'detached'});
   assert.equal(await page.locator('.live-photo-img').getAttribute('src'),'/still.webp');
   assert.equal(calls.original,0);
   if(!shared) {
    await page.getByRole('button',{name:'全屏预览',exact:true}).click();
    await page.locator('.media-viewer-shell.expanded').waitFor();
    await page.getByRole('button',{name:'退出全屏',exact:true}).focus();
    assert.equal(await page.getByRole('button',{name:'退出全屏',exact:true}).evaluate(el=>document.activeElement===el),true,'fullscreen keyboard focus');
    await page.screenshot({path:resolve(fixtures, `yearly-live-${mobile?'iphone':'desktop'}.png`)});
    await page.getByRole('button',{name:'退出全屏',exact:true}).click();
    await page.locator('.media-viewer-shell.expanded').waitFor({state:'detached'});
    await page.getByRole('button',{name:'静态照片',exact:true}).click();
    await page.locator('.image-pan img').waitFor();
   }
   assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth+1),false);
  }
  assert.deepEqual(errors,[]);await page.close();
 }
 console.log('WebKit iPhone + desktop: private/shared previews, real MP4 playback, no mobile preload, mute toggle, return to still, fullscreen exit, still zoom mode, subpath API and no overflow passed.');
} finally {await browser.close();await new Promise(r=>server.close(r));}
