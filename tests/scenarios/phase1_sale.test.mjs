// المرحلة 1 — سيناريوهات البيع، منع التكرار، التنافس على المخزون، التقريب، والصلاحيات.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { startDb, ID, uuid, expectCode } from '../harness.mjs';

let db, sTyr, sTyr2, sTnt;
const line = (product_id, qty, unit_price_baisa, discount_baisa = 0) => ({ product_id, qty, unit_price_baisa, discount_baisa });
const sale = (session, lines, payments, total, extra = {}) =>
  ({ cash_session_id: session, lines, payments, expected_total_baisa: total, ...extra });
const stock = async (branch, product) =>
  (await db.sql('select coalesce(sum(qty_on_hand),0) q from inventory_lots where branch_id=$1 and product_id=$2', [branch, product]))[0].q;
const count = async (table, where = 'true', params = []) =>
  Number((await db.sql(`select count(*) n from ${table} where ${where}`, params))[0].n);

before(async () => {
  db = await startDb();
  sTyr = (await db.rpc(ID.cashierTyr, 'open_cash_session', [uuid(), ID.devTyr1, 20000])).session.id;
  sTyr2 = (await db.rpc(ID.manager, 'open_cash_session', [uuid(), ID.devTyr2, 0])).session.id;
  sTnt = (await db.rpc(ID.cashierTnt, 'open_cash_session', [uuid(), ID.devTnt, 10000])).session.id;
});
after(async () => { await db.stop(); });

test('فتح الوردية: يوم محاسبي بتاريخ مسقط، حركة افتتاحية، ومنع وردية ثانية على الجهاز', async () => {
  const day = (await db.sql(`select business_date::text d, (now() at time zone 'Asia/Muscat')::date::text today, status
    from business_days where branch_id=$1`, [ID.tyr]))[0];
  assert.equal(day.d, day.today); assert.equal(day.status, 'open');
  assert.equal(await count('business_days', 'branch_id=$1', [ID.tyr]), 1, 'الورديتان في الفرع تتشاركان اليوم نفسه');
  assert.equal(await count('cash_movements', `cash_session_id=$1 and movement_type='opening' and amount_baisa=20000`, [sTyr]), 1);
  await expectCode(db.rpc(ID.cashierTyr, 'open_cash_session', [uuid(), ID.devTyr1, 0]), 'SESSION_ALREADY_OPEN');
  // إعادة إرسال طلب الفتح نفسه تعيد النتيجة ذاتها
  const op = uuid();
  await db.sql(`update cash_sessions set status='closed', closed_at=now() where id=$1`, [sTnt]);
  const a = await db.rpc(ID.cashierTnt, 'open_cash_session', [op, ID.devTnt, 10000]);
  const b = await db.rpc(ID.cashierTnt, 'open_cash_session', [op, ID.devTnt, 10000]);
  assert.equal(b.replayed, true); assert.equal(a.session.id, b.session.id);
  sTnt = a.session.id;
});

test('البحث: بمقاس الإطار والباركود والاسم، مع السعر النافذ للفرع والرصيد', async () => {
  const q = (branch, text, user = ID.cashierTyr) => db.as(user, (c) => c.query('select * from pos_search($1,$2)', [branch, text]).then((r) => r.rows));
  let r = await q(ID.tyr, '205/55R16');
  assert.equal(r.length, 1); assert.equal(r[0].sku, 'TR-2055516-BS'); assert.equal(r[0].stock_qty, 12); assert.equal(r[0].tire_size, '205/55R16');
  r = await q(ID.tyr, '2055516'); assert.equal(r[0].sku, 'TR-2055516-BS');
  r = await q(ID.tyr, '6291000000011'); assert.equal(r[0].exact_barcode, true); assert.equal(r[0].sku, 'TR-2055516-BS');
  r = await q(ID.tyr, 'تركيب'); assert.equal(r[0].sku, 'SV-INSTALL'); assert.equal(r[0].stock_qty, null);
  r = await q(ID.tnt, 'AC-HOLDER', ID.cashierTnt); assert.equal(r[0].unit_price_baisa, 3000, 'سعر الفرع يتقدم على سعر المنشأة');
  r = await q(ID.tyr, 'AC-HOLDER'); assert.equal(r[0].unit_price_baisa, 3500);
  await expectCode(q(ID.tyr, 'x', ID.cashierTnt), 'FORBIDDEN');
});

