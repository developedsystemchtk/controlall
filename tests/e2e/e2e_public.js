const fs=require('fs'),path=require('path');const {JSDOM,VirtualConsole}=require('jsdom');
const html=fs.readFileSync(path.join(__dirname,'..','..','index.html'),'utf8');
const sleep=ms=>new Promise(r=>setTimeout(r,ms));let failed=0;const ok=(c,l,x='')=>{if(c)console.log('pass:',l);else{failed++;console.log('FAIL:',l,x)}};
async function boot(url,rpc){
  const errors=[],calls=[];const vc=new VirtualConsole();vc.on('jsdomError',e=>{if(!/tailwind is not defined|Not implemented: HTMLCanvasElement/.test(e.message))errors.push(e.message)});
  const dom=new JSDOM(html,{url,runScripts:'dangerously',pretendToBeVisual:true,virtualConsole:vc,beforeParse(w){
    w.APP_CONFIG={SUPABASE_URL:'http://127.0.0.1:1',SUPABASE_KEY:'k'};w.lucide={createIcons(){}};w.alert=()=>{};
    w.fetch=(u,o)=>{calls.push({u,body:o&&o.body});if(/rpc_public_asset_lookup/.test(u))return rpc(JSON.parse(o.body));return Promise.reject(new Error('offline'))};
    w.matchMedia=()=>({matches:false,addListener(){},removeListener(){},addEventListener(){},removeEventListener(){}});
    w.IntersectionObserver=w.ResizeObserver=class{observe(){}unobserve(){}disconnect(){}};
    w.addEventListener('error',e=>{if(!/tailwind/.test(e.message))errors.push(e.message)});}});
  await sleep(350);return {w:dom.window,errors,calls,$:id=>dom.window.document.getElementById(id),ev:c=>dom.window.eval(c)};
}
const resp=j=>Promise.resolve({ok:true,status:200,json:()=>Promise.resolve(j)});
const ASSET={ok:true,asset:{AssetCode:'AST-001',AssetName:'เครื่องวัดความดัน',Category:'เครื่องมือแพทย์',BrandModel:'Omron X1',SerialNo:'SN123',DepartmentName:'ห้องฉุกเฉิน',Location:'ชั้น 1',PurchaseDate:'2024-03-05',Condition:'ดี',Status:'ถูกยืม',ImageUrl:'',UpdatedAt:'2026-11-22 14:05:00'},borrow:{Status:'กำลังยืม',BorrowerDept:'หอผู้ป่วยใน',DueDate:'2026-11-30'}};
(async()=>{
  let t=await boot('http://localhost:8080/',b=>b.p_code==='AST-001'?resp(ASSET):resp({ok:false,code:'not_found',message:'ไม่พบครุภัณฑ์รหัสนี้ในระบบ'}));
  ok(!!t.$('pub-scan-btn')&&!!t.$('auth-map'),'login has QR scan button and animated map panel');
  ok(!!t.$('pub-scan-btn').closest('#auth-screen'),'scan button sits on the login screen (no login needed)');
  ok(t.ev("parseScannedCode('https://x.app/?asset=AST-009')")==='AST-009'&&t.ev("parseScannedCode('AST-002')")==='AST-002'&&t.ev("parseScannedCode(' https://x.app/p?a=1&asset=A%2FB#z ')")==='A/B','parseScannedCode: URL, plain code, encoded');
  ok(/\?asset=AST-001$/.test(t.ev("assetQrText({AssetCode:'AST-001',QRCodeValue:'AST-001'})")),'new QR text is a link with ?asset=');
  t.w.openPublicScan();await sleep(50);
  ok(!t.$('pub-scan').classList.contains('hidden')&&!!t.$('pub-video')&&!!t.$('pub-code'),'scanner overlay opens with camera, manual code and image options');
  ok(/ปิดกล้อง|เบราว์เซอร์นี้เปิดกล้องไม่ได้|เปิดกล้อง/.test(t.$('pub-cam-msg').textContent),'camera unavailable is handled with a clear message');
  await t.w.pubLookup('https://x.app/?asset=AST-001');await sleep(30);
  const txt=t.$('pub-body').textContent;
  ok(/ถูกยืม/.test(txt)&&/AST-001/.test(txt)&&/เครื่องวัดความดัน/.test(txt)&&/ห้องฉุกเฉิน/.test(txt),'result card shows status, code, name, department');
  ok(/หอผู้ป่วยใน/.test(txt)&&/30\/11\/2026/.test(txt),'borrowed: shows borrower department + due date as dd/mm/yyyy');
  ok(t.$('pub-full').classList.contains('hidden'),'full details collapsed by default');
  t.w.pubToggleFull(t.$('pub-body').querySelector('button[aria-controls="pub-full"]'));
  const full=t.$('pub-full').textContent;ok(!t.$('pub-full').classList.contains('hidden')&&/Omron X1/.test(full)&&/SN123/.test(full)&&/05\/03\/2024/.test(full),'details expand: brand, serial, purchase date');
  ok(!/ราคา|ผู้อนุมัติ|นาย|นาง/.test(t.$('pub-body').textContent),'no price / approver / personal names on the public card');
  ok(!!t.$('pub-body').querySelector('.pub-belt'),'conveyor-belt hero present');
  ok(/เข้าสู่ระบบ/.test(t.$('pub-body').textContent),'guest gets a login call-to-action');
  ok(t.calls.length&&t.calls.every(c=>/rpc_public_asset_lookup|rpc_get_public_branding/.test(c.u)),'only public RPCs were called (no token sent)');
  ok(!t.calls.some(c=>/p_token/.test(c.body||'')),'no session token in public requests');
  await t.w.pubLookup('NOPE-1');await sleep(30);ok(/ไม่พบข้อมูล/.test(t.$('pub-body').textContent),'unknown code shows not-found');
  t.w.closePublicScan();ok(t.$('pub-scan').classList.contains('hidden'),'overlay closes');
  ok(t.errors.length===0,'no runtime errors',t.errors.join('|'));

  t=await boot('http://localhost:8080/',()=>Promise.resolve({ok:false,status:404,json:()=>Promise.resolve({message:'Could not find the function public.rpc_public_asset_lookup'})}));
  t.w.openPublicScan('AST-001');await sleep(60);
  ok(/002_public_asset_lookup\.sql/.test(t.$('pub-body').textContent),'server without the new SQL: clear instruction instead of a crash');

  t=await boot('http://localhost:8080/?asset=AST-001',b=>resp(ASSET));
  ok(!t.$('pub-scan').classList.contains('hidden')&&/AST-001/.test(t.$('pub-body').textContent),'deep link ?asset= opens the card directly');
  ok(t.calls.some(c=>/AST-001/.test(c.body||'')),'deep link looked up the right code');

  t=await boot('http://localhost:8080/',()=>Promise.reject(new Error('offline')));
  await t.w.startDemo('admin');await sleep(150);
  const r=await t.ev("callBackend('publicAssetLookup', state.data.assets[0].AssetCode)");
  ok(r.ok&&r.asset&&!('Price' in r.asset)&&!('Notes' in r.asset),'demo lookup returns the same safe field set');
  const bor=await t.ev("(async()=>{const b=state.data.borrows.find(x=>x.Status==='กำลังยืม');const a=state.data.assets.find(x=>x.AssetID===b.AssetID);return callBackend('publicAssetLookup',a.AssetCode)})()");
  ok(bor.borrow&&bor.borrow.BorrowerDept&&!('BorrowerName' in bor.borrow),'demo: borrower name is never exposed, only department');
  console.log(failed?failed+' FAILED':'PUBLIC E2E ALL PASSED');process.exit(failed?1:0);
})().catch(e=>{console.error('CRASH',e);process.exit(2)});
