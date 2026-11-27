-- بطاقة الصنف (مورّد افتراضي، حد التنبيه، أدنى سعر للكاشير، سنة وبلد الإطار)، استلام المشتريات بطريقة دفع وضريبة مدخلات،
-- وحساب المورّد وسداده.

alter table public.products
  add column default_supplier_id uuid,
  add column reorder_level numeric(12,3) check (reorder_level >= 0),
  add column min_price_baisa bigint check (min_price_baisa >= 0),
  add column tire_year int check (tire_year between 1990 and 2100),
  add column tire_country text,
  add foreign key (default_supplier_id, organization_id) references public.suppliers(id, organization_id);
alter table public.products drop constraint products_category_check;
alter table public.products add constraint products_category_check check (category in ('tire', 'tint', 'accessory', 'service', 'raw', 'general'));

alter table public.purchase_receipts
  add column supplier_invoice_date date,
  add column payment_method text not null default 'credit' check (payment_method in ('cash', 'credit', 'transfer')),
  add column due_date date,
  add column tax_baisa bigint not null default 0 check (tax_baisa >= 0),
  add column cash_session_id uuid references public.cash_sessions(id);

create or replace function app.ensure_system_accounts(p_org uuid) returns void
language sql security definer set search_path = '' as $$
  insert into public.accounts (organization_id, code, name_ar, name_en, account_type, system_key)
  select p_org, v.code, v.name_ar, v.name_en, v.t, v.k from (values
    ('1130', 'تحويلات بنكية تحت التسوية', 'Bank transfers clearing', 'asset', 'bank_transfer_clearing'),
    ('1140', 'البنك', 'Bank', 'asset', 'bank'),
    ('1210', 'العملاء — ذمم مدينة', 'Accounts receivable', 'asset', 'accounts_receivable'),
    ('1410', 'ضريبة القيمة المضافة — مدخلات', 'VAT input', 'asset', 'vat_input'),
    ('2110', 'الموردون — ذمم دائنة', 'Accounts payable', 'liability', 'accounts_payable'),
    ('4910', 'إيرادات أخرى', 'Other income', 'revenue', 'misc_income'),
    ('5120', 'تسويات المخزون', 'Inventory adjustments', 'expense', 'inventory_adjustment'),
    ('5210', 'مصروفات نثرية', 'Petty expenses', 'expense', 'misc_expense')) as v(code, name_ar, name_en, t, k)
  where not exists (select 1 from public.accounts a where a.organization_id = p_org and (a.system_key = v.k or a.code = v.code));
$$;
select app.ensure_system_accounts(id) from public.organizations;

