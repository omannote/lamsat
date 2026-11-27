// إقفال الوردية: النقد المتوقع والفعلي، فرق الصندوق وقيده، الصلاحيات، ومنع البيع بعد الإقفال، وتدوير اليوم المحاسبي.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { startDb, ID, uuid, expectCode } from '../harness.mjs';

let db, s1;
const sale = (session, product, qty, price, payments, total, extra = {}) => ({
  cash_session_id: session, lines: [{ product_id: product, qty, unit_price_baisa: price, discount_baisa: 0 }],
  payments, expected_total_baisa: total, ...extra });
const one = async (q, p) => (await db.sql(q, p))[0];

before(async () => {
  db = await startDb();
  await db.rpc(ID.owner, 'update_branch_settings', [ID.tyr, { shift_roles: ['cashier', 'branch_manager'] }]);
  s1 = (await db.rpc(ID.cashierTyr, 'open_cash_session', [uuid(), ID.devTyr1, 20000])).session.id;
  await db.rpc(ID.cashierTyr, 'approve_sale', [uuid(), sale(s1, ID.tireMI, 1, 34500, [{ method: 'cash', amount_baisa: 34500 }], 34500, { cash_tendered_baisa: 50000 })]);
  await db.rpc(ID.cashierTyr, 'approve_sale', [uuid(), sale(s1, ID.install, 2, 1000,
    [{ method: 'cash', amount_baisa: 500 }, { method: 'card', amount_baisa: 1500, card_reference: 'A1' }], 2000)]);
  await db.rpc(ID.cashierTyr, 'approve_sale', [uuid(), sale(s1, ID.tireMI, 2, 34500, [{ method: 'card', amount_baisa: 69000 }], 69000)]);
});
after(async () => { await db.stop(); });

test('مراجعة الإقفال: المتوقع = الافتتاحي + النقد، والبطاقة منفصلة', async () => {
  const s = await db.rpc(ID.cashierTyr, 'cash_session_summary', [s1]);
  assert.deepEqual([s.opening_cash_baisa, s.cash_sales_baisa, s.expected_cash_baisa, s.card_baisa, s.invoice_count, s.total_sales_baisa, s.status],
    [20000, 35000, 55000, 70500, 3, 105500, 'open']);
  await expectCode(db.rpc(ID.cashierTnt, 'cash_session_summary', [s1]), 'NOT_FOUND');
});

test('الصلاحيات والتحقق: كاشير فرع آخر، محاسب، مبلغ سالب، فرق بلا سبب', async () => {
  await expectCode(db.rpc(ID.cashierTnt, 'close_cash_session', [uuid(), s1, 55000, null]), 'FORBIDDEN');
  await expectCode(db.rpc(ID.accountant, 'close_cash_session', [uuid(), s1, 55000, null]), 'FORBIDDEN');
  await expectCode(db.rpc(ID.cashierTyr, 'close_cash_session', [uuid(), s1, -1, null]), 'INVALID_AMOUNT');
  const e = await expectCode(db.rpc(ID.cashierTyr, 'close_cash_session', [uuid(), s1, 54000, '  ']), 'CLOSE_NOTE_REQUIRED');
  assert.equal(JSON.parse(e.detail).difference_baisa, -1000);
  assert.equal((await one('select status from cash_sessions where id=$1', [s1])).status, 'open');
});

test('إقفال بعجز: يُحفظ الفرق وقيده، ويُعاد الطلب المكرر بلا أثر ثانٍ، ويُرفض البيع بعده', async () => {
  const op = uuid();
  const r = await db.rpc(ID.cashierTyr, 'close_cash_session', [op, s1, 54000, 'نقص في الفكة']);
  assert.equal(r.status, 'closed');
  assert.deepEqual([r.summary.expected_cash_baisa, r.summary.counted_cash_baisa, r.summary.difference_baisa, r.summary.card_baisa, r.summary.status],
    [55000, 54000, -1000, 70500, 'closed']);
  const again = await db.rpc(ID.cashierTyr, 'close_cash_session', [op, s1, 54000, 'نقص في الفكة']);
  assert.equal(again.replayed, true);
  await expectCode(db.rpc(ID.cashierTyr, 'close_cash_session', [op, s1, 55000, 'x']), 'OPERATION_MISMATCH');
  await expectCode(db.rpc(ID.cashierTyr, 'close_cash_session', [uuid(), s1, 54000, 'x']), 'SESSION_CLOSED');

  const j = await db.sql(`select a.system_key k, l.debit_baisa d, l.credit_baisa c from journal_lines l join journal_entries e on e.id=l.entry_id
    join accounts a on a.id=l.account_id where e.source_type='cash_session' and e.source_id=$1 order by a.code`, [s1]);
  assert.deepEqual(j.map((x) => [x.k, x.d, x.c]), [['cash_on_hand', 0, 1000], ['cash_over_short', 1000, 0]]);
  assert.equal(Number((await one(`select count(*) n from audit_log where entity_id=$1 and action='cash_session.close' and reason='نقص في الفكة'`, [s1])).n), 1);

  await expectCode(db.rpc(ID.cashierTyr, 'approve_sale', [uuid(), sale(s1, ID.install, 1, 1000, [{ method: 'cash', amount_baisa: 1000 }], 1000)]), 'SESSION_CLOSED');
  // حتى الإدراج المباشر من خارج الدوال يُرفض
  await assert.rejects(db.sql(`insert into invoices (organization_id, branch_id, invoice_no, seq, business_day_id, cash_session_id, device_id, cashier_id,
    tax_rate_bp, prices_include_tax, subtotal_baisa, discount_baisa, net_baisa, tax_baisa, total_baisa, paid_baisa, operation_id)
    select organization_id, branch_id, 'X-1', 999, business_day_id, id, device_id, opened_by, 0, true, 1, 0, 1, 0, 1, 1, gen_random_uuid() from cash_sessions where id=$1`, [s1]), /SESSION_CLOSED/);
});