test('بيع أربعة إطارات مع تركيب: فاتورة، ضريبة شاملة، مخزون FIFO، قيد متوازن، صندوق، إشعار', async () => {
  const payload = sale(sTyr, [line(ID.tireBS, 4, 28000), line(ID.install, 4, 1000)],
    [{ method: 'cash', amount_baisa: 116000 }], 116000,
    { cash_tendered_baisa: 120000, customer_id: ID.customer, vehicle_id: ID.vehicle });
  const res = await db.rpc(ID.cashierTyr, 'approve_sale', [uuid(), payload]);
  assert.equal(res.status, 'approved'); assert.equal(res.replayed, false);
  const inv = res.invoice;
  assert.match(inv.invoice_no, /^TYR-\d\d-000001$/);
  assert.deepEqual([inv.subtotal_baisa, inv.discount_baisa, inv.net_baisa, inv.tax_baisa, inv.total_baisa, inv.change_baisa],
    [116000, 0, 110477, 5523, 116000, 4000]);
  assert.deepEqual(inv.lines.map((l) => [l.net_baisa, l.tax_baisa, l.total_baisa]), [[106667, 5333, 112000], [3810, 190, 4000]]);
  assert.equal(inv.customer.name, 'عميل تجريبي'); assert.equal(inv.vehicle.plate, '12345 أ ب');

  // FIFO: الدفعة الأقدم (2 × 18.000) ثم التالية (2 × 19.000)
  const lots = await db.sql(`select lot_code, qty_on_hand from inventory_lots where branch_id=$1 and product_id=$2 order by received_at`, [ID.tyr, ID.tireBS]);
  assert.deepEqual(lots.map((l) => [l.lot_code, l.qty_on_hand]), [['L-A', 0], ['L-B', 8]]);
  assert.equal((await db.sql(`select sum(qty_delta) q from stock_movements where source_id=$1 and movement_type='sale'`, [inv.id]))[0].q, -4);
  assert.equal((await db.sql(`select sum(c.cost_baisa) c from invoice_line_costs c join invoice_lines l on l.id=c.invoice_line_id where l.invoice_id=$1`, [inv.id]))[0].c, 74000);

  const j = await db.sql(`select a.system_key k, l.debit_baisa d, l.credit_baisa c from journal_lines l
    join journal_entries e on e.id=l.entry_id join accounts a on a.id=l.account_id where e.source_id=$1 order by a.code`, [inv.id]);
  assert.deepEqual(j.map((x) => [x.k, x.d, x.c]), [
    ['cash_on_hand', 116000, 0], ['inventory', 0, 74000], ['vat_output', 0, 5523],
    ['sales_goods', 0, 106667], ['sales_services', 0, 3810], ['cogs', 74000, 0]]);
  assert.equal(j.reduce((s, x) => s + x.d, 0), j.reduce((s, x) => s + x.c, 0));

  assert.equal(await count('cash_movements', `source_id=$1 and movement_type='sale' and amount_baisa=116000`, [inv.id]), 1);
  assert.equal(await count('notification_events', `invoice_id=$1 and event_type='invoice_issued' and status='pending'`, [inv.id]), 1);
  assert.equal(await count('audit_log', `entity_id=$1 and action='invoice.approve' and user_id=$2`, [inv.id, ID.cashierTyr]), 1);
});