-- تعديل الدوال القائمة في موضعها؛ يفشل الترحيل إن لم يوجد النص المستهدف.
do $$
declare d text; r record;
begin
  for r in select * from (values
    -- حقول بطاقة الصنف الإضافية: تُحدَّث فقط إن أُرسلت، فلا تُمسح من واجهة لا تعرفها
    ('public.save_product(jsonb)', 'return to_jsonb(v_new);',
       'if p_product ?| array[''default_supplier_id'', ''reorder_level'', ''min_price_baisa'', ''tire_year'', ''tire_country''] then
    if (p_product->>''default_supplier_id'') is not null and not exists (select 1 from public.suppliers where id = (p_product->>''default_supplier_id'')::uuid and organization_id = v_org) then
      perform app.fail(''NOT_FOUND''); end if;
    update public.products set
      default_supplier_id = case when p_product ? ''default_supplier_id'' then (p_product->>''default_supplier_id'')::uuid else default_supplier_id end,
      reorder_level = case when p_product ? ''reorder_level'' then (p_product->>''reorder_level'')::numeric else reorder_level end,
      min_price_baisa = case when p_product ? ''min_price_baisa'' then (p_product->>''min_price_baisa'')::bigint else min_price_baisa end,
      tire_year = case when p_product ? ''tire_year'' then (p_product->>''tire_year'')::int else tire_year end,
      tire_country = case when p_product ? ''tire_country'' then nullif(btrim(p_product->>''tire_country''), '''') else tire_country end
    where id = v_id returning * into v_new;
  end if;
  return to_jsonb(v_new);'),
    -- أدنى سعر للكاشير: الخصم لا ينزل بسعر الوحدة تحته إلا لمن يرى التكلفة (مدير الفرع والمالك)
    ('public.approve_sale(uuid,jsonb)', 'perform app.fail(''DISCOUNT_LIMIT_EXCEEDED'', jsonb_build_object(''line_no'', v_idx, ''max_discount_bp'', v_max_disc)); end if;',
       'perform app.fail(''DISCOUNT_LIMIT_EXCEEDED'', jsonb_build_object(''line_no'', v_idx, ''max_discount_bp'', v_max_disc)); end if;
    if v_disc > 0 and v_prod.min_price_baisa is not null and v_gross - v_disc < app.round_baisa(v_qty * v_prod.min_price_baisa)
       and not app.has_perm(v_sess.branch_id, ''inventory.cost.view'') then
      perform app.fail(''BELOW_MIN_PRICE'', jsonb_build_object(''line_no'', v_idx, ''name_ar'', v_prod.name_ar, ''min_price_baisa'', v_prod.min_price_baisa)); end if;')
  ) as t(fn, target, repl) loop
    d := pg_get_functiondef(r.fn::regprocedure);
    if position(r.target in d) = 0 then raise exception 'patch target missing in %: %', r.fn, r.target; end if;
    execute replace(d, r.target, r.repl);
  end loop;
end $$;

create or replace function public.stock_report(p_branch_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select case when not app.has_perm(p_branch_id, 'inventory.view') then '[]'::jsonb else coalesce((
    select jsonb_agg(jsonb_build_object('product_id', p.id, 'sku', p.sku, 'name_ar', p.name_ar, 'category', p.category, 'unit', p.unit,
        'brand', p.brand, 'tire_year', p.tire_year, 'reorder_level', p.reorder_level, 'whole_units_only', p.whole_units_only,
        'tire_size', case when p.tire_size_key is not null then p.tire_width || '/' || p.tire_aspect || 'R' || p.tire_rim end,
        'is_active', p.is_active, 'price_baisa', app.effective_price(p_branch_id, p.id), 'qty', coalesce(s.qty, 0),
        'value_baisa', case when app.has_perm(p_branch_id, 'inventory.cost.view') then coalesce(s.val, 0) end,
        'avg_cost_baisa', case when app.has_perm(p_branch_id, 'inventory.cost.view') and coalesce(s.qty, 0) > 0 then round(s.val / s.qty) end,
        'lots', case when app.has_perm(p_branch_id, 'inventory.cost.view') then coalesce(s.lots, '[]'::jsonb) end) order by p.category, p.name_ar)
    from public.products p
    left join lateral (select sum(l.qty_on_hand) qty, sum(round(l.qty_on_hand * l.unit_cost_baisa)) val,
        jsonb_agg(jsonb_build_object('lot_id', l.id, 'lot_code', l.lot_code, 'dot_code', l.dot_code, 'qty', l.qty_on_hand, 'unit_cost_baisa', l.unit_cost_baisa,
          'received_at', l.received_at) order by l.received_at) filter (where l.qty_on_hand > 0) lots
      from public.inventory_lots l where l.branch_id = p_branch_id and l.product_id = p.id) s on true
    where p.organization_id = (select organization_id from public.branches where id = p_branch_id) and p.track_stock), '[]'::jsonb) end;
$$;

-- بطاقة الصنف: البيانات، الباركود، الرصيد في كل فرع متاح للمستخدم، وآخر الحركات في الفرع الحالي
create or replace function public.product_card(p_branch_id uuid, p_product_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_p public.products; v_cost boolean := app.has_perm(p_branch_id, 'inventory.cost.view');
begin
  if not app.has_perm(p_branch_id, 'inventory.view') then perform app.fail('FORBIDDEN'); end if;
  select p.* into v_p from public.products p join public.branches b on b.organization_id = p.organization_id where p.id = p_product_id and b.id = p_branch_id;
  if not found then perform app.fail('PRODUCT_NOT_FOUND'); end if;
  return jsonb_build_object(
    'product', to_jsonb(v_p),
    'price_baisa', app.effective_price(p_branch_id, v_p.id),
    'barcodes', coalesce((select jsonb_agg(barcode order by barcode) from public.product_barcodes where product_id = v_p.id), '[]'::jsonb),
    'supplier_name', (select name from public.suppliers where id = v_p.default_supplier_id),
    'can_edit', app.has_org_perm(v_p.organization_id, 'catalog.manage'),
    'branches', coalesce((select jsonb_agg(jsonb_build_object('branch_id', b.id, 'name_ar', b.name_ar,
          'qty', coalesce((select sum(qty_on_hand) from public.inventory_lots where branch_id = b.id and product_id = v_p.id), 0),
          'avg_cost_baisa', case when v_cost then (select round(sum(qty_on_hand * unit_cost_baisa) / nullif(sum(qty_on_hand), 0)) from public.inventory_lots where branch_id = b.id and product_id = v_p.id) end)
        order by b.code)
      from public.branches b where b.organization_id = v_p.organization_id and b.is_active and app.has_perm(b.id, 'inventory.view')), '[]'::jsonb),
    'movements', coalesce((select jsonb_agg(jsonb_build_object('at', m.created_at, 'type', m.movement_type, 'qty_delta', m.qty_delta,
          'unit_cost_baisa', case when v_cost then m.unit_cost_baisa end) order by m.id desc)
      from (select * from public.stock_movements where branch_id = p_branch_id and product_id = v_p.id order by id desc limit 15) m), '[]'::jsonb));
end $$;

-- ───────────── استلام المشتريات ─────────────
-- p_payload: { branch_id, supplier_id?, reference? (رقم فاتورة المورّد), supplier_invoice_date?, note?,
--   payment_method: 'credit'(افتراضي)|'cash'|'transfer', due_date? (للآجل), tax_rate_bp? (ضريبة المدخلات، التكاليف غير شاملة لها),
--   cash_session_id? (مطلوب للنقدي: يخرج المبلغ من درج وردية المستخدم), lines:[{product_id, qty, unit_cost_baisa, lot_code?, dot_code?}] }
create or replace function public.receive_purchase(p_operation_id uuid, p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid()); v_hash text := md5(p_payload::text); v_r jsonb;
  v_branch uuid := (p_payload->>'branch_id')::uuid; v_org uuid; v_id uuid := gen_random_uuid(); v_total bigint := 0;
  l jsonb; v_prod public.products; v_qty numeric(12,3); v_cost bigint; v_lot uuid; v_n int := 0;
  v_method text := coalesce(nullif(p_payload->>'payment_method', ''), 'credit'); v_rate int := coalesce((p_payload->>'tax_rate_bp')::int, 0);
  v_tax bigint; v_sess public.cash_sessions; v_drawer bigint; v_supplier uuid := (p_payload->>'supplier_id')::uuid;
begin
  v_r := app.op_replay(p_operation_id, 'purchase_receipt', v_hash); if v_r is not null then return v_r; end if;
  select organization_id into v_org from public.branches where id = v_branch;
  if v_org is null or not app.has_perm(v_branch, 'inventory.manage') then perform app.fail('FORBIDDEN'); end if;
  if jsonb_typeof(p_payload->'lines') <> 'array' or jsonb_array_length(p_payload->'lines') not between 1 and 200 then perform app.fail('EMPTY_CART'); end if;
  if v_supplier is not null and not exists (select 1 from public.suppliers where id = v_supplier and organization_id = v_org) then perform app.fail('NOT_FOUND'); end if;
  if v_method not in ('cash', 'credit', 'transfer') or v_rate not between 0 and 10000 then perform app.fail('INVALID_REQUEST'); end if;
  if v_method = 'credit' and v_supplier is null then perform app.fail('SUPPLIER_REQUIRED'); end if;
  if v_method = 'cash' then
    select * into v_sess from public.cash_sessions where id = (p_payload->>'cash_session_id')::uuid and branch_id = v_branch for update;
    if not found then perform app.fail('SESSION_NOT_FOUND'); end if;
    if v_sess.status <> 'open' then perform app.fail('SESSION_CLOSED'); end if;
    if v_sess.opened_by <> v_uid then perform app.fail('SESSION_NOT_YOURS'); end if;
  end if;
  insert into public.purchase_receipts (id, organization_id, branch_id, supplier_id, reference, note, total_cost_baisa, created_by, operation_id,
    supplier_invoice_date, payment_method, due_date, cash_session_id)
  values (v_id, v_org, v_branch, v_supplier, nullif(btrim(p_payload->>'reference'), ''), nullif(btrim(p_payload->>'note'), ''), 0, v_uid, p_operation_id,
    (p_payload->>'supplier_invoice_date')::date, v_method, case when v_method = 'credit' then (p_payload->>'due_date')::date end, v_sess.id);
  for l in select * from jsonb_array_elements(p_payload->'lines') loop
    v_n := v_n + 1;
    select * into v_prod from public.products where id = (l->>'product_id')::uuid and organization_id = v_org and track_stock;
    if not found then perform app.fail('PRODUCT_NOT_FOUND', jsonb_build_object('line_no', v_n)); end if;
    v_qty := (l->>'qty')::numeric; v_cost := (l->>'unit_cost_baisa')::bigint;
    if v_qty is null or v_qty <= 0 or (v_prod.whole_units_only and v_qty <> trunc(v_qty)) then perform app.fail('INVALID_QUANTITY', jsonb_build_object('line_no', v_n)); end if;
    if v_cost is null or v_cost < 0 then perform app.fail('INVALID_AMOUNT', jsonb_build_object('line_no', v_n)); end if;
    insert into public.inventory_lots (organization_id, branch_id, product_id, lot_code, dot_code, unit_cost_baisa, qty_received, qty_on_hand, purchase_receipt_id)
    values (v_org, v_branch, v_prod.id, nullif(btrim(l->>'lot_code'), ''), nullif(btrim(l->>'dot_code'), ''), v_cost, v_qty, v_qty, v_id) returning id into v_lot;
    insert into public.stock_movements (organization_id, branch_id, product_id, lot_id, movement_type, qty_delta, unit_cost_baisa, source_type, source_id, created_by)
    values (v_org, v_branch, v_prod.id, v_lot, 'purchase_receipt', v_qty, v_cost, 'purchase_receipt', v_id, v_uid);
    v_total := v_total + app.round_baisa(v_qty * v_cost);
  end loop;
  v_tax := app.round_baisa(v_total * v_rate / 10000.0);
  update public.purchase_receipts set total_cost_baisa = v_total, tax_baisa = v_tax where id = v_id;
  if v_method = 'cash' then
    select coalesce(sum(amount_baisa), 0) into v_drawer from public.cash_movements where cash_session_id = v_sess.id;
    if v_total + v_tax > v_drawer then perform app.fail('INSUFFICIENT_CASH', jsonb_build_object('drawer_baisa', v_drawer)); end if;
    insert into public.cash_movements (organization_id, branch_id, cash_session_id, movement_type, amount_baisa, source_type, source_id, note, created_by)
    values (v_org, v_branch, v_sess.id, 'cash_out', -(v_total + v_tax), 'purchase_receipt', v_id, 'مشتريات نقدية ' || coalesce(p_payload->>'reference', ''), v_uid);
  end if;
  perform app.post_journal(v_org, v_branch, v_sess.business_day_id, 'purchase_receipt', v_id, 'استلام مشتريات ' || coalesce(p_payload->>'reference', ''),
    jsonb_build_array(jsonb_build_array('inventory', v_total, 0), jsonb_build_array('vat_input', v_tax, 0),
      jsonb_build_array(case v_method when 'cash' then 'cash_on_hand' when 'transfer' then 'bank' else 'accounts_payable' end, 0, v_total + v_tax)));
  perform app.audit(v_org, v_branch, 'purchase.receive', 'purchase_receipt', v_id, null, null,
    jsonb_build_object('total_cost_baisa', v_total, 'tax_baisa', v_tax, 'payment_method', v_method, 'lines', v_n));
  return app.op_store(p_operation_id, v_org, v_branch, v_sess.id, 'purchase_receipt', v_hash,
    jsonb_build_object('status', 'received', 'receipt_id', v_id, 'total_cost_baisa', v_total, 'tax_baisa', v_tax, 'payable_baisa', v_total + v_tax, 'lines', v_n));
end $$;

create or replace function public.list_purchases(p_branch_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select case when not app.has_perm(p_branch_id, 'inventory.cost.view') then '[]'::jsonb else coalesce((
    select jsonb_agg(jsonb_build_object('id', r.id, 'created_at', r.created_at, 'reference', r.reference, 'supplier_invoice_date', r.supplier_invoice_date,
        'supplier_name', (select name from public.suppliers where id = r.supplier_id), 'payment_method', r.payment_method, 'due_date', r.due_date,
        'total_cost_baisa', r.total_cost_baisa, 'tax_baisa', r.tax_baisa) order by r.created_at desc)
    from (select * from public.purchase_receipts where branch_id = p_branch_id order by created_at desc limit 200) r), '[]'::jsonb) end;
$$;

-- ───────────── حساب المورّد وسداده ─────────────
create table public.supplier_payments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null, branch_id uuid not null, supplier_id uuid not null,
  method text not null check (method in ('cash', 'transfer')),
  amount_baisa bigint not null check (amount_baisa > 0),
  reference text, cash_session_id uuid references public.cash_sessions(id),
  created_by uuid not null, created_at timestamptz not null default now(),
  foreign key (supplier_id, organization_id) references public.suppliers(id, organization_id),
  foreign key (branch_id, organization_id) references public.branches(id, organization_id));
create index supplier_payments_supplier_idx on public.supplier_payments (supplier_id);
alter table public.supplier_payments enable row level security;
create policy supplier_payments_read on public.supplier_payments for select to authenticated using (app.has_perm(branch_id, 'inventory.cost.view'));
create trigger supplier_payments_immutable before update or delete on public.supplier_payments for each row execute function app.forbid_change();

-- المستحق للمورّد = المشتريات الآجلة (شاملة ضريبتها) − ما سُدِّد
create or replace function app.supplier_balance(p_supplier uuid) returns bigint
language sql stable security definer set search_path = '' as $$
  select (select coalesce(sum(total_cost_baisa + tax_baisa), 0) from public.purchase_receipts where supplier_id = p_supplier and payment_method = 'credit')
       - (select coalesce(sum(amount_baisa), 0) from public.supplier_payments where supplier_id = p_supplier);
$$;
revoke all on function app.supplier_balance(uuid) from public;

create or replace function public.suppliers_overview(p_branch_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select case when not app.has_perm(p_branch_id, 'inventory.view') then '[]'::jsonb else coalesce((
    select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'phone', s.phone, 'is_active', s.is_active,
        'balance_baisa', case when app.has_perm(p_branch_id, 'inventory.cost.view') then app.supplier_balance(s.id) end) order by s.name)
    from public.suppliers s where s.organization_id = (select organization_id from public.branches where id = p_branch_id)), '[]'::jsonb) end;
$$;

-- سداد للمورّد: نقدي من درج وردية المستخدم أو تحويل بنكي
create or replace function public.pay_supplier(p_operation_id uuid, p_branch_id uuid, p_supplier_id uuid, p_method text, p_amount_baisa bigint,
  p_reference text, p_cash_session_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); v_org uuid; v_sup public.suppliers; v_sess public.cash_sessions; v_r jsonb; v_id uuid; v_bal bigint; v_drawer bigint;
  v_hash text := md5(jsonb_build_object('b', p_branch_id, 's', p_supplier_id, 'm', p_method, 'a', p_amount_baisa, 'r', p_reference, 'c', p_cash_session_id)::text);
begin
  v_r := app.op_replay(p_operation_id, 'supplier_payment', v_hash); if v_r is not null then return v_r; end if;
  select organization_id into v_org from public.branches where id = p_branch_id;
  if v_org is null or not app.has_perm(p_branch_id, 'inventory.manage') then perform app.fail('FORBIDDEN'); end if;
  select * into v_sup from public.suppliers where id = p_supplier_id and organization_id = v_org for update;
  if not found then perform app.fail('NOT_FOUND'); end if;
  if p_method not in ('cash', 'transfer') or p_amount_baisa is null or p_amount_baisa <= 0 then perform app.fail('INVALID_AMOUNT'); end if;
  v_bal := app.supplier_balance(v_sup.id);
  if p_amount_baisa > v_bal then perform app.fail('AMOUNT_EXCEEDS_BALANCE', jsonb_build_object('balance_baisa', v_bal)); end if;
  if p_method = 'cash' then
    select * into v_sess from public.cash_sessions where id = p_cash_session_id and branch_id = p_branch_id for update;
    if not found then perform app.fail('SESSION_NOT_FOUND'); end if;
    if v_sess.status <> 'open' then perform app.fail('SESSION_CLOSED'); end if;
    if v_sess.opened_by <> v_uid then perform app.fail('SESSION_NOT_YOURS'); end if;
    select coalesce(sum(amount_baisa), 0) into v_drawer from public.cash_movements where cash_session_id = v_sess.id;
    if p_amount_baisa > v_drawer then perform app.fail('INSUFFICIENT_CASH', jsonb_build_object('drawer_baisa', v_drawer)); end if;
  end if;
  insert into public.supplier_payments (organization_id, branch_id, supplier_id, method, amount_baisa, reference, cash_session_id, created_by)
  values (v_org, p_branch_id, v_sup.id, p_method, p_amount_baisa, nullif(btrim(p_reference), ''), v_sess.id, v_uid) returning id into v_id;
  if p_method = 'cash' then
    insert into public.cash_movements (organization_id, branch_id, cash_session_id, movement_type, amount_baisa, source_type, source_id, note, created_by)
    values (v_org, p_branch_id, v_sess.id, 'cash_out', -p_amount_baisa, 'supplier_payment', v_id, 'سداد للمورّد — ' || v_sup.name, v_uid);
  end if;
  perform app.post_journal(v_org, p_branch_id, v_sess.business_day_id, 'supplier_payment', v_id, 'سداد للمورّد ' || v_sup.name,
    jsonb_build_array(jsonb_build_array('accounts_payable', p_amount_baisa, 0),
      jsonb_build_array(case when p_method = 'cash' then 'cash_on_hand' else 'bank' end, 0, p_amount_baisa)));
  perform app.audit(v_org, p_branch_id, 'supplier.payment', 'supplier', v_sup.id, null, null, jsonb_build_object('amount_baisa', p_amount_baisa, 'method', p_method));
  return app.op_store(p_operation_id, v_org, p_branch_id, v_sess.id, 'supplier_payment', v_hash,
    jsonb_build_object('status', 'recorded', 'payment_id', v_id, 'balance_baisa', v_bal - p_amount_baisa));
end $$;

revoke all on function public.product_card(uuid, uuid), public.list_purchases(uuid), public.suppliers_overview(uuid),
  public.pay_supplier(uuid, uuid, uuid, text, bigint, text, uuid) from public, anon;
grant execute on function public.product_card(uuid, uuid), public.list_purchases(uuid), public.suppliers_overview(uuid),
  public.pay_supplier(uuid, uuid, uuid, text, bigint, text, uuid) to authenticated;