test('وردية ثانية في اليوم نفسه على اليوم المحاسبي ذاته، والمدير يقفل وردية الكاشير بزيادة', async () => {
  const r = await db.rpc(ID.cashierTyr, 'open_cash_session', [uuid(), ID.devTyr1, 54000]);
  const d1 = (await one('select business_day_id d from cash_sessions where id=$1', [s1])).d;
  assert.equal(r.session.business_day_id, d1);
  assert.equal(Number((await one('select count(*) n from business_days where branch_id=$1', [ID.tyr])).n), 1);
  const c = await db.rpc(ID.manager, 'close_cash_session', [uuid(), r.session.id, 54200, 'زيادة 200 بيسة']);
  assert.equal(c.summary.difference_baisa, 200);
  const j = await db.sql(`select a.system_key k, l.debit_baisa d from journal_lines l join journal_entries e on e.id=l.entry_id
    join accounts a on a.id=l.account_id where e.source_id=$1 and l.debit_baisa>0`, [r.session.id]);
  assert.deepEqual(j.map((x) => [x.k, x.d]), [['cash_on_hand', 200]]);
  // إقفال مطابق لا ينشئ قيدًا ولا يتطلب سببًا
  const r3 = await db.rpc(ID.cashierTyr, 'open_cash_session', [uuid(), ID.devTyr1, 1000]);
  await db.rpc(ID.cashierTyr, 'close_cash_session', [uuid(), r3.session.id, 1000, null]);
  assert.equal(Number((await one(`select count(*) n from journal_entries where source_id=$1`, [r3.session.id])).n), 0);
});

test('تدوير اليوم المحاسبي: يوم سابق بلا ورديات مفتوحة يُقفل ويُفتح يوم جديد؛ ومع وردية مفتوحة يبقى', async () => {
  await db.sql(`update business_days set business_date = business_date - 1 where branch_id=$1`, [ID.tyr]);
  const old = (await one('select id from business_days where branch_id=$1', [ID.tyr])).id;
  // جهاز 2 يفتح: لا ورديات مفتوحة على اليوم القديم ← يوم جديد
  const a = await db.rpc(ID.manager, 'open_cash_session', [uuid(), ID.devTyr2, 0]);
  assert.notEqual(a.session.business_day_id, old);
  assert.equal((await one('select status from business_days where id=$1', [old])).status, 'closed');
  // نجعل اليوم الجديد «أمس» والوردية ما زالت مفتوحة (عابرة لمنتصف الليل): وردية أخرى تنضم لليوم نفسه
  await db.sql(`update business_days set business_date = business_date - 5 where id=$1`, [old]);
  await db.sql(`update business_days set business_date = business_date - 1 where id=$1`, [a.session.business_day_id]);
  const b = await db.rpc(ID.cashierTyr, 'open_cash_session', [uuid(), ID.devTyr1, 0]);
  assert.equal(b.session.business_day_id, a.session.business_day_id);
  const inv = await db.rpc(ID.cashierTyr, 'approve_sale', [uuid(), sale(b.session.id, ID.install, 1, 1000, [{ method: 'cash', amount_baisa: 1000 }], 1000)]);
  assert.equal(inv.invoice.business_date, (await one('select business_date::text d from business_days where id=$1', [a.session.business_day_id])).d);
});

test('بيع وإقفال متزامنان: المتوقع يساوي دائمًا الافتتاحي + النقد المسجّل في الوردية', async () => {
  for (let i = 0; i < 6; i++) {
    const s = (await db.rpc(ID.cashierTnt, 'open_cash_session', [uuid(), ID.devTnt, 5000])).session.id;
    const p = sale(s, ID.holder, 1, 3000, [{ method: 'cash', amount_baisa: 3000 }], 3000);
    const [sold] = await Promise.allSettled([
      db.rpc(ID.cashierTnt, 'approve_sale', [uuid(), p]),
      db.rpc(ID.cashierTnt, 'close_cash_session', [uuid(), s, 5000, 'جرد']),
      db.rpc(ID.cashierTnt, 'approve_sale', [uuid(), p]),
    ]);
    const row = await one('select expected_cash_baisa e, status from cash_sessions where id=$1', [s]);
    const cash = Number((await one(`select coalesce(sum(amount_baisa),0) c from payments where cash_session_id=$1 and method='cash'`, [s])).c);
    assert.equal(row.status, 'closed');
    assert.equal(row.e, 5000 + cash, `جولة ${i}: بيع ${sold.status}`);
  }
});

test('قائمة الورديات للإدارة ضمن الصلاحيات', async () => {
  const all = await db.rpc(ID.owner, 'list_cash_sessions', [null, '2000-01-01', '2100-01-01']);
  assert.equal(all.length, Number((await one('select count(*) n from cash_sessions')).n));
  assert.ok(all.some((x) => x.difference_baisa === -1000 && x.branch_code === 'TYR' && x.device_name));
  const mgr = await db.rpc(ID.manager, 'list_cash_sessions', [null, '2000-01-01', '2100-01-01']);
  assert.ok(mgr.length > 0 && mgr.every((x) => x.branch_code === 'TYR'));
  assert.equal((await db.rpc(ID.cashierTyr, 'list_cash_sessions', [null, '2000-01-01', '2100-01-01'])).length, 0);
});
