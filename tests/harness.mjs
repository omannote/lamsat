// يشغّل PostgreSQL محليًا، يطبّق الترحيلات والبيانات التجريبية، ويوفّر تنفيذ الاستعلامات بهوية مستخدم.
import { spawn, execFileSync } from 'node:child_process';
import pg from 'pg';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

export const ID = {
  org: 'b0000000-0000-4000-8000-000000000001',
  tnt: 'c0000000-0000-4000-8000-000000000001', tyr: 'c0000000-0000-4000-8000-000000000002',
  devTnt: 'd0000000-0000-4000-8000-000000000001', devTyr1: 'd0000000-0000-4000-8000-000000000002', devTyr2: 'd0000000-0000-4000-8000-000000000003',
  owner: 'a0000000-0000-4000-8000-000000000001', manager: 'a0000000-0000-4000-8000-000000000002',
  accountant: 'a0000000-0000-4000-8000-000000000003', cashierTnt: 'a0000000-0000-4000-8000-000000000004',
  cashierTyr: 'a0000000-0000-4000-8000-000000000005',
  tireBS: 'e0000000-0000-4000-8000-000000000001', tireMI: 'e0000000-0000-4000-8000-000000000002',
  tireHK: 'e0000000-0000-4000-8000-000000000004', install: 'e0000000-0000-4000-8000-000000000011',
  balance: 'e0000000-0000-4000-8000-000000000012', holder: 'e0000000-0000-4000-8000-000000000032',
  mats: 'e0000000-0000-4000-8000-000000000031',
  customer: 'f0000000-0000-4000-8000-000000000001', vehicle: 'f1000000-0000-4000-8000-000000000001',
};
export const uuid = () => randomUUID();

export async function startDb() {
  // ثنائيات PostgreSQL تأتي من حزمة embedded-postgres (لا حاجة لتثبيت خادم). لا تعمل بحساب root.
  const plat = { linux: 'linux', darwin: 'darwin', win32: 'windows' }[process.platform];
  const bin = path.join(root, 'tests/node_modules/@embedded-postgres', `${plat}-${process.arch}`, 'native', 'bin');
  const exe = (n) => path.join(bin, process.platform === 'win32' ? `${n}.exe` : n);
  const dir = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'lamsat-pg-')), 'data');
  const port = 54000 + Math.floor(Math.random() * 1000);
  execFileSync(exe('initdb'), ['-D', dir, '-U', 'postgres', '-A', 'trust', '-E', 'UTF8', '--no-locale'], { stdio: 'pipe' });
  const proc = spawn(exe('postgres'), ['-D', dir, '-p', String(port), '-c', 'listen_addresses=127.0.0.1',
    '-c', `unix_socket_directories=${process.platform === 'win32' ? '' : path.dirname(dir)}`, '-c', 'fsync=off'], { stdio: 'ignore' });
  const server = { stop: async () => { proc.kill('SIGINT'); await new Promise((r) => proc.once('exit', r)); fs.rmSync(path.dirname(dir), { recursive: true, force: true }); } };
  for (let i = 0; ; i++) {
    try { const c = new pg.Client({ host: '127.0.0.1', port, user: 'postgres', database: 'postgres' }); await c.connect(); await c.end(); break; }
    catch (e) { if (i > 100) throw e; await new Promise((r) => setTimeout(r, 100)); }
  }
  const pool = new pg.Pool({ host: '127.0.0.1', port, user: 'postgres', database: 'postgres', max: 10 });
  pool.on('error', () => {});
  pg.types.setTypeParser(20, (v) => Number(v));       // bigint
  pg.types.setTypeParser(1700, (v) => Number(v));     // numeric
  await pool.query(fs.readFileSync(path.join(root, 'tests/local_supabase_shim.sql'), 'utf8'));
  const migDir = path.join(root, 'supabase/migrations');
  for (const f of fs.readdirSync(migDir).sort()) await pool.query(fs.readFileSync(path.join(migDir, f), 'utf8'));
  await pool.query(fs.readFileSync(path.join(root, 'supabase/seed/10_demo_data.sql'), 'utf8'));

  /** ينفّذ fn داخل معاملة بدور authenticated وهوية المستخدم (أو anon إذا كان userId = null). */
  async function as(userId, fn) {
    const c = await pool.connect();
    try {
      await c.query('begin');
      await c.query(`set local role ${userId ? 'authenticated' : 'anon'}`);
      await c.query(`select set_config('request.jwt.claims', $1, true)`, [JSON.stringify(userId ? { sub: userId } : {})]);
      const r = await fn(c);
      await c.query('commit');
      return r;
    } catch (e) { await c.query('rollback').catch(() => {}); throw e; } finally { c.release(); }
  }
  const rpc = (userId, fn, args) => as(userId, async (c) => {
    const ph = args.map((_, i) => `$${i + 1}`).join(',');
    const r = await c.query(`select public.${fn}(${ph}) as r`, args);
    return r.rows[0].r;
  });
  const sql = (text, params) => pool.query(text, params).then((r) => r.rows);
  const stop = async () => { await pool.end(); await server.stop(); };
  return { pool, as, rpc, sql, stop };
}

/** يتوقع فشل الوعد بكود خطأ النظام (رسالة الاستثناء). */
export async function expectCode(promise, code) {
  try { await promise; } catch (e) {
    if (e.message !== code) throw new Error(`expected ${code}, got: ${e.message}`);
    return e;
  }
  throw new Error(`expected ${code}, but call succeeded`);
}
