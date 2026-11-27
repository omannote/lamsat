// إعدادات الفرع: الورديات للكاشير فقط افتراضيًا، وبقية الأدوار تُفعَّل من إعدادات النظام.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { startDb, ID, uuid, expectCode } from '../harness.mjs';

let db;
before(async () => { db = await startDb(); });
after(async () => { await db.stop(); });

test('افتراضيًا يفتح الكاشير الوردية فقط؛ المدير والمالك يُرفضان حتى يفعّلهما المالك من الإعدادات', async () => {
  await expectCode(db.rpc(ID.manager, 'open_cash_session', [uuid(), ID.devTyr2, 0]), 'SHIFT_NOT_ENABLED_FOR_ROLE');
  await expectCode(db.rpc(ID.owner, 'open_cash_session', [uuid(), ID.devTyr2, 0]), 'SHIFT_NOT_ENABLED_FOR_ROLE');
  assert.equal((await db.rpc(ID.cashierTyr, 'open_cash_session', [uuid(), ID.devTyr1, 0])).status, 'opened');
  assert.equal(Number((await db.sql('select count(*) n from cash_sessions'))[0].n), 1);

  await expectCode(db.rpc(ID.manager, 'update_branch_settings', [ID.tyr, { shift_roles: ['branch_manager'] }]), 'FORBIDDEN');
  const s = await db.rpc(ID.owner, 'update_branch_settings', [ID.tyr, { shift_roles: ['branch_manager', 'nonsense'] }]);
  assert.deepEqual([...s.shift_roles].sort(), ['branch_manager', 'cashier'], 'الكاشير يبقى دائمًا والأدوار المجهولة تُهمل');
  assert.equal((await db.rpc(ID.manager, 'open_cash_session', [uuid(), ID.devTyr2, 0])).status, 'opened');
  await expectCode(db.rpc(ID.owner, 'open_cash_session', [uuid(), ID.devTnt, 0]), 'SHIFT_NOT_ENABLED_FOR_ROLE');
  // الإعداد لكل فرع على حدة
  assert.deepEqual((await db.sql('select shift_roles from branch_settings where branch_id=$1', [ID.tnt]))[0].shift_roles, ['cashier']);
  assert.equal(Number((await db.sql(`select count(*) n from audit_log where action='branch_settings.update' and user_id=$1`, [ID.owner]))[0].n), 1);
});

test('إعدادات الضريبة ونص الإيصال تُحدَّث وتُطبَّق على البيع التالي', async () => {
  await db.rpc(ID.owner, 'update_branch_settings', [ID.tnt, { tax_enabled: false, receipt_footer_ar: 'نسعد بخدمتكم' }]);
  const s = (await db.rpc(ID.cashierTnt, 'open_cash_session', [uuid(), ID.devTnt, 0])).session.id;
  const r = await db.rpc(ID.cashierTnt, 'approve_sale', [uuid(), { cash_session_id: s,
    lines: [{ product_id: ID.holder, qty: 1, unit_price_baisa: 3000, discount_baisa: 0 }], payments: [{ method: 'cash', amount_baisa: 3000 }], expected_total_baisa: 3000 }]);
  assert.deepEqual([r.invoice.tax_baisa, r.invoice.branch.receipt_footer_ar], [0, 'نسعد بخدمتكم']);
  await expectCode(db.rpc(ID.owner, 'update_branch_settings', [ID.tnt, { tax_rate_bp: 20000 }]), 'INVALID_AMOUNT');
});