test('الضغط المتكرر على F9 وإعادة المحاولة بعد انقطاع الرد: فاتورة واحدة وخصم مخزون واحد', async () => {
  const op = uuid();
  const payload = sale(sTyr, [line(ID.tireMI, 2, 34500)], [{ method: 'card', amount_baisa: 69000, card_reference: 'AUTH-1' }], 69000);
  const before = await stock(ID.tyr, ID.tireMI);
  // خمسة طلبات متزامنة بالمعرف نفسه
  const results = await Promise.all(Array.from({ length: 5 }, () => db.rpc(ID.cashierTyr, 'approve_sale', [op, payload])));
  assert.equal(results.filter((r) => r.replayed === false).length, 1);
  assert.equal(new Set(results.map((r) => r.invoice.id)).size, 1);
  // إعادة محاولة لاحقة (كأن الرد الأول ضاع)
  const again = await db.rpc(ID.cashierTyr, 'approve_sale', [op, payload]);
  assert.equal(again.replayed, true); assert.equal(again.invoice.id, results[0].invoice.id);
  assert.equal(await count('invoices', 'operation_id=$1', [op]), 1);
  assert.equal(await stock(ID.tyr, ID.tireMI), before - 2);
  assert.equal(await count('payments', 'invoice_id=$1', [again.invoice.id]), 1);
  // الاستعلام عن نتيجة العملية بالمعرف نفسه
  const got = await db.rpc(ID.cashierTyr, 'get_operation', [op]);
  assert.equal(got.found, true); assert.equal(got.result.invoice.invoice_no, again.invoice.invoice_no);
  assert.equal((await db.rpc(ID.cashierTyr, 'get_operation', [uuid()])).found, false);
  const recent = await db.rpc(ID.cashierTyr, 'recent_operations', [sTyr, 20]);
  assert.ok(recent.some((o) => o.operation_id === op && o.invoice_no === again.invoice.invoice_no));
  // المعرف نفسه مع طلب مختلف يُرفض
  const other = sale(sTyr, [line(ID.tireMI, 1, 34500)], [{ method: 'cash', amount_baisa: 34500 }], 34500);
  await expectCode(db.rpc(ID.cashierTyr, 'approve_sale', [op, other]), 'OPERATION_MISMATCH');
  await expectCode(db.rpc(ID.manager, 'approve_sale', [op, payload]), 'OPERATION_MISMATCH');
});

test('جهازان يبيعان آخر قطعة في الوقت نفسه: تنجح عملية واحدة فقط', async () => {
  assert.equal(await stock(ID.tyr, ID.tireHK), 1);
  const p1 = sale(sTyr, [line(ID.tireHK, 1, 19500)], [{ method: 'cash', amount_baisa: 19500 }], 19500);
  const p2 = sale(sTyr2, [line(ID.tireHK, 1, 19500)], [{ method: 'cash', amount_baisa: 19500 }], 19500);
  const r = await Promise.allSettled([
    db.rpc(ID.cashierTyr, 'approve_sale', [uuid(), p1]), db.rpc(ID.manager, 'approve_sale', [uuid(), p2])]);
  const ok = r.filter((x) => x.status === 'fulfilled'); const bad = r.filter((x) => x.status === 'rejected');
  assert.equal(ok.length, 1); assert.equal(bad.length, 1);
  assert.equal(bad[0].reason.message, 'INSUFFICIENT_STOCK');
  assert.equal(JSON.parse(bad[0].reason.detail).available, 0);
  assert.equal(await stock(ID.tyr, ID.tireHK), 0);
  assert.equal(await count('invoice_lines', 'product_id=$1', [ID.tireHK]), 1);
  // الفشل لا يترك أثرًا ولا يستهلك رقم فاتورة
  const seqs = (await db.sql('select seq from invoices where branch_id=$1 order by seq', [ID.tyr])).map((x) => x.seq);
  assert.deepEqual(seqs, seqs.map((_, i) => i + 1), 'تسلسل بلا فجوات');
});

test('دفع مختلط نقدي وبطاقة مع الباقي، ورفض عدم تطابق المدفوع', async () => {
  const lines = [line(ID.tireMI, 1, 34500), line(ID.balance, 1, 1000)];
  await expectCode(db.rpc(ID.cashierTyr, 'approve_sale', [uuid(),
    sale(sTyr, lines, [{ method: 'cash', amount_baisa: 30000 }], 35500)]), 'PAYMENT_MISMATCH');
  const res = await db.rpc(ID.cashierTyr, 'approve_sale', [uuid(), sale(sTyr, lines,
    [{ method: 'cash', amount_baisa: 15500 }, { method: 'card', amount_baisa: 20000, card_reference: 'R-778' }], 35500,
    { cash_tendered_baisa: 20000 })]);
  assert.equal(res.invoice.change_baisa, 4500);
  const j = await db.sql(`select a.system_key k, l.debit_baisa d from journal_lines l join journal_entries e on e.id=l.entry_id
    join accounts a on a.id=l.account_id where e.source_id=$1 and l.debit_baisa>0 and a.system_key in ('cash_on_hand','card_clearing') order by 1`, [res.invoice.id]);
  assert.deepEqual(j.map((x) => [x.k, x.d]), [['card_clearing', 20000], ['cash_on_hand', 15500]]);
  // الدرج يزيد بالمبلغ النقدي الصافي فقط
  assert.equal(await count('cash_movements', `source_id=$1 and amount_baisa=15500`, [res.invoice.id]), 1);
});

