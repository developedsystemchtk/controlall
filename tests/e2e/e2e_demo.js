const fs = require('fs'), path = require('path');
const { JSDOM, VirtualConsole } = require('jsdom');
const html = fs.readFileSync(path.join(__dirname, '..', '..', 'index.html'), 'utf8');
let failed = 0; const ok = (c, l, x = '') => { if (c) console.log('pass:', l); else { failed++; console.log('FAIL:', l, x); } };
const sleep = ms => new Promise(r => setTimeout(r, ms));
(async () => {
  const errors = [], alerts = []; let netCalls = 0;
  const vc = new VirtualConsole(); vc.on('jsdomError', e => errors.push('jsdomError: ' + (e.detail && e.detail.message || e.message)));
  const dom = new JSDOM(html, { url: 'http://localhost:8080/', runScripts: 'dangerously', pretendToBeVisual: true, virtualConsole: vc,
    beforeParse(w) {
      w.fetch = () => { netCalls++; return Promise.reject(new Error('network disabled in demo test')); };
      w.APP_CONFIG = { SUPABASE_URL: 'http://127.0.0.1:1', SUPABASE_KEY: 'x' };
      w.lucide = { createIcons() {} }; w.alert = m => alerts.push(String(m)); w.confirm = () => true;
      w.matchMedia = () => ({ matches: false, addListener() {}, removeListener() {}, addEventListener() {}, removeEventListener() {} });
      w.IntersectionObserver = w.ResizeObserver = class { observe() {} unobserve() {} disconnect() {} };
      w.addEventListener('error', e => errors.push('window.error: ' + e.message));
      w.addEventListener('unhandledrejection', e => errors.push('unhandledrejection: ' + (e.reason && e.reason.message || e.reason)));
    } });
  const w = dom.window, $ = id => w.document.getElementById(id), ev = c => w.eval(c);
  await sleep(500); netCalls = 0; errors.length = 0; // ignore the branding fetch failure at boot
  ok(w.document.querySelector('.demo-cta'), 'login screen has demo button');
  w.openDemoPicker(); ok(w.document.querySelectorAll('.role-pick button').length === 4, 'role picker lists 4 views');

  for (const [un, role] of [['admin', 'SuperAdmin'], ['phatsadu', 'DeptAdmin'], ['approver', 'Approver'], ['nurse1', 'Borrower']]) {
    await w.startDemo(un); await sleep(200);
    ok(ev('state.user.Role') === role && ev('state.demo') === true, `demo as ${role}`);
    ok(w.document.body.classList.contains('is-demo') && !$('app-shell').classList.contains('hidden'), `banner+shell visible (${role})`);
    const routes = ev('getNavItems().filter(i=>i.id).map(i=>i.id)').filter(x => x !== 'scanner');
    for (const id of routes) { const b = errors.length; w.navigate(id); await sleep(25); ok(errors.length === b, `${role} route ${id}`, errors.slice(b).join(' | ')); }
    if (role === 'SuperAdmin') {
      w.navigate('dashboard'); await sleep(30);
      const tiles = w.document.querySelectorAll('.tile').length, live = ev("state.data.assets.filter(a=>a.Status!=='ตัดจำหน่าย').length");
      ok(tiles === live && tiles >= 40, `board has one tile per live asset (${tiles}/${live})`);
      ok(w.document.querySelectorAll('.tile.is-late').length === 2, 'two overdue tiles flagged');
      ok(w.document.querySelectorAll('.task').length >= 3, 'task list shows overdue/pending/repair');
      ok(w.document.querySelectorAll('.board-row').length === 7, 'one board row per department (7)');
      ok(!/Chart/.test(w.document.getElementById('main-content').innerHTML), 'no chart canvases');
      ok(ev('state.data.users.length') === 9 && ev('state.data.logs.length') > 5, 'admin gets users + logs');
    }
    if (role === 'Borrower') ok(ev('state.data.users.length') === 0 && ev('state.data.logs.length') === 0, 'borrower sees no users/logs in demo either');
  }

  // borrow -> approve flow inside demo, persists across role switch
  await w.startDemo('nurse1'); await sleep(100);
  const aid = ev("state.data.assets.find(a=>a.AssetCode==='EQ-001').AssetID"), n0 = ev('state.data.borrows.length');
  const today = ev('todayStr(0)'), due = ev('todayStr(2)');
  let r = await w.callBackend('createBorrowRequest', { AssetID: aid, BorrowDate: today, DueDate: due, Purpose: 'ทดสอบเดโม', LocationUse: 'x', Remarks: '' }, ev('state.user'));
  ok(r.ok, 'demo: create borrow request', JSON.stringify(r));
  await w.startDemo('approver'); await sleep(100);
  ok(ev('state.data.borrows.length') === n0 + 1, 'request visible after switching to approver');
  const bid = ev("state.data.borrows.find(b=>b.AssetCode==='EQ-001' && b.Status==='รออนุมัติ').BorrowID");
  r = await w.callBackend('processBorrowAction', { BorrowID: bid, action: 'approve_handover', ConditionBefore: 'ปกติ', PhotoBase64: '' }, ev('state.user'));
  ok(r.ok, 'demo: approve + handover', JSON.stringify(r)); await w.reloadAllData(); await sleep(50);
  ok(ev("state.data.assets.find(a=>a.AssetCode==='EQ-001').Status") === 'ถูกยืม', 'asset becomes ถูกยืม');

  // reset + exit
  await w.resetDemoData(); await sleep(100);
  ok(ev('state.data.borrows.length') === n0, 'reset restores seed data');
  w.exitDemo();
  ok(!$('auth-screen').classList.contains('hidden') && !w.document.body.classList.contains('is-demo') && !ev('state.demo'), 'exit returns to login, demo flags cleared');
  ok(!w.localStorage.getItem('sansai_asset_session_v1'), 'demo never stored a login session');
  ok(netCalls === 0, `zero network calls during entire demo run (${netCalls})`);
  console.log(failed ? `\n${failed} FAILED` : '\nDEMO E2E ALL PASSED'); process.exit(failed ? 1 : 0);
})().catch(e => { console.error('CRASH', e); process.exit(2); });
