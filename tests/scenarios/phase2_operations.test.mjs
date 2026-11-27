// الكتالوج، المشتريات، تسوية المخزون، العملاء، المسودات، القبض والصرف، المرتجع والإلغاء.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { startDb, ID, uuid, expectCode } from '../harness.mjs';

let db, s;
const one = async (q, p) => (await db.sql(q, p))[0];
const stock = async (branch, product) => Number((await one('select coalesce(sum(qty_on_hand),0) q from inventory_lots where branch_id=$1 and product_id=$2', [branch, product])).q);
const sell = (lines, payments, total, extra = {}) => db.rpc(ID.cashierTyr, 'approve_sale', [uuid(),
  { cash_session_id: s, lines: lines.map(([product_id, qty, unit_price_baisa]) => ({ product_id, qty, unit_price_baisa, discount_baisa: 0 })), payments, expected_total_baisa: total, ...extra }]);
const balanced = async () => Number((await one(`select count(*) n from (select entry_id from journal_lines group by 1 having sum(debit_baisa)<>sum(credit_baisa)) x`)).n);
const stockOk = async () => Number((await one(`select count(*) n from (select l.id from inventory_lots l join stock_movements m on m.lot_id=l.id group by l.id, l.qty_on_hand having sum(m.qty_delta)<>l.qty_on_hand) x`)).n);

before(async () => { db = await startDb(); s = (await db.rpc(ID.cashierTyr, 'open_cash_session', [uuid(), ID.devTyr1, 50000])).session.id; });
after(async () => { await db.stop(); });

test('الكتالوج: إضافة وتعديل صنف مع باركود وسعر فرع، حسب الصلاحية', async () => {
  const base = { organization_id: ID.org, sku: 'TR-2254518-CN', kind: 'item', category: 'tire', name_ar: 'إطار كونتيننتال 225/45R18', brand: 'Continental',
    unit: 'حبة', base_price_baisa: 41000, tire_width: 225, tire_aspect: 45, tire_rim: 18, barcodes: ['4019238000001'] };
  await expectCode(db.rpc(ID.manager, 'save_product', [base]), 'FORBIDDEN');
  const p = await db.rpc(ID.owner, 'save_product', [base]);
  assert.equal(p.tire_size_key, '2254518'); assert.equal(p.track_stock, true);
  await expectCode(db.rpc(ID.owner, 'save_product', [base]), 'SKU_EXISTS');
  await expectCode(db.rpc(ID.owner, 'save_product', [{ ...base, sku: 'X-1', barcodes: ['6291000000011'] }]), 'BARCODE_EXISTS');
  const u = await db.rpc(ID.owner, 'save_product', [{ ...base, id: p.id, base_price_baisa: 42000 }]);
  assert.equal(u.base_price_baisa, 42000);
  assert.equal(Number((await one(`select count(*) n from audit_log where entity_id=$1 and action='product.update' and (old_values->>'base_price_baisa')='41000'`, [p.id])).n), 1);
  const svc = await db.rpc(ID.owner, 'save_product', [{ organization_id: ID.org, sku: 'SV-NITRO', kind: 'service', name_ar: 'تعبئة نيتروجين', base_price_baisa: 500, track_stock: true }]);
  assert.equal(svc.track_stock, false, 'الخدمة لا يُتتبع مخزونها');
  await db.rpc(ID.owner, 'set_branch_price', [ID.tyr, p.id, 40000]);
  let r = await db.as(ID.cashierTyr, (c) => c.query('select * from pos_search($1,$2)', [ID.tyr, '4019238000001']).then((x) => x.rows));
  assert.deepEqual([r[0].unit_price_baisa, r[0].exact_barcode], [40000, true]);
  await db.rpc(ID.owner, 'set_branch_price', [ID.tyr, p.id, null]);
  r = await db.as(ID.cashierTyr, (c) => c.query('select * from pos_search($1,$2)', [ID.tyr, '225/45']).then((x) => x.rows));
  assert.equal(r[0].unit_price_baisa, 42000);
  await expectCode(db.rpc(ID.cashierTyr, 'set_branch_price', [ID.tyr, p.id, 1]), 'FORBIDDEN');
});

