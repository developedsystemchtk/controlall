const fs = require('fs'), path = require('path');
const { JSDOM, VirtualConsole } = require('jsdom');
const html = fs.readFileSync(path.join(__dirname, '..', '..', 'index.html'), 'utf8');
const fpSrc = fs.readFileSync(path.join(__dirname, 'node_modules', 'flatpickr', 'dist', 'flatpickr.js'), 'utf8');
const fpTh = fs.readFileSync(path.join(__dirname, 'node_modules', 'flatpickr', 'dist', 'l10n', 'th.js'), 'utf8');
let failed = 0; const ok = (c, l, x = '') => { if (c) console.log('pass:', l); else { failed++; console.log('FAIL:', l, x); } };
const sleep = ms => new Promise(r => setTimeout(r, ms));
(async () => {
  const errors = [];
  const vc = new VirtualConsole(); vc.on('jsdomError', e => errors.push(e.detail && e.detail.message || e.message));
  const dom = new JSDOM(html, { url: 'http://localhost:8080/', runScripts: 'dangerously', pretendToBeVisual: true, virtualConsole: vc,
    beforeParse(w) {
      w.fetch = () => Promise.reject(new Error('offline')); w.APP_CONFIG = { SUPABASE_URL: 'http://127.0.0.1:1', SUPABASE_KEY: 'x' };
      w.lucide = { createIcons() {} }; w.alert = () => {}; w.confirm = () => true;
      w.matchMedia = () => ({ matches: false, addListener() {}, removeListener() {}, addEventListener() {}, removeEventListener() {} });
      w.IntersectionObserver = w.ResizeObserver = class { observe() {} unobserve() {} disconnect() {} };
      w.eval(fpSrc); w.eval(fpTh);
      w.addEventListener('error', e => errors.push(e.message));
    } });
  const w = dom.window, $ = id => w.document.getElementById(id), ev = c => w.eval(c);
  await sleep(400); errors.length = 0;

  // helpers
  ok(ev("fmtDate('2026-11-22')") === '22/11/2026', 'fmtDate -> dd/mm/yyyy');
  ok(ev("fmtDate('2026-11-22', true)") === '22/11/2569', 'fmtDate (พ.ศ. option)');
  ok(ev("fmtDateTime('2026-11-22 14:05:33')") === '22/11/2026 14:05', 'fmtDateTime -> dd/mm/yyyy HH:MM (24h, no seconds)');
  ok(ev("fmtDateTime('2026-11-22 00:07:00')") === '22/11/2026 00:07', 'midnight stays 00:07 (not 12:07 AM)');
  ok(ev("fmtDateTime('2026-11-22 23:59:00')") === '22/11/2026 23:59', '23:59 stays 24-hour');
  ok(ev("fmtDate('')") === '-' && ev("fmtDate(null)") === '-', 'empty date -> "-"');
  ok(ev("fmtThaiDate('2026-01-05')") === '05/01/2569', 'official documents: dd/mm/yyyy (พ.ศ.)');

  const ISO = /\b\d{4}-\d{2}-\d{2}\b/, AMPM = /\b(AM|PM|am|pm)\b/;
  for (const [un, role] of [['admin', 'SuperAdmin'], ['phatsadu', 'DeptAdmin'], ['approver', 'Approver'], ['nurse1', 'Borrower']]) {
    await w.startDemo(un); await sleep(150);
    const routes = ev('getNavItems().filter(i=>i.id).map(i=>i.id)').filter(x => x !== 'scanner');
    let bad = [];
    for (const id of routes) {
      w.navigate(id); await sleep(25);
      const txt = $('main-content').textContent;
      if (ISO.test(txt)) bad.push(id + ':' + (txt.match(ISO) || [])[0]);
      if (AMPM.test(txt)) bad.push(id + ':AMPM');
    }
    ok(bad.length === 0, `${role}: no ISO dates / AM-PM on any screen (${routes.length} routes)`, bad.join(', '));
  }

  // activity log timestamps + dashboard
  await w.startDemo('admin'); await sleep(100); w.navigate('dashboard'); await sleep(40);
  ok(/\d{2}\/\d{2}\/\d{4} \d{2}:\d{2}/.test($('main-content').textContent), 'dashboard feed shows dd/mm/yyyy HH:MM');

  // date pickers: visible dd/mm/yyyy, hidden value stays ISO for the app's readers
  const aid = ev("state.data.assets.find(a=>a.Status==='พร้อมให้ยืม').AssetID");
  w.openBorrowModal(aid); await sleep(80);
  const start = $('brw-start'); const alt = start._flatpickr && start._flatpickr.altInput;
  ok(start._flatpickr, 'borrow date input upgraded to date picker');
  ok(/^\d{4}-\d{2}-\d{2}$/.test(start.value), 'real input keeps ISO value', start.value);
  ok(alt && /^\d{2}\/\d{2}\/\d{4}$/.test(alt.value), 'visible input shows dd/mm/yyyy', alt && alt.value);
  ok(ev("document.getElementById('brw-start').value") === ev('todayStr(0)'), 'submit code still reads today as ISO');
  start._flatpickr.setDate('2026-12-31', true); await sleep(20);
  ok(start.value === '2026-12-31' && alt.value === '31/12/2026', 'typing/choosing a date updates both (ISO + dd/mm/yyyy)');
  ok(!ISO.test($('modal-panel').textContent), 'borrow modal text has no ISO dates', ($('modal-panel').textContent.match(ISO)||[])[0]);
  w.closeModal();
  w.openAssetDetailModal(aid); await sleep(60);
  ok(!ISO.test($('modal-panel').textContent) && !AMPM.test($('modal-panel').textContent), 'asset detail modal has no ISO dates / AM-PM', ($('modal-panel').textContent.match(ISO)||[])[0]);
  w.closeModal();


  // more modals + printed documents
  await w.startDemo('admin'); await sleep(120);
  const bidA = ev("state.data.borrows.find(b=>b.Status==='อนุมัติแล้ว').BorrowID"), bidP = ev("state.data.borrows.find(b=>b.Status==='รออนุมัติ').BorrowID"), bidR = ev("state.data.borrows.find(b=>b.Status==='กำลังยืม').BorrowID");
  const modalChecks = [
    ['approve+handover', () => w.openApproveHandoverModal(bidP)], ['handover', () => w.openHandoverModal(bidA)], ['return', () => w.openReturnModal(bidR)],
    ['asset form', () => w.openAssetFormModal(aid)], ['maintenance', () => w.openMaintenanceModal(null, aid)], ['disposal', () => w.openDisposeModal(aid)],
    ['borrow form print', () => w.printBorrowForm(bidR)], ['official report', () => { w.navigate('reports'); w.openOfficialReportPreview && w.openOfficialReportPreview(new w.Event('x')); }]
  ];
  for (const [name, fn] of modalChecks) {
    try { fn(); await sleep(80); } catch (e) { errors.push(name + ': ' + e.message); }
    const txt = ($('modal-panel') ? $('modal-panel').textContent : '') + ($('print-area') ? $('print-area').textContent : '');
    ok(!ISO.test(txt) && !AMPM.test(txt), `${name}: no ISO dates / AM-PM`, (txt.match(ISO) || [])[0]);
    if (name === 'return') { const rd = $('ret-date'); ok(rd && rd._flatpickr && /^\d{2}\/\d{2}\/\d{4}$/.test(rd._flatpickr.altInput.value), 'return date picker shows dd/mm/yyyy'); }
    if (name === 'borrow form print') ok(/\d{2}\/\d{2}\/25\d{2}/.test(txt), 'printed borrow form dates are dd/mm/yyyy (พ.ศ.)', txt.slice(0,120));
    try { w.closeModal(); } catch (e) {}
  }

  // Excel export rows
  const rows = ev("exportRows(state.data.borrows.slice(0,2)).map(r=>[r.BorrowDate,r.DueDate,r.CreatedAt])");
  ok(rows.every(r => /^\d{2}\/\d{2}\/\d{4}$/.test(r[0]) && /^\d{2}\/\d{2}\/\d{4}$/.test(r[1]) && /^\d{2}\/\d{2}\/\d{4} \d{2}:\d{2}$/.test(r[2])), 'Excel export uses dd/mm/yyyy and HH:MM', JSON.stringify(rows));
  ok(ev("exportRows([{ImageUrl:'data:image/jpeg;base64,AAAA'}])[0].ImageUrl") === '(มีรูปภาพแนบในระบบ)', 'Excel export no longer embeds base64 images in cells');
  ok(errors.length === 0, 'no runtime errors', errors.join(' | '));
  console.log(failed ? `\n${failed} FAILED` : '\nDATES E2E ALL PASSED'); process.exit(failed ? 1 : 0);
})().catch(e => { console.error('CRASH', e); process.exit(2); });
