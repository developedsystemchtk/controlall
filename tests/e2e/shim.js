// Minimal PostgREST emulator: POST /rest/v1/rpc/<fn> with JSON body of named params, executed as role "anon".
const http = require('http');
const { Client } = require('pg');
const TYPES = { p_payload: 'jsonb', p_map: 'jsonb', p_remember: 'boolean' };
async function start(port = 54321) {
  const db = new Client({ host: '127.0.0.1', user: 'postgres', password: 'pgtest', database: 'afdb' });
  await db.connect();
  const calls = [];
  const server = http.createServer((req, res) => {
    let raw = '';
    req.on('data', c => raw += c);
    req.on('end', async () => {
      const send = (code, obj) => { res.writeHead(code, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(obj)); };
      try {
        const m = req.url.match(/^\/rest\/v1\/rpc\/([a-z_]+)$/);
        if (req.method !== 'POST' || !m) return send(404, { message: 'not found' });
        if (!req.headers['apikey']) return send(401, { message: 'No API key found in request' });
        const fn = m[1];
        const body = raw ? JSON.parse(raw) : {};
        const keys = Object.keys(body);
        // verify function exists with exactly these named params (like PostgREST schema cache would)
        const sig = await db.query(`select p.proargnames from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname=$1`, [fn]);
        if (!sig.rows.length) return send(404, { code: 'PGRST202', message: 'Could not find the function public.' + fn });
        const names = sig.rows[0].proargnames || [];
        const unknown = keys.filter(k => !names.includes(k));
        if (unknown.length) return send(404, { code: 'PGRST202', message: `Could not find the function public.${fn}(${keys.join(', ')}) in the schema cache` });
        const args = keys.map((k, i) => `${k} => $${i + 1}::${TYPES[k] || 'text'}`).join(', ');
        const vals = keys.map(k => (TYPES[k] === 'jsonb' ? JSON.stringify(body[k]) : body[k]));
        await db.query('begin'); await db.query('set local role anon');
        let r;
        try { r = await db.query(`select public.${fn}(${args}) as r`, vals); await db.query('commit'); }
        catch (e) { await db.query('rollback'); throw e; }
        calls.push(fn);
        send(200, r.rows[0].r);
      } catch (e) { send(400, { message: e.message }); }
    });
  });
  await new Promise(r => server.listen(port, '127.0.0.1', r));
  return { server, db, calls, close: async () => { server.close(); await db.end(); } };
}
module.exports = { start };