test('استلام مشتريات: دفعات وحركات وقيد، بلا تكرار، ثم بيع منها', async () => {
  const sup = await db.rpc(ID.manager, 'save_supplier', [{ organization_id: ID.org, name: 'مورد الإطارات', phone: '24000000' }]);
  const before = await stock(ID.tyr, ID.tireHK);
  const payload = { branch_id: ID.tyr, supplier_id: sup.id, reference: 'PO-77', lines: [
    { product_id: ID.tireHK, qty: 8, unit_cost_baisa: 13500, dot_code: 'DOT 4026' }, { product_id: ID.tireMI, qty: 4, unit_cost_baisa: 25000 }] };
  await expectCode(db.rpc(ID.cashierTyr, 'receive_purchase', [uuid(), payload]), 'FORBIDDEN');
  await expectCode(db.rpc(ID.manager, 'receive_purchase', [uuid(), { ...payload, branch_id: ID.tnt }]), 'FORBIDDEN');
  await expectCode(db.rpc(ID.manager, 'receive_purchase', [uuid(), { ...payload, lines: [{ product_id: ID.install, qty: 1, unit_cost_baisa: 1 }] }]), 'PRODUCT_NOT_FOUND');
  const op = uuid();
  const r = await db.rpc(ID.manager, 'receive_purchase', [op, payload]);
  assert.deepEqual([r.status, r.total_cost_baisa, r.lines], ['received', 208000, 2]);
  assert.equal((await db.rpc(ID.manager, 'receive_purchase', [op, payload])).replayed, true);
  assert.equal(await stock(ID.tyr, ID.tireHK), before + 8);
  const j = await db.sql(`select a.system_key k, l.debit_baisa d, l.credit_baisa c from journal_lines l join journal_entries e on e.id=l.entry_id join accounts a on a.id=l.account_id where e.source_id=$1 order by a.code`, [r.receipt_id]);
  assert.deepEqual(j.map((x) => [x.k, x.d, x.c]), [['inventory', 208000, 0], ['accounts_payable', 0, 208000]]);
  const rep = await db.rpc(ID.manager, 'stock_report', [ID.tyr]);
  const hk = rep.find((x) => x.product_id === ID.tireHK);
  assert.equal(hk.qty, before + 8); assert.ok(hk.value_baisa > 0 && hk.lots.length >= 1);
  const repCashier = await db.rpc(ID.cashierTyr, 'stock_report', [ID.tyr]);
  assert.equal(repCashier.find((x) => x.product_id === ID.tireHK).value_baisa, null, 'الكاشير لا يرى التكلفة');
  assert.equal((await db.rpc(ID.cashierTnt, 'stock_report', [ID.tyr])).length, 0);
});

test('تسوية المخزون: زيادة ونقص بسبب إلزامي وقيد، ورفض ما يتجاوز الرصيد', async () => {
  const q0 = await stock(ID.tyr, ID.tireHK);
  await expectCode(db.rpc(ID.manager, 'adjust_stock', [uuid(), ID.tyr, ID.tireHK, -1, null, ' ']), 'REASON_REQUIRED');
  await expectCode(db.rpc(ID.manager, 'adjust_stock', [uuid(), ID.tyr, ID.tireHK, -(q0 + 1), null, 'جرد']), 'INSUFFICIENT_STOCK');
  const dn = await db.rpc(ID.manager, 'adjust_stock', [uuid(), ID.tyr, ID.tireHK, -2, null, 'تالف في الجرد']);
  assert.equal(await stock(ID.tyr, ID.tireHK), q0 - 2); assert.ok(dn.value_baisa > 0);
  const up = await db.rpc(ID.manager, 'adjust_stock', [uuid(), ID.tyr, ID.tireHK, 1, 14000, 'وُجد في الجرد']);
  assert.equal(up.value_baisa, 14000); assert.equal(await stock(ID.tyr, ID.tireHK), q0 - 1);
  await expectCode(db.rpc(ID.cashierTyr, 'adjust_stock', [uuid(), ID.tyr, ID.tireHK, 1, 1, 'x']), 'FORBIDDEN');
  assert.equal(await balanced(), 0); assert.equal(await stockOk(), 0);
});

test('العملاء: إضافة من الكاشير، والهاتف المكرر يعيد العميل نفسه ويضيف المركبة', async () => {
  const a = await db.rpc(ID.cashierTyr, 'save_customer', [{ branch_id: ID.tyr, name: 'سالم', phone: '+968 9111 2222', plate: '777 ب ر', make: 'Nissan' }]);
  assert.equal(a.customer.phone, '96891112222'); assert.equal(a.vehicle.plate, '777 ب ر');
  const b = await db.rpc(ID.cashierTyr, 'save_customer', [{ branch_id: ID.tyr, name: 'اسم آخر', phone: '96891112222', plate: '888 ب ر' }]);
  assert.equal(b.customer.id, a.customer.id); assert.notEqual(b.vehicle.id, a.vehicle.id);
  assert.equal(Number((await one('select count(*) n from vehicles where customer_id=$1', [a.customer.id])).n), 2);
  await expectCode(db.rpc(ID.accountant, 'save_customer', [{ branch_id: ID.tyr, name: 'x' }]), 'FORBIDDEN');
});