test('تغيّر السعر بعد الإضافة للسلة: يُعرض الفرق ولا يُحفظ شيء حتى يؤكد الكاشير', async () => {
  const op = uuid();
  await db.sql(`update products set base_price_baisa=13000 where id=$1`, [ID.mats]);
  const invBefore = await count('invoices');
  const stale = sale(sTnt, [line(ID.mats, 1, 12000)], [{ method: 'cash', amount_baisa: 12000 }], 12000);
  const r1 = await db.rpc(ID.cashierTnt, 'approve_sale', [op, stale]);
  assert.equal(r1.status, 'price_changed');
  assert.deepEqual([r1.changes[0].expected_baisa, r1.changes[0].current_baisa], [12000, 13000]);
  assert.equal(await count('invoices'), invBefore);
  assert.equal((await db.rpc(ID.cashierTnt, 'get_operation', [op])).found, false);
  const r2 = await db.rpc(ID.cashierTnt, 'approve_sale', [op,
    sale(sTnt, [line(ID.mats, 1, 13000)], [{ method: 'cash', amount_baisa: 13000 }], 13000)]);
  assert.equal(r2.status, 'approved'); assert.match(r2.invoice.invoice_no, /^TNT-\d\d-000001$/);
});

test('التقريب: ضريبة مضافة على السعر، ضريبة معطلة، وخصم ضمن حد المدير', async () => {
  // ضريبة 5% تُضاف على السعر، مع خصم 10% للمدير (حده 15%)
  await db.sql(`update branch_settings set prices_include_tax=false where branch_id=$1`, [ID.tyr]);
  const l = [line(ID.tireMI, 1, 34500, 3450), line(ID.install, 3, 1000)];
  // 34500-3450=31050 → ضريبة 1552.5 → 1553 ؛ 3000 → 150 ؛ الإجمالي 31050+1553+3000+150 = 35753
  const stale = await db.rpc(ID.manager, 'approve_sale', [uuid(), sale(sTyr2, l, [{ method: 'card', amount_baisa: 34050 }], 34050)]);
  assert.equal(stale.status, 'total_changed'); assert.equal(stale.server_total_baisa, 35753);
  const r = await db.rpc(ID.manager, 'approve_sale', [uuid(), sale(sTyr2, l, [{ method: 'card', amount_baisa: 35753 }], 35753)]);
  assert.deepEqual([r.invoice.subtotal_baisa, r.invoice.discount_baisa, r.invoice.net_baisa, r.invoice.tax_baisa, r.invoice.total_baisa],
    [37500, 3450, 34050, 1703, 35753]);
  assert.deepEqual(r.invoice.lines.map((x) => x.tax_baisa), [1553, 150]);
  // خصم يتجاوز حد المدير، وخصم من كاشير بلا صلاحية
  await expectCode(db.rpc(ID.manager, 'approve_sale', [uuid(),
    sale(sTyr2, [line(ID.install, 1, 1000, 200)], [{ method: 'cash', amount_baisa: 840 }], 840)]), 'DISCOUNT_LIMIT_EXCEEDED');
  await expectCode(db.rpc(ID.cashierTyr, 'approve_sale', [uuid(),
    sale(sTyr, [line(ID.install, 1, 1000, 10)], [{ method: 'cash', amount_baisa: 1040 }], 1040)]), 'DISCOUNT_LIMIT_EXCEEDED');
  // ضريبة معطلة
  await db.sql(`update branch_settings set tax_enabled=false where branch_id=$1`, [ID.tyr]);
  const n = await db.rpc(ID.cashierTyr, 'approve_sale', [uuid(), sale(sTyr, [line(ID.install, 1, 1000)], [{ method: 'cash', amount_baisa: 1000 }], 1000)]);
  assert.deepEqual([n.invoice.net_baisa, n.invoice.tax_baisa, n.invoice.tax_rate_bp], [1000, 0, 0]);
  await db.sql(`update branch_settings set tax_enabled=true, prices_include_tax=true where branch_id=$1`, [ID.tyr]);
  // كمية كسرية لصنف يباع بالحبة
  await expectCode(db.rpc(ID.cashierTyr, 'approve_sale', [uuid(),
    sale(sTyr, [line(ID.tireMI, 1.5, 34500)], [{ method: 'cash', amount_baisa: 51750 }], 51750)]), 'INVALID_QUANTITY');
});

