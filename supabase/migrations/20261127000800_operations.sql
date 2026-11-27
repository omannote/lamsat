-- لمسات | العمليات اليومية: الكتالوج، الموردون والمشتريات، تسوية المخزون، العملاء، المسودات، القبض والصرف، المرتجع والإلغاء

-- ───────────── جداول ─────────────
create table public.suppliers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  name text not null, phone text, notes text, is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (id, organization_id));

create table public.purchase_receipts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null, branch_id uuid not null, supplier_id uuid,
  reference text, note text, total_cost_baisa bigint not null,
  created_by uuid, created_at timestamptz not null default now(), operation_id uuid not null unique,
  foreign key (branch_id, organization_id) references public.branches(id, organization_id),
  foreign key (supplier_id, organization_id) references public.suppliers(id, organization_id));
alter table public.inventory_lots add column purchase_receipt_id uuid references public.purchase_receipts(id);

create table public.invoice_drafts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null, branch_id uuid not null, device_id uuid references public.devices(id),
  created_by uuid not null references public.profiles(id),
  title text not null, total_baisa bigint not null default 0, payload jsonb not null,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  foreign key (branch_id, organization_id) references public.branches(id, organization_id));
create index invoice_drafts_branch_idx on public.invoice_drafts (branch_id, updated_at desc);

create table public.refunds (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null, branch_id uuid not null,
  invoice_id uuid not null references public.invoices(id),
  refund_no text not null, kind text not null check (kind in ('refund','void')),
  business_day_id uuid not null references public.business_days(id),
  cash_session_id uuid references public.cash_sessions(id),
  method text not null check (method in ('cash','card')),
  reason text not null,
  net_baisa bigint not null, tax_baisa bigint not null, amount_baisa bigint not null check (amount_baisa >= 0),
  created_by uuid not null, created_at timestamptz not null default now(), operation_id uuid not null unique,
  unique (organization_id, refund_no),
  check (amount_baisa = net_baisa + tax_baisa), check (method <> 'cash' or cash_session_id is not null),
  foreign key (branch_id, organization_id) references public.branches(id, organization_id));
create index refunds_invoice_idx on public.refunds (invoice_id);
create index refunds_day_idx on public.refunds (business_day_id);

create table public.refund_lines (
  id uuid primary key default gen_random_uuid(),
  refund_id uuid not null references public.refunds(id),
  organization_id uuid not null, branch_id uuid not null,
  invoice_line_id uuid not null references public.invoice_lines(id),
  qty numeric(12,3) not null check (qty > 0),
  net_baisa bigint not null, tax_baisa bigint not null, amount_baisa bigint not null,
  restocked boolean not null default false, cost_baisa bigint not null default 0);
create index refund_lines_line_idx on public.refund_lines (invoice_line_id);

create trigger refunds_immutable before update or delete on public.refunds for each row execute function app.forbid_change();
create trigger refund_lines_immutable before update or delete on public.refund_lines for each row execute function app.forbid_change();