test('المسودات: حفظ وتعديل وقائمة وحذف حسب الصلاحية مع التدقيق', async () => {
  const d = await db.rpc(ID.cashierTyr, 'save_draft', [null, s, 'سيارة كامري', 116000, { lines: [{ product_id: ID.tireBS, qty: 4 }] }]);
  await db.rpc(ID.cashierTyr, 'save_draft', [d.id, s, 'سيارة كامري — معدّل', 120000, { lines: [] }]);
  const list = await db.rpc(ID.cashierTyr, 'list_drafts', [ID.tyr]);
  assert.deepEqual([list.length, list[0].title, list[0].total_baisa], [1, 'سيارة كامري — معدّل', 120000]);
  assert.equal((await db.rpc(ID.cashierTnt, 'list_drafts', [ID.tyr])).length, 0);
  await expectCode(db.rpc(ID.cashierTnt, 'delete_draft', [d.id, 'x']), 'FORBIDDEN');
  await db.rpc(ID.manager, 'delete_draft', [d.id, 'عميل لم يعد']);
  assert.equal((await db.rpc(ID.cashierTyr, 'list_drafts', [ID.tyr])).length, 0);
  assert.equal(Number((await one(`select count(*) n from audit_log where action='draft.delete' and reason='عميل لم يعد' and user_id=$1`, [ID.manager])).n), 1);
});

test('القبض والصرف النقدي يدخلان في النقد المتوقع عند الإقفال', async () => {
  await expectCode(db.rpc(ID.cashierTyr, 'record_cash_movement', [uuid(), s, 'cash_out', 5000, '']), 'REASON_REQUIRED');
  await expectCode(db.rpc(ID.cashierTyr, 'record_cash_movement', [uuid(), s, 'cash_out', 999999, 'x']), 'INSUFFICIENT_CASH');
  await expectCode(db.rpc(ID.cashierTnt, 'record_cash_movement', [uuid(), s, 'cash_in', 1, 'x']), 'FORBIDDEN');
  const op = uuid();
  const o = await db.rpc(ID.cashierTyr, 'record_cash_movement', [op, s, 'cash_out', 5000, 'شراء ماء']);
  assert.equal(o.drawer_baisa, 45000);
  assert.equal((await db.rpc(ID.cashierTyr, 'record_cash_movement', [op, s, 'cash_out', 5000, 'شراء ماء'])).replayed, true);
  await db.rpc(ID.cashierTyr, 'record_cash_movement', [uuid(), s, 'cash_in', 2000, 'فكة من المالك']);
  const sum = await db.rpc(ID.cashierTyr, 'cash_session_summary', [s]);
  assert.deepEqual([sum.cash_other_baisa, sum.expected_cash_baisa], [-3000, 47000]);
  assert.equal(await balanced(), 0);
});