test('عزل الفروع والصلاحيات عبر API مباشرة', async () => {
  const tyrInvoice = (await db.sql('select id from invoices where branch_id=$1 limit 1', [ID.tyr]))[0].id;
  // كاشير العازل لا يرى بيانات فرع الإطارات
  const seen = await db.as(ID.cashierTnt, async (c) => ({
    invoices: (await c.query('select count(*)::int n from invoices where branch_id=$1', [ID.tyr])).rows[0].n,
    lines: (await c.query('select count(*)::int n from invoice_lines where branch_id=$1', [ID.tyr])).rows[0].n,
    payments: (await c.query('select count(*)::int n from payments where branch_id=$1', [ID.tyr])).rows[0].n,
    sessions: (await c.query('select count(*)::int n from cash_sessions where branch_id=$1', [ID.tyr])).rows[0].n,
    branches: (await c.query('select count(*)::int n from branches')).rows[0].n,
    own: (await c.query('select count(*)::int n from invoices')).rows[0].n,
  }));
  assert.deepEqual(seen, { invoices: 0, lines: 0, payments: 0, sessions: 0, branches: 1, own: 1 });
  await expectCode(db.rpc(ID.cashierTnt, 'get_invoice', [tyrInvoice]), 'NOT_FOUND');
  await expectCode(db.rpc(ID.cashierTnt, 'open_cash_session', [uuid(), ID.devTyr1, 0]), 'FORBIDDEN');
  await expectCode(db.rpc(ID.cashierTnt, 'approve_sale', [uuid(),
    sale(sTyr, [line(ID.install, 1, 1000)], [{ method: 'cash', amount_baisa: 1000 }], 1000)]), 'FORBIDDEN');
  await expectCode(db.rpc(ID.cashierTnt, 'resolve_device', ['POS-TYR-01']), 'DEVICE_NOT_FOUND');
  assert.equal((await db.rpc(ID.cashierTnt, 'recent_operations', [sTyr, 20])).length, 0);
  // وردية مستخدم آخر في الفرع نفسه
  await expectCode(db.rpc(ID.manager, 'approve_sale', [uuid(),
    sale(sTyr, [line(ID.install, 1, 1000)], [{ method: 'cash', amount_baisa: 1000 }], 1000)]), 'SESSION_NOT_YOURS');

  // الكاشير لا يقرأ التكلفة ولا القيود ولا التدقيق، ولا يكتب مباشرة في الجداول المالية
  const cashier = await db.as(ID.cashierTyr, async (c) => ({
    costs: (await c.query('select count(*)::int n from invoice_line_costs')).rows[0].n,
    lots: (await c.query('select count(*)::int n from inventory_lots')).rows[0].n,
    journal: (await c.query('select count(*)::int n from journal_lines')).rows[0].n,
    audit: (await c.query('select count(*)::int n from audit_log')).rows[0].n,
    invoices: (await c.query('select count(*)::int n from invoices')).rows[0].n,
  }));
  assert.deepEqual({ ...cashier, invoices: cashier.invoices > 0 }, { costs: 0, lots: 0, journal: 0, audit: 0, invoices: true });
  for (const q of [
    `update invoices set total_baisa = 1`, `delete from invoices`, `update inventory_lots set qty_on_hand = 99`,
    `insert into payments (organization_id, branch_id, invoice_id, cash_session_id, method, amount_baisa) select organization_id, branch_id, id, cash_session_id, 'cash', 1 from invoices limit 1`,
    `update products set base_price_baisa = 1`, `select * from operation_requests`, `select * from branch_counters`]) {
    await assert.rejects(db.as(ID.cashierTyr, (c) => c.query(q)), /permission denied/, q);
  }
  // كاشير يحاول استخدام صلاحيات المحاسب/المدير
  const dash = await db.rpc(ID.cashierTyr, 'dashboard_summary', [null, '2000-01-01', '2100-01-01']);
  assert.equal(dash.invoice_count, 0);
  // المحاسب يقرأ القيود في كل الفروع لكنه لا يبيع ولا يفتح وردية
  const acc = await db.as(ID.accountant, async (c) => (await c.query('select count(distinct branch_id)::int n from journal_entries')).rows[0].n);
  assert.equal(acc, 2);
  await expectCode(db.rpc(ID.accountant, 'open_cash_session', [uuid(), ID.devTyr1, 0]), 'FORBIDDEN');
  // مدير فرع الإطارات لا يرى فرع العازل
  assert.equal(await db.as(ID.manager, async (c) => (await c.query('select count(*)::int n from invoices where branch_id=$1', [ID.tnt])).rows[0].n), 0);
  // بلا تسجيل دخول: لا تنفيذ ولا قراءة
  await assert.rejects(db.rpc(null, 'my_context', []), /permission denied/);
  await assert.rejects(db.as(null, (c) => c.query('select * from invoices')), /permission denied/);
  // مستخدم معطّل يفقد الوصول
  await db.sql(`update profiles set is_active=false where id=$1`, [ID.cashierTnt]);
  assert.equal(await db.as(ID.cashierTnt, async (c) => (await c.query('select count(*)::int n from invoices')).rows[0].n), 0);
  await db.sql(`update profiles set is_active=true where id=$1`, [ID.cashierTnt]);
});

