const fs = require('fs'); const { Client } = require('pg');
const html = fs.readFileSync(require('path').join(__dirname, '..', '..', 'index.html'), 'utf8');
const a = html.indexOf('const RPC_MAP = {'); const b = html.indexOf('\n    };', a) + 6;
const RPC_MAP = eval('(' + html.slice(a + 'const RPC_MAP = '.length, b).replace(/;$/, '') + ')');
(async () => {
  const db = new Client({ host: '127.0.0.1', user: 'postgres', password: 'pgtest', database: 'afdb' }); await db.connect();
  let bad = 0;
  const dummy = { loginUser: ['u', 'p', true], deleteDepartment: ['x'], deleteUser: ['x'], deleteAsset: ['x'] };
  for (const [fn, def] of Object.entries(RPC_MAP)) {
    const keys = Object.keys(def.params(...(dummy[fn] || [{}]))).concat(def.auth ? ['p_token'] : []).sort();
    const r = await db.query(`select p.proargnames, p.pronargs, p.pronargdefaults from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname=$1`, [def.rpc]);
    if (!r.rows.length) { console.log('MISSING FUNCTION', def.rpc); bad++; continue; }
    const names = (r.rows[0].proargnames||[]).slice().sort(); const required = r.rows[0].pronargs - r.rows[0].pronargdefaults;
    const extra = keys.filter(k => !names.includes(k));
    const missing = names.filter(n => !keys.includes(n)).length > r.rows[0].pronargdefaults;
    if (extra.length || missing) { console.log('MISMATCH', fn, def.rpc, 'client:', keys, 'db:', names); bad++; } else console.log('match:', fn.padEnd(20), '->', def.rpc, JSON.stringify(keys));
  }
  // does the DB expose any rpc the UI never uses, or any non-rpc function to the API roles?
  const ex = await db.query(`select p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and has_function_privilege('anon', p.oid, 'execute') and p.proname not like 'rpc\\_%'`);
  console.log('non-rpc public functions callable by anon:', ex.rows.map(r => r.proname));
  const un = await db.query(`select p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'rpc\\_%'`);
  const used = new Set(Object.values(RPC_MAP).map(d => d.rpc)); console.log('rpc in DB not used by UI:', un.rows.map(r => r.proname).filter(n => !used.has(n)));
  await db.end(); console.log(bad ? bad + ' PROBLEMS' : 'ALL 16 SIGNATURES MATCH'); process.exit(bad ? 1 : 0);
})();