test('مرتجع جزئي ثم كلي: الكميات والمبالغ المتبقية، المخزون، القيد، الصندوق، بلا فرق تقريب', async () => {
  const q0 = await stock(ID.tyr, ID.tireMI);
  // 3 إطارات بسعر 34500 شامل ضريبة 5% + 3 تركيب
  const inv = (await sell([[ID.tireMI, 3, 34500], [ID.install, 3, 1000]], [{ method: 'cash', amount_baisa: 106500 }], 106500, { customer_id: ID.customer })).invoice;
  assert.equal(await stock(ID.tyr, ID.tireMI), q0 - 3);
  const base = { invoice_id: inv.id, kind: 'refund', method: 'cash', cash_session_id: s };
  await expectCode(db.rpc(ID.cashierTyr, 'refund_invoice', [uuid(), { ...base, reason: 'x', lines: [{ line_no: 1, qty: 1 }] }]), 'FORBIDDEN');
  await expectCode(db.rpc(ID.manager, 'refund_invoice', [uuid(), { ...base, reason: '', lines: [{ line_no: 1, qty: 1 }] }]), 'REASON_REQUIRED');
  await expectCode(db.rpc(ID.manager, 'refund_invoice', [uuid(), { ...base, reason: 'x', lines: [{ line_no: 1, qty: 4 }] }]), 'REFUND_EXCEEDS_REMAINING');
  await expectCode(db.rpc(ID.manager, 'refund_invoice', [uuid(), { ...base, reason: 'x', lines: [] }]), 'EMPTY_CART');

  const op = uuid();
  const p1 = { ...base, reason: 'مقاس غير مناسب', lines: [{ line_no: 1, qty: 1, restock: true }, { line_no: 2, qty: 1 }] };
  const r1 = await db.rpc(ID.manager, 'refund_invoice', [op, p1]);
  assert.match(r1.refund_no, /^R-TYR-\d\d-000001$/);
  assert.deepEqual([r1.status, r1.amount_baisa, r1.tax_baisa], ['refunded', 35500, 1643 + 48]);
  assert.equal((await db.rpc(ID.manager, 'refund_invoice', [op, p1])).replayed, true);
  assert.equal(await stock(ID.tyr, ID.tireMI), q0 - 2);
  let st = await db.rpc(ID.manager, 'invoice_refund_state', [inv.id]);
  assert.deepEqual(st.lines.map((l) => [l.remaining_qty, l.remaining_baisa]), [[2, 69000], [2, 2000]]);
  assert.equal(st.refunds.length, 1); assert.equal(st.open_sessions.length, 1);
  const j = await db.sql(`select a.system_key k, l.debit_baisa d, l.credit_baisa c from journal_lines l join journal_entries e on e.id=l.entry_id join accounts a on a.id=l.account_id where e.source_id=$1 order by a.code`, [r1.refund_id]);
  const J = Object.fromEntries(j.map((x) => [x.k, x.d - x.c]));
  assert.equal(J.cash_on_hand, -35500); assert.equal(J.vat_output, 1691); assert.equal(J.sales_goods + J.sales_services, 35500 - 1691);
  assert.equal(J.inventory, -J.cogs); assert.ok(J.inventory > 0);
  // إرجاع بلا إعادة للمخزون (تالف) ثم الباقي كله
  await db.rpc(ID.manager, 'refund_invoice', [uuid(), { ...base, method: 'card', cash_session_id: null, reason: 'تالف', lines: [{ line_no: 1, qty: 1, restock: false }] }]);
  assert.equal(await stock(ID.tyr, ID.tireMI), q0 - 2);
  await db.rpc(ID.manager, 'refund_invoice', [uuid(), { ...base, reason: 'إرجاع الباقي', lines: [{ line_no: 1, qty: 1, restock: true }, { line_no: 2, qty: 2 }] }]);
  st = await db.rpc(ID.manager, 'invoice_refund_state', [inv.id]);
  assert.deepEqual(st.lines.map((l) => [l.remaining_qty, l.remaining_baisa]), [[0, 0], [0, 0]]);
  const tot = await one(`select sum(amount_baisa) a, sum(tax_baisa) t, sum(net_baisa) n from refunds where invoice_id=$1`, [inv.id]);
  assert.deepEqual([Number(tot.a), Number(tot.t), Number(tot.n)], [inv.total_baisa, inv.tax_baisa, inv.net_baisa], 'مجموع المرتجعات يساوي الفاتورة بالضبط');
  await expectCode(db.rpc(ID.manager, 'refund_invoice', [uuid(), { ...base, reason: 'x', lines: [{ line_no: 2, qty: 1 }] }]), 'REFUND_EXCEEDS_REMAINING');
  await expectCode(db.rpc(ID.manager, 'refund_invoice', [uuid(), { ...base, kind: 'void', reason: 'x' }]), 'INVOICE_HAS_REFUNDS');
  assert.equal(await balanced(), 0); assert.equal(await stockOk(), 0);
});