test('سياق المستخدم والمؤشرات وسلامة السجلات', async () => {
  const ctx = await db.rpc(ID.cashierTyr, 'my_context', []);
  assert.equal(ctx.branches.length, 1); assert.equal(ctx.branches[0].code, 'TYR');
  assert.ok(ctx.branches[0].permissions.includes('pos.sell')); assert.ok(!ctx.branches[0].permissions.includes('invoice.void'));
  assert.equal((await db.rpc(ID.owner, 'my_context', [])).branches.length, 2);

  const d = await db.rpc(ID.owner, 'dashboard_summary', [null, '2000-01-01', '2100-01-01']);
  const t = (await db.sql(`select count(*)::int n, sum(net_baisa) net, sum(total_baisa) total from invoices`))[0];
  const pay = (await db.sql(`select sum(amount_baisa) filter (where method='cash') cash, sum(amount_baisa) filter (where method='card') card from payments`))[0];
  const cost = (await db.sql(`select sum(cost_baisa) c from invoice_line_costs`))[0].c;
  assert.deepEqual([d.invoice_count, d.net_sales_baisa, d.total_baisa, d.cash_baisa, d.card_baisa, d.gross_profit_baisa],
    [t.n, t.net, t.total, pay.cash, pay.card, t.net - cost]);
  assert.equal(d.cash_baisa + d.card_baisa, d.total_baisa);
  const dm = await db.rpc(ID.manager, 'dashboard_summary', [null, '2000-01-01', '2100-01-01']);
  assert.equal(dm.invoice_count, await count('invoices', 'branch_id=$1', [ID.tyr]));

  // كل القيود متوازنة، والمخزون يساوي مجموع الحركات، والدرج يساوي الافتتاحي + النقد
  assert.equal(await count(`(select entry_id from journal_lines group by 1 having sum(debit_baisa)<>sum(credit_baisa)) x`), 0);
  assert.equal(await count(`(select l.id from inventory_lots l join stock_movements m on m.lot_id=l.id group by l.id, l.qty_on_hand having sum(m.qty_delta)<>l.qty_on_hand) x`), 0);
  const drawer = (await db.sql(`select sum(amount_baisa) s from cash_movements where cash_session_id=$1`, [sTyr]))[0].s;
  const cashSales = (await db.sql(`select coalesce(sum(amount_baisa),0) s from payments where cash_session_id=$1 and method='cash'`, [sTyr]))[0].s;
  assert.equal(drawer, 20000 + cashSales);
  // قيد غير متوازن أو تعديل سجل مالي يُرفض حتى من خارج الواجهات
  await assert.rejects(db.sql(`insert into journal_lines (entry_id, organization_id, branch_id, account_id, debit_baisa)
    select e.id, e.organization_id, e.branch_id, (select id from accounts limit 1), 5 from journal_entries e limit 1`), /JOURNAL_UNBALANCED/);
  await assert.rejects(db.sql(`update payments set amount_baisa = 1`), /IMMUTABLE_RECORD/);
  await assert.rejects(db.sql(`delete from stock_movements`), /IMMUTABLE_RECORD/);
});

