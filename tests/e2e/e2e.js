const fs = require('fs');
const { JSDOM, VirtualConsole } = require('jsdom');
const { start } = require('./shim');
const html = fs.readFileSync(require('path').join(__dirname, '..', '..', 'index.html'), 'utf8');

let failed = 0;
const ok = (c, label, extra = '') => { if (c) console.log('pass:', label); else { failed++; console.log('FAIL:', label, extra); } };
const sleep = ms => new Promise(r => setTimeout(r, ms));

(async () => {
  const sh = await start();
  const errors = [], alerts = [];
  const vc = new VirtualConsole();
  vc.on('jsdomError', e => errors.push('jsdomError: ' + (e.detail && e.detail.message || e.message)));
  vc.on('error', (...a) => errors.push('console.error: ' + a.map(String).join(' ').slice(0, 300)));
  const dom = new JSDOM(html, {
    url: 'http://localhost:8080/', runScripts: 'dangerously', pretendToBeVisual: true, virtualConsole: vc,
    beforeParse(w) {
      w.fetch = (u, o) => fetch(u, o);
      w.APP_CONFIG = { SUPABASE_URL: 'http://127.0.0.1:54321', SUPABASE_KEY: 'sb_publishable_test' };
      w.lucide = { createIcons() {} };
      w.Chart = function () { this.destroy = () => {}; this.update = () => {}; };
      w.alert = m => alerts.push(String(m)); w.confirm = () => true; w.prompt = () => '';
      w.matchMedia = () => ({ matches: false, addListener() {}, removeListener() {}, addEventListener() {}, removeEventListener() {} });
      w.IntersectionObserver = w.ResizeObserver = class { observe() {} unobserve() {} disconnect() {} };
      w.addEventListener('error', e => errors.push('window.error: ' + e.message));
      w.addEventListener('unhandledrejection', e => errors.push('unhandledrejection: ' + (e.reason && e.reason.message || e.reason)));
    }
  });
  const w = dom.window, $ = id => w.document.getElementById(id);
  const ev = code => w.eval(code);
  const login = async (u, p) => { $('login-username').value = u; $('login-password').value = p; await w.handleLogin(); await sleep(150); };
  const call = (fn, ...a) => w.callBackend(fn, ...a);
  const visibleRoutes = () => ev('getNavItems().filter(i=>i.id).map(i=>i.id)');

  await sleep(600); // DOMContentLoaded -> getPublicBranding
  ok($('auth-app-title').textContent === 'ระบบยืม-คืนครุภัณฑ์', 'login screen title rebranded', $('auth-app-title').textContent);
  ok($('auth-app-subtitle').textContent === 'โรงพยาบาลสันทราย', 'login subtitle = โรงพยาบาลสันทราย', $('auth-app-subtitle').textContent);
  ok(w.document.title.includes('โรงพยาบาลสันทราย') && !/assetflow/i.test(w.document.title), 'document.title rebranded', w.document.title);
  ok($('reg-dept').options.length >= 1 && $('reg-dept').options[0].value !== '', 'register dept list loaded from backend', $('reg-dept').innerHTML.slice(0, 120));

  // wrong login shows an error, no session
  await login('admin', 'nope'); ok(alerts.some(a => a.includes('ไม่ถูกต้อง')) && !ev('state.user'), 'bad login rejected in UI');

  // admin login
  await login('admin', 'AdminPass123');
  ok(ev('state.user && state.user.Role') === 'SuperAdmin', 'admin logged in');
  ok(ev('state.token').length === 64, 'token kept in state');
  ok(!$('app-shell').classList.contains('hidden'), 'app shell visible');
  ok($('sidebar-app-title').textContent === 'ระบบยืม-คืนครุภัณฑ์' && $('sidebar-org-name').textContent === 'โรงพยาบาลสันทราย', 'sidebar branding');
  const stored = JSON.parse(w.localStorage.getItem('sansai_asset_session_v1') || 'null');
  ok(stored && stored.token && stored.user && !('PasswordHash' in stored.user), 'session persisted without password hash');

  // seed data through the real adapter (extra "actor" arg like the original UI sends)
  const d = ev('state.data.departments'); const d1 = d[0].DeptID;
  let r = await call('saveDepartment', { DeptID: '', DeptCode: 'IT', DeptName: 'กลุ่มงานเทคโนโลยีสารสนเทศ', Status: 'Active' }, ev('state.user')); ok(r.ok, 'saveDepartment', JSON.stringify(r));
  await w.reloadAllData(); const d2 = ev("state.data.departments.find(x=>x.DeptCode==='IT').DeptID");
  const mkUser = (u, role, dept) => call('saveUser', { UserID: '', Username: u, Password: 'Passw0rd!x', FullName: 'ทดสอบ ' + u, Role: role, DepartmentID: dept, Email: '', Phone: '', Status: 'Active' }, ev('state.user'));
  ok((await mkUser('dadmin', 'DeptAdmin', d2)).ok, 'create DeptAdmin'); ok((await mkUser('appr', 'Approver', d1)).ok, 'create Approver'); ok((await mkUser('nurse1', 'Borrower', d1)).ok, 'create Borrower');
  const tinyJpeg = 'data:image/jpeg;base64,/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA=';
  for (const [i, nm] of ['MacBook Pro 14', 'เครื่องวัดความดัน', 'โปรเจกเตอร์'].entries()) {
    r = await call('saveAsset', { AssetID: '', AssetCode: 'EQ-' + (i + 1), SerialNo: 'SN' + i, AssetName: nm, Category: 'ทั่วไป', BrandModel: 'X', DepartmentID: i === 1 ? d2 : d1, Location: 'ห้อง ' + i, PurchaseDate: '2026-01-0' + (i + 1), Price: 1500.5 * (i + 1), Status: 'พร้อมให้ยืม', Condition: 'ดี', Notes: '', ImageUrl: '', ImageBase64: i === 0 ? tinyJpeg : '' }, ev('state.user'));
    ok(r.ok, 'saveAsset ' + nm, JSON.stringify(r));
  }
  await w.reloadAllData();
  const aid = ev("state.data.assets.find(a=>a.AssetCode==='EQ-1').AssetID");
  ok(ev("state.data.assets.find(a=>a.AssetCode==='EQ-1').ImageUrl").startsWith('data:image/jpeg'), 'image stored & returned');
  ok(typeof ev("state.data.assets[0].Price") === 'number', 'Price is a JSON number');

  // admin: every visible route renders without exceptions
  const adminRoutes = visibleRoutes().filter(x => x !== 'scanner'); ok(adminRoutes.length >= 12, 'admin sees all menus: ' + adminRoutes.length);
  for (const id of adminRoutes) { const before = errors.length; w.navigate(id); await sleep(30); ok(errors.length === before, 'admin route renders: ' + id, errors.slice(before).join(' | ')); }

  // borrower flow
  w.document.getElementById('app-shell'); await w.handleLogout(); await sleep(100);
  ok(!ev('state.user') && !$('auth-screen').classList.contains('hidden'), 'logout returns to login');
  await login('nurse1', 'Passw0rd!x'); ok(ev('state.user.Role') === 'Borrower', 'borrower logged in');
  ok(ev('state.data.users.length') === 0 && ev('state.data.logs.length') === 0, 'borrower payload has no users/logs');
  const today = new Date().toISOString().slice(0, 10), due = new Date(Date.now() + 2 * 864e5).toISOString().slice(0, 10);
  r = await call('createBorrowRequest', { AssetID: aid, BorrowDate: today, DueDate: due, Purpose: 'ทดสอบ', LocationUse: 'วอร์ด', Remarks: '' }, ev('state.user'));
  ok(r.ok && r.status === 'รออนุมัติ' && /^REQ-\d{4}-\d{4}$/.test(r.requestCode), 'borrow request', JSON.stringify(r));
  await w.reloadAllData();
  const bRoutes = visibleRoutes().filter(x => x !== 'scanner'); ok(!bRoutes.includes('users') && !bRoutes.includes('settings') && !bRoutes.includes('approvals'), 'borrower menu limited: ' + bRoutes.join(','));
  for (const id of bRoutes) { const before = errors.length; w.navigate(id); await sleep(30); ok(errors.length === before, 'borrower route renders: ' + id, errors.slice(before).join(' | ')); }
  // forged client-side role must not matter
  ev("state.user.Role='SuperAdmin'");
  r = await call('saveSettings', { AppTitle: 'hacked' }, ev('state.user')); ok(!r.ok && r.code === 'forbidden', 'forged Role in browser is ignored by server', JSON.stringify(r));
  ev("state.user.Role='Borrower'");

  // approver flow
  await w.handleLogout(); await login('appr', 'Passw0rd!x'); ok(ev('state.user.Role') === 'Approver', 'approver logged in');
  const bid = ev("state.data.borrows[0].BorrowID");
  r = await call('processBorrowAction', { BorrowID: bid, action: 'approve_handover', ConditionBefore: 'สมบูรณ์', PhotoBase64: tinyJpeg }, ev('state.user')); ok(r.ok, 'approve + handover with photo', JSON.stringify(r));
  await w.reloadAllData();
  for (const id of visibleRoutes().filter(x => x !== 'scanner')) { const before = errors.length; w.navigate(id); await sleep(30); ok(errors.length === before, 'approver route renders: ' + id, errors.slice(before).join(' | ')); }
  ok(w.document.body.innerHTML.includes('openBorrowPhoto'), 'photo link uses openBorrowPhoto (no raw data: href)');
  r = await call('processBorrowAction', { BorrowID: bid, action: 'return', ReturnDate: today, ConditionAfter: 'ปกติ', isDamaged: false, DamageDetail: '', Remarks: '', PhotoBase64: '' }, ev('state.user')); ok(r.ok, 'return asset', JSON.stringify(r));
  await w.reloadAllData(); ok(ev("state.data.borrows[0].Status") === 'คืนแล้ว', 'borrow shows คืนแล้ว');
  for (const id of ['borrow_summary', 'reports', 'dashboard']) { const before = errors.length; ev(`state.filters.summaryTab='by_asset'`); w.navigate(id); await sleep(30); ok(errors.length === before, 'post-return render: ' + id, errors.slice(before).join(' | ')); }

  // expired / tampered session
  ev("state.token='" + 'a'.repeat(64) + "'"); await call('getInitialData'); await sleep(50);
  ok(!ev('state.user') && !$('auth-screen').classList.contains('hidden'), 'invalid token -> forced back to login');
  ok(!w.localStorage.getItem('sansai_asset_session_v1') && !w.sessionStorage.getItem('sansai_asset_session_v1'), 'session cleared');

  // original-credit leftovers in rendered DOM
  ok(!/assetflow|org\.go\.th|สุรชัย/i.test(w.document.documentElement.outerHTML), 'no original credits anywhere in rendered page');

  console.log('--- distinct RPCs exercised:', [...new Set(sh.calls)].sort().join(', '));
  console.log('--- error alerts seen:', alerts.filter(a => !/ไม่ถูกต้อง|ไม่สำเร็จ|เซสชัน/.test(a)).slice(0, 5));
  console.log(failed ? `\n${failed} FAILED` : '\nE2E ALL PASSED');
  await sh.close(); process.exit(failed ? 1 : 0);
})().catch(e => { console.error('E2E CRASH', e); process.exit(2); });