test('إلغاء فاتورة معتمدة: حركات عكسية كاملة، حالة ملغاة، تدقيق بالسبب، واستبعاد من المؤشرات', async () => {
  const q0 = await stock(ID.tyr, ID.tireBS);
  const d0 = await db.rpc(ID.owner, 'dashboard_summary', [ID.tyr, '2000-01-01', '2100-01-01']);
  const inv = (await sell([[ID.tireBS, 4, 28000], [ID.install, 4, 1000]], [{ method: 'cash', amount_baisa: 66000 }, { method: 'card', amount_baisa: 50000 }], 116000, { customer_id: ID.customer })).invoice;
  const base = { invoice_id: inv.id, kind: 'void', method: 'cash', cash_session_id: s, reason: 'فاتورة بالخطأ' };
  await expectCode(db.rpc(ID.accountant, 'refund_invoice', [uuid(), base]), 'FORBIDDEN');
  await expectCode(db.rpc(ID.cashierTnt, 'refund_invoice', [uuid(), base]), 'NOT_FOUND');
  const v = await db.rpc(ID.manager, 'refund_invoice', [uuid(), base]);
  assert.deepEqual([v.status, v.amount_baisa, v.restocked_cost_baisa], ['voided', 116000, 74000]);
  assert.equal(await stock(ID.tyr, ID.tireBS), q0);
  assert.equal((await db.rpc(ID.manager, 'get_invoice', [inv.id])).status, 'voided');
  await expectCode(db.rpc(ID.manager, 'refund_invoice', [uuid(), base]), 'INVOICE_NOT_REFUNDABLE');
  assert.equal(Number((await one(`select count(*) n from audit_log where entity_id=$1 and action='invoice.void' and reason='فاتورة بالخطأ' and user_id=$2`, [inv.id, ID.manager])).n), 1);
  assert.equal(Number((await one(`select count(*) n from notification_events where invoice_id=$1 and event_type='invoice_voided'`, [inv.id])).n), 1);
  // أثر الفاتورة وإلغائها على الحسابات صفر
  const net = await db.sql(`select a.system_key k, sum(l.debit_baisa - l.credit_baisa) v from journal_lines l join journal_entries e on e.id=l.entry_id join accounts a on a.id=l.account_id
    where e.source_id in ($1,$2) group by 1`, [inv.id, v.refund_id]);
  const N = Object.fromEntries(net.map((x) => [x.k, Number(x.v)]));
  assert.deepEqual([N.sales_goods, N.sales_services, N.vat_output, N.inventory, N.cogs], [0, 0, 0, 0, 0]);
  assert.equal(N.cash_on_hand, 66000 - 116000, 'رُدّ المبلغ كله نقدًا من الدرج'); assert.equal(N.card_clearing, 50000);
  const d1 = await db.rpc(ID.owner, 'dashboard_summary', [ID.tyr, '2000-01-01', '2100-01-01']);
  assert.deepEqual([d1.invoice_count, d1.net_sales_baisa, d1.gross_profit_baisa], [d0.invoice_count, d0.net_sales_baisa, d0.gross_profit_baisa]);
  assert.equal(await balanced(), 0); assert.equal(await stockOk(), 0);
  // الدرج عند الإقفال يعكس المرتجعات النقدية
  const drawer = Number((await one('select sum(amount_baisa) s from cash_movements where cash_session_id=$1', [s])).s);
  const sum = await db.rpc(ID.cashierTyr, 'cash_session_summary', [s]);
  assert.equal(sum.expected_cash_baisa, drawer);
});

test('مرتجع بعد إقفال اليوم يُرحَّل إلى اليوم المفتوح ويبقى اليوم المقفل كما هو', async () => {
  const inv = (await sell([[ID.install, 2, 1000]], [{ method: 'cash', amount_baisa: 2000 }], 2000)).invoice;
  const oldDay = (await one('select business_day_id d from invoices where id=$1', [inv.id])).d;
  const sum = await db.rpc(ID.cashierTyr, 'cash_session_summary', [s]);
  await db.rpc(ID.cashierTyr, 'close_cash_session', [uuid(), s, sum.expected_cash_baisa, null]);
  const base = { invoice_id: inv.id, kind: 'refund', method: 'card', reason: 'تصحيح لاحق', lines: [{ line_no: 1, qty: 1 }] };
  await db.sql(`update business_days set business_date = business_date - 1 where id=$1`, [oldDay]);
  const s2 = (await db.rpc(ID.cashierTyr, 'open_cash_session', [uuid(), ID.devTyr1, 0])).session;
  assert.notEqual(s2.business_day_id, oldDay);
  const before = await one(`select count(*) n, coalesce(sum(l.debit_baisa),0) d from journal_entries e join journal_lines l on l.entry_id=e.id where e.business_day_id=$1`, [oldDay]);
  const r = await db.rpc(ID.manager, 'refund_invoice', [uuid(), base]);
  const f = await one('select business_day_id d, invoice_id i from refunds where id=$1', [r.refund_id]);
  assert.equal(f.d, s2.business_day_id); assert.equal(f.i, inv.id);
  const after = await one(`select count(*) n, coalesce(sum(l.debit_baisa),0) d from journal_entries e join journal_lines l on l.entry_id=e.id where e.business_day_id=$1`, [oldDay]);
  assert.deepEqual(after, before, 'قيود اليوم المقفل لم تتغير');
});