do $$
declare t text;
begin
  foreach t in array array['suppliers','purchase_receipts','invoice_drafts','refunds','refund_lines'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated, public', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('grant all on public.%I to service_role', t);
  end loop;
end $$;
create policy suppliers_read on public.suppliers for select to authenticated using (app.has_org_perm(organization_id, 'inventory.view'));
create policy purchase_receipts_read on public.purchase_receipts for select to authenticated using (app.has_perm(branch_id, 'inventory.cost.view'));
create policy invoice_drafts_read on public.invoice_drafts for select to authenticated using (app.has_perm(branch_id, 'pos.sell') or app.has_perm(branch_id, 'draft.delete'));
create policy refunds_read on public.refunds for select to authenticated using (app.has_perm(branch_id, 'invoice.view'));
create policy refund_lines_read on public.refund_lines for select to authenticated using (app.has_perm(branch_id, 'invoice.view'));

-- حسابات نظامية إضافية (مبدئية — يراجعها المحاسب)
create or replace function app.ensure_system_accounts(p_org uuid) returns void
language sql security definer set search_path = '' as $$
  insert into public.accounts (organization_id, code, name_ar, name_en, account_type, system_key)
  select p_org, v.code, v.name_ar, v.name_en, v.t, v.k from (values
    ('2110', 'الموردون — ذمم دائنة', 'Accounts payable', 'liability', 'accounts_payable'),
    ('4910', 'إيرادات أخرى', 'Other income', 'revenue', 'misc_income'),
    ('5120', 'تسويات المخزون', 'Inventory adjustments', 'expense', 'inventory_adjustment'),
    ('5210', 'مصروفات نثرية', 'Petty expenses', 'expense', 'misc_expense')) as v(code, name_ar, name_en, t, k)
  where not exists (select 1 from public.accounts a where a.organization_id = p_org and (a.system_key = v.k or a.code = v.code));
$$;
revoke all on function app.ensure_system_accounts(uuid) from public;
select app.ensure_system_accounts(id) from public.organizations;

-- قيد من سطور (system_key, debit, credit)؛ يتجاهل الأصفار ويرفض غياب الحساب.
create or replace function app.post_journal(p_org uuid, p_branch uuid, p_day uuid, p_source_type text, p_source_id uuid, p_desc text, p_lines jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_entry uuid; l jsonb; v_acc uuid;
begin
  if not exists (select 1 from jsonb_array_elements(p_lines) x where (x->>1)::bigint > 0 or (x->>2)::bigint > 0) then return null; end if;
  insert into public.journal_entries (organization_id, branch_id, business_day_id, source_type, source_id, description, created_by)
  values (p_org, p_branch, p_day, p_source_type, p_source_id, p_desc, (select auth.uid())) returning id into v_entry;
  for l in select * from jsonb_array_elements(p_lines) loop
    continue when (l->>1)::bigint = 0 and (l->>2)::bigint = 0;
    select id into v_acc from public.accounts where organization_id = p_org and system_key = l->>0;
    if v_acc is null then perform app.fail('ACCOUNT_MAPPING_MISSING', jsonb_build_object('system_key', l->>0)); end if;
    insert into public.journal_lines (entry_id, organization_id, branch_id, account_id, debit_baisa, credit_baisa)
    values (v_entry, p_org, p_branch, v_acc, (l->>1)::bigint, (l->>2)::bigint);
  end loop;
  return v_entry;
end $$;
revoke all on function app.post_journal(uuid, uuid, uuid, text, uuid, text, jsonb) from public;

-- حجز معرّف عملية: يعيد النتيجة المخزنة إن كان الطلب معادًا، وإلا null.
create or replace function app.op_replay(p_op uuid, p_type text, p_hash text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v public.operation_requests;
begin
  if p_op is null then perform app.fail('INVALID_REQUEST'); end if;
  select * into v from public.operation_requests where operation_id = p_op;
  if not found then return null; end if;
  if v.user_id <> (select auth.uid()) or v.op_type <> p_type or v.request_hash <> p_hash then perform app.fail('OPERATION_MISMATCH'); end if;
  return v.result || jsonb_build_object('replayed', true);
end $$;
create or replace function app.op_store(p_op uuid, p_org uuid, p_branch uuid, p_session uuid, p_type text, p_hash text, p_result jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.operation_requests (operation_id, organization_id, branch_id, cash_session_id, user_id, op_type, request_hash, result)
  values (p_op, p_org, p_branch, p_session, (select auth.uid()), p_type, p_hash, p_result);
  return p_result || jsonb_build_object('replayed', false);
end $$;
revoke all on function app.op_replay(uuid, text, text), app.op_store(uuid, uuid, uuid, uuid, text, text, jsonb) from public;

-- ───────────── الكتالوج ─────────────
create or replace function public.save_product(p_product jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_org uuid := (p_product->>'organization_id')::uuid; v_id uuid := (p_product->>'id')::uuid; v_old public.products; v_new public.products;
begin
  if v_org is null or not app.has_org_perm(v_org, 'catalog.manage') then perform app.fail('FORBIDDEN'); end if;
  if coalesce(btrim(p_product->>'sku'), '') = '' or coalesce(btrim(p_product->>'name_ar'), '') = '' or (p_product->>'base_price_baisa')::bigint is null
     or (p_product->>'base_price_baisa')::bigint < 0 then perform app.fail('INVALID_REQUEST'); end if;
  if exists (select 1 from public.products where organization_id = v_org and sku = btrim(p_product->>'sku') and id is distinct from v_id) then
    perform app.fail('SKU_EXISTS'); end if;
  if v_id is not null then
    select * into v_old from public.products where id = v_id and organization_id = v_org for update;
    if not found then perform app.fail('NOT_FOUND'); end if;
  else v_id := gen_random_uuid(); end if;
  insert into public.products (id, organization_id, sku, kind, category, name_ar, name_en, brand, unit, whole_units_only, track_stock, taxable,
    base_price_baisa, tire_width, tire_aspect, tire_rim, is_active)
  values (v_id, v_org, btrim(p_product->>'sku'), coalesce(p_product->>'kind', 'item'), coalesce(p_product->>'category', 'general'),
    btrim(p_product->>'name_ar'), nullif(btrim(p_product->>'name_en'), ''), nullif(btrim(p_product->>'brand'), ''),
    coalesce(nullif(btrim(p_product->>'unit'), ''), 'قطعة'), coalesce((p_product->>'whole_units_only')::boolean, true),
    coalesce((p_product->>'track_stock')::boolean, (coalesce(p_product->>'kind', 'item') = 'item')) and coalesce(p_product->>'kind', 'item') = 'item',
    coalesce((p_product->>'taxable')::boolean, true), (p_product->>'base_price_baisa')::bigint,
    (p_product->>'tire_width')::int, (p_product->>'tire_aspect')::int, (p_product->>'tire_rim')::int, coalesce((p_product->>'is_active')::boolean, true))
  on conflict (id) do update set sku = excluded.sku, kind = excluded.kind, category = excluded.category, name_ar = excluded.name_ar,
    name_en = excluded.name_en, brand = excluded.brand, unit = excluded.unit, whole_units_only = excluded.whole_units_only,
    track_stock = excluded.track_stock, taxable = excluded.taxable, base_price_baisa = excluded.base_price_baisa,
    tire_width = excluded.tire_width, tire_aspect = excluded.tire_aspect, tire_rim = excluded.tire_rim, is_active = excluded.is_active, updated_at = now()
  returning * into v_new;
  if p_product ? 'barcodes' then
    delete from public.product_barcodes where organization_id = v_org and product_id = v_id;
    begin
      insert into public.product_barcodes (organization_id, barcode, product_id)
      select distinct v_org, btrim(b), v_id from jsonb_array_elements_text(p_product->'barcodes') b where btrim(b) <> '';
    exception when unique_violation then perform app.fail('BARCODE_EXISTS'); end;
  end if;
  perform app.audit(v_org, null, case when v_old.id is null then 'product.create' else 'product.update' end, 'product', v_id, null,
    case when v_old.id is null then null else jsonb_build_object('sku', v_old.sku, 'name_ar', v_old.name_ar, 'base_price_baisa', v_old.base_price_baisa, 'is_active', v_old.is_active) end,
    jsonb_build_object('sku', v_new.sku, 'name_ar', v_new.name_ar, 'base_price_baisa', v_new.base_price_baisa, 'is_active', v_new.is_active));
  return to_jsonb(v_new);
end $$;

-- p_price_baisa = null يحذف سعر الفرع فيعود سعر المنشأة
create or replace function public.set_branch_price(p_branch_id uuid, p_product_id uuid, p_price_baisa bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare v_org uuid; v_old bigint;
begin
  select organization_id into v_org from public.branches where id = p_branch_id;
  if v_org is null or not app.has_org_perm(v_org, 'catalog.manage') or not app.has_branch(p_branch_id) then perform app.fail('FORBIDDEN'); end if;
  if not exists (select 1 from public.products where id = p_product_id and organization_id = v_org) then perform app.fail('NOT_FOUND'); end if;
  select price_baisa into v_old from public.branch_prices where branch_id = p_branch_id and product_id = p_product_id;
  if p_price_baisa is null then delete from public.branch_prices where branch_id = p_branch_id and product_id = p_product_id;
  elsif p_price_baisa < 0 then perform app.fail('INVALID_AMOUNT');
  else insert into public.branch_prices (branch_id, product_id, organization_id, price_baisa) values (p_branch_id, p_product_id, v_org, p_price_baisa)
       on conflict (branch_id, product_id) do update set price_baisa = excluded.price_baisa, updated_at = now(); end if;
  perform app.audit(v_org, p_branch_id, 'branch_price.set', 'product', p_product_id, null, jsonb_build_object('price_baisa', v_old), jsonb_build_object('price_baisa', p_price_baisa));
end $$;

-- ───────────── المخزون والمشتريات ─────────────
create or replace function public.stock_report(p_branch_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select case when not app.has_perm(p_branch_id, 'inventory.view') then '[]'::jsonb else coalesce((
    select jsonb_agg(jsonb_build_object('product_id', p.id, 'sku', p.sku, 'name_ar', p.name_ar, 'category', p.category, 'unit', p.unit,
        'tire_size', case when p.tire_size_key is not null then p.tire_width || '/' || p.tire_aspect || 'R' || p.tire_rim end,
        'is_active', p.is_active, 'price_baisa', app.effective_price(p_branch_id, p.id), 'qty', coalesce(s.qty, 0),
        'value_baisa', case when app.has_perm(p_branch_id, 'inventory.cost.view') then coalesce(s.val, 0) end,
        'lots', case when app.has_perm(p_branch_id, 'inventory.cost.view') then coalesce(s.lots, '[]'::jsonb) end) order by p.category, p.name_ar)
    from public.products p
    left join lateral (select sum(l.qty_on_hand) qty, sum(round(l.qty_on_hand * l.unit_cost_baisa)) val,
        jsonb_agg(jsonb_build_object('lot_id', l.id, 'lot_code', l.lot_code, 'dot_code', l.dot_code, 'qty', l.qty_on_hand, 'unit_cost_baisa', l.unit_cost_baisa,
          'received_at', l.received_at) order by l.received_at) filter (where l.qty_on_hand > 0) lots
      from public.inventory_lots l where l.branch_id = p_branch_id and l.product_id = p.id) s on true
    where p.organization_id = (select organization_id from public.branches where id = p_branch_id) and p.track_stock), '[]'::jsonb) end;
$$;

create or replace function public.save_supplier(p_supplier jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_org uuid := (p_supplier->>'organization_id')::uuid; v_row public.suppliers;
begin
  if v_org is null or not app.has_org_perm(v_org, 'inventory.manage') then perform app.fail('FORBIDDEN'); end if;
  if coalesce(btrim(p_supplier->>'name'), '') = '' then perform app.fail('INVALID_REQUEST'); end if;
  insert into public.suppliers (id, organization_id, name, phone, notes, is_active)
  values (coalesce((p_supplier->>'id')::uuid, gen_random_uuid()), v_org, btrim(p_supplier->>'name'), nullif(btrim(p_supplier->>'phone'), ''),
    nullif(btrim(p_supplier->>'notes'), ''), coalesce((p_supplier->>'is_active')::boolean, true))
  on conflict (id) do update set name = excluded.name, phone = excluded.phone, notes = excluded.notes, is_active = excluded.is_active
    where public.suppliers.organization_id = v_org
  returning * into v_row;
  if v_row.id is null then perform app.fail('NOT_FOUND'); end if;
  return to_jsonb(v_row);
end $$;

-- p_payload: { branch_id, supplier_id?, reference?, note?, lines:[{product_id, qty, unit_cost_baisa, lot_code?, dot_code?}] }
create or replace function public.receive_purchase(p_operation_id uuid, p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid()); v_hash text := md5(p_payload::text); v_r jsonb;
  v_branch uuid := (p_payload->>'branch_id')::uuid; v_org uuid; v_id uuid := gen_random_uuid(); v_total bigint := 0;
  l jsonb; v_prod public.products; v_qty numeric(12,3); v_cost bigint; v_lot uuid; v_n int := 0;
begin
  v_r := app.op_replay(p_operation_id, 'purchase_receipt', v_hash); if v_r is not null then return v_r; end if;
  select organization_id into v_org from public.branches where id = v_branch;
  if v_org is null or not app.has_perm(v_branch, 'inventory.manage') then perform app.fail('FORBIDDEN'); end if;
  if jsonb_typeof(p_payload->'lines') <> 'array' or jsonb_array_length(p_payload->'lines') not between 1 and 200 then perform app.fail('EMPTY_CART'); end if;
  if (p_payload->>'supplier_id') is not null and not exists (select 1 from public.suppliers where id = (p_payload->>'supplier_id')::uuid and organization_id = v_org) then
    perform app.fail('NOT_FOUND'); end if;
  insert into public.purchase_receipts (id, organization_id, branch_id, supplier_id, reference, note, total_cost_baisa, created_by, operation_id)
  values (v_id, v_org, v_branch, (p_payload->>'supplier_id')::uuid, nullif(btrim(p_payload->>'reference'), ''), nullif(btrim(p_payload->>'note'), ''), 0, v_uid, p_operation_id);
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
  update public.purchase_receipts set total_cost_baisa = v_total where id = v_id;
  perform app.post_journal(v_org, v_branch, null, 'purchase_receipt', v_id, 'استلام مشتريات ' || coalesce(p_payload->>'reference', ''),
    jsonb_build_array(jsonb_build_array('inventory', v_total, 0), jsonb_build_array('accounts_payable', 0, v_total)));
  perform app.audit(v_org, v_branch, 'purchase.receive', 'purchase_receipt', v_id, null, null, jsonb_build_object('total_cost_baisa', v_total, 'lines', v_n));
  return app.op_store(p_operation_id, v_org, v_branch, null, 'purchase_receipt', v_hash,
    jsonb_build_object('status', 'received', 'receipt_id', v_id, 'total_cost_baisa', v_total, 'lines', v_n));
end $$;

-- تسوية جرد: موجب يضيف دفعة بالتكلفة المعطاة (أو تكلفة آخر دفعة)، سالب يخصم FIFO. السبب إلزامي.
create or replace function public.adjust_stock(p_operation_id uuid, p_branch_id uuid, p_product_id uuid, p_qty_delta numeric,
  p_unit_cost_baisa bigint, p_reason text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid()); v_org uuid; v_prod public.products; v_r jsonb; v_lot record; v_cost bigint; v_value bigint := 0;
  v_need numeric(12,3); v_take numeric(12,3); v_new uuid; v_ref uuid := gen_random_uuid();
  v_hash text := md5(jsonb_build_object('b', p_branch_id, 'p', p_product_id, 'q', p_qty_delta, 'c', p_unit_cost_baisa, 'r', p_reason)::text);
begin
  v_r := app.op_replay(p_operation_id, 'stock_adjust', v_hash); if v_r is not null then return v_r; end if;
  select organization_id into v_org from public.branches where id = p_branch_id;
  if v_org is null or not app.has_perm(p_branch_id, 'inventory.manage') then perform app.fail('FORBIDDEN'); end if;
  select * into v_prod from public.products where id = p_product_id and organization_id = v_org and track_stock;
  if not found then perform app.fail('PRODUCT_NOT_FOUND'); end if;
  if p_qty_delta is null or p_qty_delta = 0 or (v_prod.whole_units_only and p_qty_delta <> trunc(p_qty_delta)) then perform app.fail('INVALID_QUANTITY'); end if;
  if coalesce(btrim(p_reason), '') = '' then perform app.fail('REASON_REQUIRED'); end if;
  if p_qty_delta > 0 then
    v_cost := coalesce(p_unit_cost_baisa, (select unit_cost_baisa from public.inventory_lots where branch_id = p_branch_id and product_id = p_product_id order by received_at desc, id desc limit 1));
    if v_cost is null or v_cost < 0 then perform app.fail('INVALID_AMOUNT'); end if;
    insert into public.inventory_lots (organization_id, branch_id, product_id, lot_code, unit_cost_baisa, qty_received, qty_on_hand)
    values (v_org, p_branch_id, p_product_id, 'ADJ', v_cost, p_qty_delta, p_qty_delta) returning id into v_new;
    insert into public.stock_movements (organization_id, branch_id, product_id, lot_id, movement_type, qty_delta, unit_cost_baisa, source_type, source_id, created_by)
    values (v_org, p_branch_id, p_product_id, v_new, 'adjustment', p_qty_delta, v_cost, 'adjustment', v_ref, v_uid);
    v_value := app.round_baisa(p_qty_delta * v_cost);
    perform app.post_journal(v_org, p_branch_id, null, 'stock_adjustment', v_ref, 'تسوية مخزون (زيادة): ' || v_prod.name_ar,
      jsonb_build_array(jsonb_build_array('inventory', v_value, 0), jsonb_build_array('inventory_adjustment', 0, v_value)));
  else
    v_need := -p_qty_delta;
    for v_lot in select id, qty_on_hand, unit_cost_baisa from public.inventory_lots
                 where branch_id = p_branch_id and product_id = p_product_id and qty_on_hand > 0 order by received_at, id for update loop
      v_take := least(v_need, v_lot.qty_on_hand);
      update public.inventory_lots set qty_on_hand = qty_on_hand - v_take where id = v_lot.id;
      insert into public.stock_movements (organization_id, branch_id, product_id, lot_id, movement_type, qty_delta, unit_cost_baisa, source_type, source_id, created_by)
      values (v_org, p_branch_id, p_product_id, v_lot.id, 'adjustment', -v_take, v_lot.unit_cost_baisa, 'adjustment', v_ref, v_uid);
      v_value := v_value + app.round_baisa(v_take * v_lot.unit_cost_baisa); v_need := v_need - v_take; exit when v_need = 0;
    end loop;
    if v_need > 0 then perform app.fail('INSUFFICIENT_STOCK', jsonb_build_object('name_ar', v_prod.name_ar, 'requested', -p_qty_delta, 'available', -p_qty_delta - v_need)); end if;
    perform app.post_journal(v_org, p_branch_id, null, 'stock_adjustment', v_ref, 'تسوية مخزون (نقص): ' || v_prod.name_ar,
      jsonb_build_array(jsonb_build_array('inventory_adjustment', v_value, 0), jsonb_build_array('inventory', 0, v_value)));
  end if;
  perform app.audit(v_org, p_branch_id, 'stock.adjust', 'product', p_product_id, btrim(p_reason), null, jsonb_build_object('qty_delta', p_qty_delta, 'value_baisa', v_value));
  return app.op_store(p_operation_id, v_org, p_branch_id, null, 'stock_adjust', v_hash, jsonb_build_object('status', 'adjusted', 'qty_delta', p_qty_delta, 'value_baisa', v_value));
end $$;

-- ───────────── العملاء ─────────────
-- p: { branch_id, name, phone?, preferred_lang?, plate?, make?, model? } — هاتف موجود يعيد العميل نفسه ويضيف المركبة.
create or replace function public.save_customer(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_branch uuid := (p->>'branch_id')::uuid; v_org uuid; v_cust public.customers; v_veh public.vehicles;
  v_phone text := nullif(regexp_replace(coalesce(p->>'phone', ''), '[^0-9]', '', 'g'), ''); v_plate text := nullif(btrim(p->>'plate'), '');
begin
  select organization_id into v_org from public.branches where id = v_branch;
  if v_org is null or not app.has_perm(v_branch, 'pos.sell') then perform app.fail('FORBIDDEN'); end if;
  if coalesce(btrim(p->>'name'), '') = '' then perform app.fail('INVALID_REQUEST'); end if;
  if v_phone is not null then select * into v_cust from public.customers where organization_id = v_org and phone = v_phone; end if;
  if v_cust.id is null then
    insert into public.customers (organization_id, name, phone, preferred_lang)
    values (v_org, btrim(p->>'name'), v_phone, coalesce(nullif(p->>'preferred_lang', ''), 'ar')) returning * into v_cust;
    perform app.audit(v_org, v_branch, 'customer.create', 'customer', v_cust.id, null, null, jsonb_build_object('name', v_cust.name));
  end if;
  if v_plate is not null then
    select * into v_veh from public.vehicles where organization_id = v_org and customer_id = v_cust.id and plate = v_plate;
    if not found then
      insert into public.vehicles (organization_id, customer_id, plate, make, model)
      values (v_org, v_cust.id, v_plate, nullif(btrim(p->>'make'), ''), nullif(btrim(p->>'model'), '')) returning * into v_veh;
    end if;
  end if;
  return jsonb_build_object('customer', jsonb_build_object('id', v_cust.id, 'name', v_cust.name, 'phone', v_cust.phone),
    'vehicle', case when v_veh.id is null then null else jsonb_build_object('id', v_veh.id, 'plate', v_veh.plate) end);
end $$;

-- ───────────── المسودات ─────────────
create or replace function public.save_draft(p_id uuid, p_cash_session_id uuid, p_title text, p_total_baisa bigint, p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_sess public.cash_sessions; v_row public.invoice_drafts;
begin
  select * into v_sess from public.cash_sessions where id = p_cash_session_id and status = 'open';
  if not found or not app.has_perm(v_sess.branch_id, 'pos.sell') then perform app.fail('FORBIDDEN'); end if;
  if jsonb_typeof(p_payload) <> 'object' or coalesce(btrim(p_title), '') = '' then perform app.fail('INVALID_REQUEST'); end if;
  if p_id is null then
    insert into public.invoice_drafts (organization_id, branch_id, device_id, created_by, title, total_baisa, payload)
    values (v_sess.organization_id, v_sess.branch_id, v_sess.device_id, (select auth.uid()), btrim(p_title), coalesce(p_total_baisa, 0), p_payload) returning * into v_row;
  else
    update public.invoice_drafts set title = btrim(p_title), total_baisa = coalesce(p_total_baisa, 0), payload = p_payload, updated_at = now()
    where id = p_id and branch_id = v_sess.branch_id returning * into v_row;
    if v_row.id is null then perform app.fail('NOT_FOUND'); end if;
  end if;
  return jsonb_build_object('id', v_row.id, 'title', v_row.title);
end $$;

create or replace function public.list_drafts(p_branch_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'title', d.title, 'total_baisa', d.total_baisa, 'updated_at', d.updated_at,
      'created_by_name', pr.full_name, 'payload', d.payload) order by d.updated_at desc), '[]'::jsonb)
  from public.invoice_drafts d join public.profiles pr on pr.id = d.created_by
  where d.branch_id = p_branch_id and (app.has_perm(d.branch_id, 'pos.sell') or app.has_perm(d.branch_id, 'draft.delete'));
$$;

-- حذف مسودة: صاحبها، أو من يملك draft.delete (مع سبب). فتح المسودة للبيع يحذفها بالدالة نفسها.
create or replace function public.delete_draft(p_id uuid, p_reason text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare v_row public.invoice_drafts;
begin
  select * into v_row from public.invoice_drafts where id = p_id for update;
  if not found then perform app.fail('NOT_FOUND'); end if;
  if not ((v_row.created_by = (select auth.uid()) and app.has_perm(v_row.branch_id, 'pos.sell')) or app.has_perm(v_row.branch_id, 'draft.delete')
          or (p_reason = 'opened' and app.has_perm(v_row.branch_id, 'pos.sell'))) then perform app.fail('FORBIDDEN'); end if;
  delete from public.invoice_drafts where id = p_id;
  perform app.audit(v_row.organization_id, v_row.branch_id, 'draft.delete', 'invoice_draft', v_row.id, p_reason,
    jsonb_build_object('title', v_row.title, 'total_baisa', v_row.total_baisa), null);
end $$;

-- ───────────── القبض والصرف النقدي ─────────────
create or replace function public.record_cash_movement(p_operation_id uuid, p_cash_session_id uuid, p_type text, p_amount_baisa bigint, p_note text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_sess public.cash_sessions; v_r jsonb; v_id uuid; v_drawer bigint;
  v_hash text := md5(jsonb_build_object('s', p_cash_session_id, 't', p_type, 'a', p_amount_baisa, 'n', p_note)::text);
begin
  v_r := app.op_replay(p_operation_id, 'cash_movement', v_hash); if v_r is not null then return v_r; end if;
  select * into v_sess from public.cash_sessions where id = p_cash_session_id for update;
  if not found then perform app.fail('SESSION_NOT_FOUND'); end if;
  if not app.has_perm(v_sess.branch_id, 'cash.movement') then perform app.fail('FORBIDDEN'); end if;
  if v_sess.status <> 'open' then perform app.fail('SESSION_CLOSED'); end if;
  if v_sess.opened_by <> (select auth.uid()) and not app.has_perm(v_sess.branch_id, 'cash.close.any') then perform app.fail('SESSION_NOT_YOURS'); end if;
  if p_type not in ('cash_in', 'cash_out') or p_amount_baisa is null or p_amount_baisa <= 0 then perform app.fail('INVALID_AMOUNT'); end if;
  if coalesce(btrim(p_note), '') = '' then perform app.fail('REASON_REQUIRED'); end if;
  select coalesce(sum(amount_baisa), 0) into v_drawer from public.cash_movements where cash_session_id = v_sess.id;
  if p_type = 'cash_out' and p_amount_baisa > v_drawer then perform app.fail('INSUFFICIENT_CASH', jsonb_build_object('drawer_baisa', v_drawer)); end if;
  insert into public.cash_movements (organization_id, branch_id, cash_session_id, movement_type, amount_baisa, note, created_by)
  values (v_sess.organization_id, v_sess.branch_id, v_sess.id, p_type, case when p_type = 'cash_in' then p_amount_baisa else -p_amount_baisa end, btrim(p_note), (select auth.uid()))
  returning id into v_id;
  perform app.post_journal(v_sess.organization_id, v_sess.branch_id, v_sess.business_day_id, 'cash_movement', v_id, btrim(p_note),
    case when p_type = 'cash_in' then jsonb_build_array(jsonb_build_array('cash_on_hand', p_amount_baisa, 0), jsonb_build_array('misc_income', 0, p_amount_baisa))
         else jsonb_build_array(jsonb_build_array('misc_expense', p_amount_baisa, 0), jsonb_build_array('cash_on_hand', 0, p_amount_baisa)) end);
  perform app.audit(v_sess.organization_id, v_sess.branch_id, 'cash.' || p_type, 'cash_session', v_sess.id, btrim(p_note), null, jsonb_build_object('amount_baisa', p_amount_baisa));
  return app.op_store(p_operation_id, v_sess.organization_id, v_sess.branch_id, v_sess.id, 'cash_movement', v_hash,
    jsonb_build_object('status', 'recorded', 'type', p_type, 'amount_baisa', p_amount_baisa, 'drawer_baisa', v_drawer + case when p_type = 'cash_in' then p_amount_baisa else -p_amount_baisa end));
end $$;

-- ───────────── المرتجع والإلغاء ─────────────
-- الكميات والمبالغ المتبقية القابلة للإرجاع لكل سطر، وسجل المرتجعات السابقة.
create or replace function public.invoice_refund_state(p_invoice_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select case when not app.has_perm(i.branch_id, 'invoice.view') then null else jsonb_build_object(
    'invoice_id', i.id, 'status', i.status,
    'lines', (select jsonb_agg(jsonb_build_object('line_no', l.line_no, 'description_ar', l.description_ar, 'kind', l.kind, 'unit', l.unit, 'qty', l.qty,
        'total_baisa', l.total_baisa, 'refunded_qty', coalesce(r.q, 0), 'refunded_baisa', coalesce(r.a, 0),
        'remaining_qty', l.qty - coalesce(r.q, 0), 'remaining_baisa', l.total_baisa - coalesce(r.a, 0),
        'track_stock', (select track_stock from public.products where id = l.product_id)) order by l.line_no)
      from public.invoice_lines l left join lateral (select sum(qty) q, sum(amount_baisa) a from public.refund_lines where invoice_line_id = l.id) r on true
      where l.invoice_id = i.id),
    'refunds', coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'refund_no', f.refund_no, 'kind', f.kind, 'method', f.method, 'reason', f.reason,
        'amount_baisa', f.amount_baisa, 'created_at', f.created_at, 'created_by_name', (select full_name from public.profiles where id = f.created_by)) order by f.created_at)
      from public.refunds f where f.invoice_id = i.id), '[]'::jsonb),
    'open_sessions', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'device_name', d.name, 'opened_by_name', (select full_name from public.profiles where id = s.opened_by)))
      from public.cash_sessions s join public.devices d on d.id = s.device_id where s.branch_id = i.branch_id and s.status = 'open'), '[]'::jsonb)) end
  from public.invoices i where i.id = p_invoice_id;
$$;

-- p_payload: { invoice_id, kind:'refund'|'void', reason, method:'cash'|'card', cash_session_id? (مطلوب للنقدي),
--              lines:[{line_no, qty, restock}] (للمرتجع؛ الإلغاء يشمل كل البنود ويعيد البضاعة للمخزون) }
-- يُرحَّل إلى اليوم المحاسبي المفتوح حاليًا للفرع مع ربطه بالفاتورة الأصلية.
create or replace function public.refund_invoice(p_operation_id uuid, p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid()); v_hash text := md5(p_payload::text); v_r jsonb;
  v_inv public.invoices; v_kind text := p_payload->>'kind'; v_method text := p_payload->>'method'; v_reason text := btrim(coalesce(p_payload->>'reason', ''));
  v_sess public.cash_sessions; v_day public.business_days; v_id uuid := gen_random_uuid(); v_seq bigint; v_no text; v_prefix text;
  v_req jsonb; l record; v_qty numeric(12,3); v_restock boolean; v_amt bigint; v_tax bigint; v_net bigint; v_cost bigint; v_line_cost bigint; v_prev_cost bigint;
  v_tot_net bigint := 0; v_tot_tax bigint := 0; v_tot_amt bigint := 0; v_net_goods bigint := 0; v_net_serv bigint := 0; v_cost_back bigint := 0;
  v_lot uuid; v_src record; v_n int := 0; v_cust public.customers; v_lines jsonb := '[]'::jsonb;
begin
  v_r := app.op_replay(p_operation_id, 'refund', v_hash); if v_r is not null then return v_r; end if;
  if v_kind not in ('refund', 'void') or v_method not in ('cash', 'card') then perform app.fail('INVALID_REQUEST'); end if;
  select * into v_inv from public.invoices where id = (p_payload->>'invoice_id')::uuid for update;
  if not found or not app.has_perm(v_inv.branch_id, 'invoice.view') then perform app.fail('NOT_FOUND'); end if;
  if not app.has_perm(v_inv.branch_id, case when v_kind = 'void' then 'invoice.void' else 'invoice.refund' end) then perform app.fail('FORBIDDEN'); end if;
  if v_inv.status <> 'approved' then perform app.fail('INVOICE_NOT_REFUNDABLE'); end if;
  if v_reason = '' then perform app.fail('REASON_REQUIRED'); end if;
  if v_kind = 'void' and exists (select 1 from public.refunds where invoice_id = v_inv.id) then perform app.fail('INVOICE_HAS_REFUNDS'); end if;

  select * into v_day from public.business_days where branch_id = v_inv.branch_id and status = 'open';
  if not found then perform app.fail('BUSINESS_DAY_CLOSED'); end if;
  if v_method = 'cash' then
    select * into v_sess from public.cash_sessions where id = (p_payload->>'cash_session_id')::uuid for update;
    if not found or v_sess.branch_id <> v_inv.branch_id or v_sess.status <> 'open' then perform app.fail('SESSION_CLOSED'); end if;
  end if;

  select invoice_prefix into v_prefix from public.branch_settings where branch_id = v_inv.branch_id;
  insert into public.branch_counters (branch_id, counter_key, last_value) values (v_inv.branch_id, 'refund', 1)
  on conflict (branch_id, counter_key) do update set last_value = public.branch_counters.last_value + 1 returning last_value into v_seq;
  v_no := 'R-' || v_prefix || '-' || to_char(v_day.business_date, 'YY') || '-' || lpad(v_seq::text, 6, '0');

  for l in
    select il.*, p.track_stock, p.whole_units_only, coalesce(c.cost_baisa, 0) as line_cost,
           coalesce(r.q, 0) as ref_qty, coalesce(r.a, 0) as ref_amt, coalesce(r.t, 0) as ref_tax, coalesce(r.c, 0) as ref_cost
    from public.invoice_lines il join public.products p on p.id = il.product_id
    left join public.invoice_line_costs c on c.invoice_line_id = il.id
    left join lateral (select sum(qty) q, sum(amount_baisa) a, sum(tax_baisa) t, sum(cost_baisa) filter (where restocked) c
                       from public.refund_lines where invoice_line_id = il.id) r on true
    where il.invoice_id = v_inv.id order by il.line_no
  loop
    if v_kind = 'void' then v_qty := l.qty; v_restock := l.track_stock;
    else
      select x into v_req from jsonb_array_elements(coalesce(p_payload->'lines', '[]'::jsonb)) x where (x->>'line_no')::int = l.line_no limit 1;
      continue when v_req is null;
      v_qty := (v_req->>'qty')::numeric; v_restock := l.track_stock and coalesce((v_req->>'restock')::boolean, false);
      v_req := null;
    end if;
    if v_qty is null or v_qty <= 0 or (l.whole_units_only and v_qty <> trunc(v_qty)) or v_qty > l.qty - l.ref_qty then
      perform app.fail('REFUND_EXCEEDS_REMAINING', jsonb_build_object('line_no', l.line_no, 'remaining_qty', l.qty - l.ref_qty)); end if;
    -- آخر كمية متبقية تأخذ الباقي بالضبط حتى لا يتراكم فرق تقريب
    if v_qty = l.qty - l.ref_qty then
      v_amt := l.total_baisa - l.ref_amt; v_tax := l.tax_baisa - l.ref_tax;
    else
      v_amt := app.round_baisa(l.total_baisa * v_qty / l.qty); v_tax := app.round_baisa(l.tax_baisa * v_qty / l.qty);
    end if;
    v_net := v_amt - v_tax; v_line_cost := 0;
    if v_restock then
      v_line_cost := app.round_baisa(l.line_cost * v_qty / l.qty);
      select m.lot_id, lt.dot_code, lt.lot_code into v_src from public.stock_movements m join public.inventory_lots lt on lt.id = m.lot_id
      where m.source_type = 'invoice' and m.source_id = v_inv.id and m.product_id = l.product_id and m.movement_type = 'sale' order by m.id limit 1;
      insert into public.inventory_lots (organization_id, branch_id, product_id, lot_code, dot_code, unit_cost_baisa, qty_received, qty_on_hand)
      values (v_inv.organization_id, v_inv.branch_id, l.product_id, coalesce(v_src.lot_code, 'RET'), v_src.dot_code,
        app.round_baisa(v_line_cost / v_qty), v_qty, v_qty) returning id into v_lot;
      insert into public.stock_movements (organization_id, branch_id, product_id, lot_id, movement_type, qty_delta, unit_cost_baisa, source_type, source_id, created_by)
      values (v_inv.organization_id, v_inv.branch_id, l.product_id, v_lot, case when v_kind = 'void' then 'void_reversal' else 'sale_return' end,
        v_qty, app.round_baisa(v_line_cost / v_qty), 'refund', v_id, v_uid);
      v_cost_back := v_cost_back + v_line_cost;
    end if;
    v_lines := v_lines || jsonb_build_object('id', l.id, 'qty', v_qty, 'net', v_net, 'tax', v_tax, 'amt', v_amt, 'restock', v_restock, 'cost', v_line_cost);
    v_tot_net := v_tot_net + v_net; v_tot_tax := v_tot_tax + v_tax; v_tot_amt := v_tot_amt + v_amt; v_n := v_n + 1;
    if l.kind = 'service' then v_net_serv := v_net_serv + v_net; else v_net_goods := v_net_goods + v_net; end if;
  end loop;
  if v_n = 0 then perform app.fail('EMPTY_CART'); end if;

  insert into public.refunds (id, organization_id, branch_id, invoice_id, refund_no, kind, business_day_id, cash_session_id, method, reason,
    net_baisa, tax_baisa, amount_baisa, created_by, operation_id)
  values (v_id, v_inv.organization_id, v_inv.branch_id, v_inv.id, v_no, v_kind, v_day.id, v_sess.id, v_method, v_reason,
    v_tot_net, v_tot_tax, v_tot_amt, v_uid, p_operation_id);
  insert into public.refund_lines (refund_id, organization_id, branch_id, invoice_line_id, qty, net_baisa, tax_baisa, amount_baisa, restocked, cost_baisa)
  select v_id, v_inv.organization_id, v_inv.branch_id, (x->>'id')::uuid, (x->>'qty')::numeric, (x->>'net')::bigint, (x->>'tax')::bigint,
         (x->>'amt')::bigint, (x->>'restock')::boolean, (x->>'cost')::bigint
  from jsonb_array_elements(v_lines) x;

  if v_method = 'cash' and v_tot_amt > 0 then
    insert into public.cash_movements (organization_id, branch_id, cash_session_id, movement_type, amount_baisa, source_type, source_id, note, created_by)
    values (v_inv.organization_id, v_inv.branch_id, v_sess.id, 'refund', -v_tot_amt, 'refund', v_id, v_no, v_uid);
  end if;
  perform app.post_journal(v_inv.organization_id, v_inv.branch_id, v_day.id, 'refund', v_id,
    case when v_kind = 'void' then 'إلغاء الفاتورة ' else 'مرتجع من الفاتورة ' end || v_inv.invoice_no,
    jsonb_build_array(jsonb_build_array('sales_goods', v_net_goods, 0), jsonb_build_array('sales_services', v_net_serv, 0),
      jsonb_build_array('vat_output', v_tot_tax, 0),
      jsonb_build_array(case when v_method = 'cash' then 'cash_on_hand' else 'card_clearing' end, 0, v_tot_amt),
      jsonb_build_array('inventory', v_cost_back, 0), jsonb_build_array('cogs', 0, v_cost_back)));

  if v_kind = 'void' then
    update public.invoices set status = 'voided', version = version + 1 where id = v_inv.id;
    if v_inv.customer_id is not null then
      select * into v_cust from public.customers where id = v_inv.customer_id;
      if v_cust.phone is not null then
        insert into public.notification_events (organization_id, branch_id, event_type, customer_id, invoice_id, lang, payload)
        values (v_inv.organization_id, v_inv.branch_id, 'invoice_voided', v_cust.id, v_inv.id, v_cust.preferred_lang, jsonb_build_object('invoice_no', v_inv.invoice_no));
      end if;
    end if;
  end if;
  perform app.audit(v_inv.organization_id, v_inv.branch_id, case when v_kind = 'void' then 'invoice.void' else 'invoice.refund' end, 'invoice', v_inv.id, v_reason,
    jsonb_build_object('status', v_inv.status), jsonb_build_object('refund_no', v_no, 'amount_baisa', v_tot_amt, 'method', v_method,
      'status', case when v_kind = 'void' then 'voided' else 'approved' end));
  return app.op_store(p_operation_id, v_inv.organization_id, v_inv.branch_id, v_sess.id, 'refund', v_hash,
    jsonb_build_object('status', case when v_kind = 'void' then 'voided' else 'refunded' end, 'refund_id', v_id, 'refund_no', v_no,
      'net_baisa', v_tot_net, 'tax_baisa', v_tot_tax, 'amount_baisa', v_tot_amt, 'restocked_cost_baisa', v_cost_back));
end $$;

-- المؤشرات: الفواتير الملغاة مستبعدة، والمرتجعات تُطرح في يومها المحاسبي.
create or replace function public.dashboard_summary(p_branch_id uuid, p_from date, p_to date) returns jsonb
language sql stable security definer set search_path = '' as $$
  with inv as (
    select i.*, app.has_perm(i.branch_id, 'inventory.cost.view') as can_cost
    from public.invoices i join public.business_days d on d.id = i.business_day_id
    where d.business_date between p_from and p_to and i.status = 'approved'
      and (p_branch_id is null or i.branch_id = p_branch_id) and app.has_perm(i.branch_id, 'reports.view')),
  ref as (
    select f.* from public.refunds f join public.business_days d on d.id = f.business_day_id
    where d.business_date between p_from and p_to and f.kind = 'refund'
      and (p_branch_id is null or f.branch_id = p_branch_id) and app.has_perm(f.branch_id, 'reports.view')),
  t as (select (select coalesce(sum(net_baisa), 0) from inv) net, (select coalesce(sum(net_baisa), 0) from ref) rnet,
               (select coalesce(sum(rl.cost_baisa), 0) from public.refund_lines rl join ref on ref.id = rl.refund_id where rl.restocked) rcost)
  select jsonb_build_object(
    'invoice_count', (select count(*) from inv),
    'net_sales_baisa', t.net - t.rnet,
    'refunds_baisa', (select coalesce(sum(amount_baisa), 0) from ref),
    'tax_baisa', (select coalesce(sum(tax_baisa), 0) from inv) - (select coalesce(sum(tax_baisa), 0) from ref),
    'total_baisa', (select coalesce(sum(total_baisa), 0) from inv),
    'discount_baisa', (select coalesce(sum(discount_baisa), 0) from inv),
    'cash_baisa', (select coalesce(sum(p.amount_baisa), 0) from public.payments p join inv on inv.id = p.invoice_id where p.method = 'cash'),
    'card_baisa', (select coalesce(sum(p.amount_baisa), 0) from public.payments p join inv on inv.id = p.invoice_id where p.method = 'card'),
    'gross_profit_baisa', case when (select bool_and(can_cost) from inv) then
        t.net - t.rnet - ((select coalesce(sum(c.cost_baisa), 0) from public.invoice_line_costs c
           join public.invoice_lines l on l.id = c.invoice_line_id join inv on inv.id = l.invoice_id) - t.rcost) end)
  from t;
$$;

revoke all on function public.save_product(jsonb), public.set_branch_price(uuid, uuid, bigint), public.stock_report(uuid), public.save_supplier(jsonb),
  public.receive_purchase(uuid, jsonb), public.adjust_stock(uuid, uuid, uuid, numeric, bigint, text), public.save_customer(jsonb),
  public.save_draft(uuid, uuid, text, bigint, jsonb), public.list_drafts(uuid), public.delete_draft(uuid, text),
  public.record_cash_movement(uuid, uuid, text, bigint, text), public.invoice_refund_state(uuid), public.refund_invoice(uuid, jsonb) from public, anon;
grant execute on function public.save_product(jsonb), public.set_branch_price(uuid, uuid, bigint), public.stock_report(uuid), public.save_supplier(jsonb),
  public.receive_purchase(uuid, jsonb), public.adjust_stock(uuid, uuid, uuid, numeric, bigint, text), public.save_customer(jsonb),
  public.save_draft(uuid, uuid, text, bigint, jsonb), public.list_drafts(uuid), public.delete_draft(uuid, text),
  public.record_cash_movement(uuid, uuid, text, bigint, text), public.invoice_refund_state(uuid), public.refund_invoice(uuid, jsonb) to authenticated, service_role;
