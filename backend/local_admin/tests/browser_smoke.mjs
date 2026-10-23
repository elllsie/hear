// Uses the installed Chrome and Node's built-in CDP WebSocket; no npm packages.
import {spawn} from 'node:child_process';
import {readFile,writeFile,mkdtemp} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createHash} from 'node:crypto';

const info=JSON.parse(await readFile(process.argv[2]||'/private/tmp/tinghuier-browser-info.json','utf8'));
const profile=await mkdtemp(join(tmpdir(),'tinghuier-chrome-'));
const output=process.argv[3]||'/private/tmp/tinghuier-admin-preview';
const source='backend/generated/learning-audio/v2/words/en-US/KaoYan_2/dare_1179.mp3';
const digest=data=>createHash('sha256').update(data).digest('hex');
const before=digest(await readFile(source));
const chrome=spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',[
 '--headless=new','--disable-gpu','--no-first-run','--no-default-browser-check',
 '--disable-background-networking','--disable-extensions','--remote-debugging-port=0',
 '--user-data-dir='+profile,'--window-size=1440,1050','about:blank'
],{stdio:'ignore'});
const delay=ms=>new Promise(r=>setTimeout(r,ms));
let ws;
try{
 let port;
 for(let i=0;i<120;i++){try{port=(await readFile(join(profile,'DevToolsActivePort'),'utf8')).split('\n')[0];break;}catch{await delay(200);}}
 if(!port)throw new Error('Chrome did not start');
 const targets=await (await fetch('http://127.0.0.1:'+port+'/json/list')).json();
 const target=targets.find(t=>t.type==='page');
 ws=new WebSocket(target.webSocketDebuggerUrl);
 await new Promise((resolve,reject)=>{ws.addEventListener('open',resolve,{once:true});ws.addEventListener('error',reject,{once:true});});
 let seq=0;const pending=new Map();const errors=[];
 ws.addEventListener('message',e=>{const m=JSON.parse(e.data);if(m.id&&pending.has(m.id)){const [resolve,reject]=pending.get(m.id);pending.delete(m.id);if(m.error)reject(new Error(m.error.message));else resolve(m.result);}if(m.method==='Runtime.exceptionThrown')errors.push(m.params.exceptionDetails.exception?.description||m.params.exceptionDetails.text);});
 const send=(method,params={})=>new Promise((resolve,reject)=>{const id=++seq;pending.set(id,[resolve,reject]);ws.send(JSON.stringify({id,method,params}));});
 const evaluate=async expression=>{const result=await send('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true,userGesture:true});if(result.exceptionDetails)throw new Error(result.exceptionDetails.exception?.description||result.exceptionDetails.text);return result.result.value;};
 const wait=async(expression,timeout=15000)=>{const start=Date.now();while(Date.now()-start<timeout){if(await evaluate(expression))return;await delay(150);}throw new Error('Timeout waiting for '+expression);};
 const click=async selector=>{await wait(`!!document.querySelector(${JSON.stringify(selector)})`);await evaluate(`document.querySelector(${JSON.stringify(selector)}).click()`);};
 const fill=async(selector,value)=>evaluate(`(()=>{const el=document.querySelector(${JSON.stringify(selector)});el.value=${JSON.stringify(value)};el.dispatchEvent(new Event('input',{bubbles:true}));el.dispatchEvent(new Event('change',{bubbles:true}));})()`);
 const route=async name=>{await evaluate(`location.hash=${JSON.stringify(name)}`);await wait(`document.querySelector('#content h1') && !document.querySelector('#content .loading')`);await delay(250);};
 const screenshot=async name=>{const result=await send('Page.captureScreenshot',{format:'png',captureBeyondViewport:false});await writeFile(output+'-'+name+'.png',Buffer.from(result.data,'base64'));};
 await send('Page.enable');await send('Runtime.enable');
 await send('Emulation.setDeviceMetricsOverride',{width:1440,height:1050,deviceScaleFactor:1,mobile:false});
 await send('Page.navigate',{url:info.url+'/#login='+info.token});
 await wait(`!document.querySelector('#app').hidden && document.querySelector('#content h1')`);
 await screenshot('overview');
 console.log('PASS automatic local login and dashboard');
 await route('words');await wait(`!!document.querySelector('#word-search')`);
 await fill('#word-search','dare');await wait(`document.querySelector('td.word-text')?.textContent.startsWith('dare') && document.querySelectorAll('tbody tr').length===1`);
 await click('[data-action="listen-word"]');await click('[data-action="load-audio"][data-version="local"]');
 await wait(`!!document.querySelector('audio')`);await wait(`document.querySelector('audio').readyState>=2`);
 console.log('PASS word search and local audio decoding');
 await click('[data-action="generate-specific"]');
 await evaluate(`document.querySelector('#generate-form').requestSubmit()`);
 await wait(`document.querySelector('#modal-title').textContent.includes('生成') && !!document.querySelector('#job-log')`);
 await wait(`!!document.querySelector('.publish-check')`,60000);
 await screenshot('audio-review');
 await click('[data-job][data-action="load-audio"]');await wait(`document.querySelector('audio')?.readyState>=2`);
 if(digest(await readFile(source))!==before)throw new Error('Draft generation modified canonical audio');
 console.log('PASS actual Kokoro generation, draft isolation and preview playback');
 await click('[data-action="close-modal"]');
 await click('[data-action="flag-word"]');await fill('#flag-form textarea','浏览器验收：待人工试听');await evaluate(`document.querySelector('#flag-form').requestSubmit()`);await wait(`!document.querySelector('#modal').open`);
 await route('flags');await wait(`document.querySelector('#content').textContent.includes('浏览器验收')`);
 console.log('PASS persistent review flags');
 await route('words');await click('[data-action="import-book"]');
 const imported=join(profile,'book.json');await writeFile(imported,JSON.stringify([{id:'1',text:'example',meaningZh:'n. 例子',meaningEn:'n. an illustration'}]));
 await fill('#import-form input[name="id"]','Browser_Test');await fill('#import-form input[name="title"]','浏览器验收词书');
 const doc=await send('DOM.getDocument');const node=await send('DOM.querySelector',{nodeId:doc.root.nodeId,selector:'#book-file'});await send('DOM.setFileInputFiles',{nodeId:node.nodeId,files:[imported]});
 await click('[data-action="preview-import"]');await wait(`document.querySelector('#import-preview').textContent.includes('校验通过')`);
 await evaluate(`document.querySelector('#import-form').requestSubmit()`);await wait(`!document.querySelector('#modal').open && document.querySelector('.book-title').textContent.includes('浏览器验收词书')`);
 console.log('PASS JSON validation, preview and import');
 await route('articles');await wait(`!!document.querySelector('#article-form')`);
 await fill('#article-form input[name="title"]','浏览器测试文章');await fill('#article-form textarea','Learning a language takes patience and practice. A short daily routine makes useful progress over time.');await evaluate(`document.querySelector('#article-form').requestSubmit()`);
 await wait(`document.querySelector('.source-item')?.textContent.includes('浏览器测试文章')`);
 console.log('PASS article local save (no paid AI calls)');
 await route('podcasts');await wait(`!!document.querySelector('[data-action="new-source"]')`);await click('[data-action="new-source"]');
 await fill('#source-form input[name="key"]','browser_source');await fill('#source-form input[name="name"]','Browser Test Podcast');await fill('#source-form input[name="rss_url"]','https://example.invalid/feed.xml');await evaluate(`document.querySelector('#source-form').requestSubmit()`);
 await wait(`!document.querySelector('#modal').open && document.querySelector('.source-item.active')?.textContent.includes('Browser Test Podcast')`);
 console.log('PASS podcast source management (no cloud mutation)');
 await route('settings');await wait(`document.querySelector('#content').textContent.includes('服务连接')`);
 console.log('PASS settings page');
 await route('jobs');await wait(`document.querySelector('#job-list')?.textContent.includes('生成')`);
 await screenshot('jobs');
 await route('words');await wait(`!!document.querySelector('#word-search')`);
 await send('Emulation.setDeviceMetricsOverride',{width:740,height:950,deviceScaleFactor:1,mobile:false});await delay(300);
 const overflow=await evaluate(`document.documentElement.scrollWidth>window.innerWidth`);if(overflow)throw new Error('Narrow viewport overflows');await screenshot('narrow');
 if(errors.length)throw new Error('Browser errors: '+errors.join('\n'));
 console.log('PASS narrow viewport and no uncaught JavaScript errors');
 console.log('Browser acceptance complete. Screenshots saved to '+output+'-*.png');
}finally{if(ws)ws.close();chrome.kill('SIGTERM');}