test('إعادة الطباعة تُسجَّل في التدقيق', async () => {
  const inv = (await db.sql('select id from invoices where branch_id=$1 order by seq limit 1', [ID.tyr]))[0].id;
  await db.rpc(ID.cashierTyr, 'record_invoice_print', [inv, false]);
  await db.rpc(ID.cashierTyr, 'record_invoice_print', [inv, true]);
  const again = await db.rpc(ID.cashierTyr, 'get_invoice', [inv]);
  assert.equal(again.print_count, 2); assert.equal(again.lines.length, 2);
  assert.equal(await count('audit_log', `entity_id=$1 and action='invoice.reprint'`, [inv]), 1);
});

test('قائمة الفواتير: بحث برقم الفاتورة والهاتف واللوحة ضمن الفروع المصرح بها فقط', async () => {
  const all = await db.rpc(ID.owner, 'list_invoices', [null, '2000-01-01', '2100-01-01', null, 100]);
  assert.equal(all.length, await count('invoices'));
  assert.ok(all.every((x, i) => i === 0 || all[i - 1].approved_at >= x.approved_at), 'الأحدث أولًا');
  const byPhone = await db.rpc(ID.owner, 'list_invoices', [null, '2000-01-01', '2100-01-01', '9689000', 100]);
  assert.equal(byPhone.length, 1); assert.equal(byPhone[0].plate, '12345 أ ب'); assert.equal(byPhone[0].cash_baisa, 116000);
  assert.equal((await db.rpc(ID.owner, 'list_invoices', [null, '2000-01-01', '2100-01-01', '12345', 100])).length, 1);
  assert.equal((await db.rpc(ID.owner, 'list_invoices', [null, '2000-01-01', '2100-01-01', 'TNT-', 100])).length, 1);
  assert.equal((await db.rpc(ID.owner, 'list_invoices', [ID.tnt, '2000-01-01', '2100-01-01', null, 100])).length, 1);
  assert.equal((await db.rpc(ID.owner, 'list_invoices', [null, '2000-01-01', '2000-01-02', null, 100])).length, 0);
  const tnt = await db.rpc(ID.cashierTnt, 'list_invoices', [null, '2000-01-01', '2100-01-01', null, 100]);
  assert.ok(tnt.length === 1 && tnt[0].branch_code === 'TNT');
  assert.equal((await db.rpc(ID.cashierTnt, 'list_invoices', [ID.tyr, '2000-01-01', '2100-01-01', null, 100])).length, 0);
});

test('التخلي عن عملية غير مؤكدة: طلب متأخر بالمعرف نفسه لا يُعتمد، والمعتمدة لا تُلغى', async () => {
  const op = uuid();
  const payload = sale(sTyr, [line(ID.install, 1, 1000)], [{ method: 'cash', amount_baisa: 1000 }], 1000);
  const n = await count('invoices');
  assert.equal((await db.rpc(ID.cashierTyr, 'cancel_operation', [op, sTyr])).status, 'cancelled');
  await expectCode(db.rpc(ID.cashierTyr, 'approve_sale', [op, payload]), 'OPERATION_CANCELLED');
  assert.equal(await count('invoices'), n);
  // عملية اعتُمدت فعلًا: محاولة التخلي تعيد الفاتورة
  const op2 = uuid();
  const ok = await db.rpc(ID.cashierTyr, 'approve_sale', [op2, payload]);
  const c = await db.rpc(ID.cashierTyr, 'cancel_operation', [op2, sTyr]);
  assert.equal(c.status, 'approved'); assert.equal(c.invoice.id, ok.invoice.id);
  // سباق: اعتماد وتخلٍّ في اللحظة نفسها — نتيجة واحدة متسقة
  const op3 = uuid();
  const [a, b] = await Promise.allSettled([db.rpc(ID.cashierTyr, 'approve_sale', [op3, payload]), db.rpc(ID.cashierTyr, 'cancel_operation', [op3, sTyr])]);
  const invoices = await count('invoices', 'operation_id=$1', [op3]);
  if (a.status === 'fulfilled') { assert.equal(invoices, 1); assert.equal(b.value.status, 'approved'); }
  else { assert.equal(a.reason.message, 'OPERATION_CANCELLED'); assert.equal(invoices, 0); assert.equal(b.value.status, 'cancelled'); }
  await expectCode(db.rpc(ID.cashierTnt, 'cancel_operation', [uuid(), sTyr]), 'FORBIDDEN');
});
