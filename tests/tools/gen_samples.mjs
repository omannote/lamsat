// يولّد عينات الطلبات والردود في contracts/samples من قاعدة الاختبار المحلية (ردود حقيقية من الدوال).
import fs from 'node:fs';
import path from 'node:path';
import { startDb, ID, uuid } from '../harness.mjs';

const out = path.resolve(import.meta.dirname, '../../contracts/samples');
const save = (name, v) => fs.writeFileSync(path.join(out, `${name}.json`), JSON.stringify(v, null, 2) + '\n');
const db = await startDb();
try {
  save('my_context.response', await db.rpc(ID.cashierTyr, 'my_context', []));
  save('resolve_device.response', await db.rpc(ID.cashierTyr, 'resolve_device', ['POS-TYR-01']));
  const open = await db.rpc(ID.cashierTyr, 'open_cash_session', [uuid(), ID.devTyr1, 20000]);
  save('open_cash_session.response', open);
  save('pos_search.response', await db.as(ID.cashierTyr, (c) => c.query('select * from pos_search($1,$2)', [ID.tyr, '205']).then((r) => r.rows)));
  const request = { cash_session_id: open.session.id, customer_id: ID.customer, vehicle_id: ID.vehicle,
    lines: [{ product_id: ID.tireBS, qty: 4, unit_price_baisa: 28000, discount_baisa: 0 }, { product_id: ID.install, qty: 4, unit_price_baisa: 1000, discount_baisa: 0 }],
    payments: [{ method: 'cash', amount_baisa: 66000 }, { method: 'card', amount_baisa: 50000, card_reference: 'AUTH-123456' }],
    cash_tendered_baisa: 70000, expected_total_baisa: 116000 };
  const op = uuid();
  save('approve_sale.request', { p_operation_id: op, p_payload: request });
  const res = await db.rpc(ID.cashierTyr, 'approve_sale', [op, request]);
  save('approve_sale.response', res);
  await db.sql('update products set base_price_baisa = 29000 where id = $1', [ID.tireBS]);
  save('approve_sale.price_changed.response', await db.rpc(ID.cashierTyr, 'approve_sale', [uuid(), request]));
  save('get_operation.response', await db.rpc(ID.cashierTyr, 'get_operation', [op]));
  save('list_invoices.response', await db.rpc(ID.owner, 'list_invoices', [null, '2000-01-01', '2100-01-01', null, 100]));
  save('dashboard_summary.response', await db.rpc(ID.owner, 'dashboard_summary', [null, '2000-01-01', '2100-01-01']));
  save('cash_session_summary.response', await db.rpc(ID.cashierTyr, 'cash_session_summary', [open.session.id]));
  save('close_cash_session.response', await db.rpc(ID.cashierTyr, 'close_cash_session', [uuid(), open.session.id, 85500, 'نقص 500 بيسة في الفكة']));
  await db.rpc(ID.cashierTnt, 'open_cash_session', [uuid(), ID.devTnt, 10000]);
  save('list_cash_sessions.response', await db.rpc(ID.owner, 'list_cash_sessions', [null, '2000-01-01', '2100-01-01']));
  save('owner_context.response', await db.rpc(ID.owner, 'my_context', []));
  const j = await db.sql(`select l.id, l.entry_id, l.account_id, l.debit_baisa, l.credit_baisa from journal_lines l order by l.id`);
  save('_journal_lines.rows', j);
  save('_accounts.rows', await db.sql('select id, code, name_ar from accounts order by code'));
  save('_journal_entries.rows', await db.sql('select id from journal_entries'));
  save('_audit.rows', await db.sql(`select id, action, created_at, user_id from audit_log where entity_type='invoice'`));
} finally { await db.stop(); }
