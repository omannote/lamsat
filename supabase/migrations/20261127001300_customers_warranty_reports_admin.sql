-- العملاء والضمان، تصنيف المصروفات، لوحة المالك، تقرير الضريبة، التحويل بين الفرعين، وإدارة المستخدمين.

-- ───────────── الضمان ─────────────
alter table public.products add column warranty_months int check (warranty_months between 0 and 120);

create table public.warranties (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null, branch_id uuid not null,
  invoice_id uuid not null references public.invoices(id),
  invoice_line_id uuid not null unique references public.invoice_lines(id),
  customer_id uuid, vehicle_id uuid,
  warranty_no text not null, product_name text not null, months int not null,
  starts_on date not null, expires_on date not null,
  created_at timestamptz not null default now(),
  unique (organization_id, warranty_no));
create index warranties_customer_idx on public.warranties (customer_id);
create index warranties_invoice_idx on public.warranties (invoice_id);
alter table public.warranties enable row level security;
create policy warranties_read on public.warranties for select to authenticated using (app.has_perm(branch_id, 'invoice.view'));

-- كل بند مباع من صنف له مدة ضمان يُصدر له ضمان مرتبط بالفاتورة والعميل والمركبة
create or replace function app.issue_warranty() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_m int; v_inv public.invoices; v_day date := (now() at time zone 'Asia/Muscat')::date;
begin
  select warranty_months into v_m from public.products where id = new.product_id;
  if coalesce(v_m, 0) <= 0 then return new; end if;
  select * into v_inv from public.invoices where id = new.invoice_id;
  insert into public.warranties (organization_id, branch_id, invoice_id, invoice_line_id, customer_id, vehicle_id, warranty_no, product_name, months, starts_on, expires_on)
  values (new.organization_id, new.branch_id, new.invoice_id, new.id, v_inv.customer_id, v_inv.vehicle_id,
    'W-' || v_inv.invoice_no || '-' || new.line_no, new.description_ar, v_m, v_day, (v_day + make_interval(months => v_m))::date);
  return new;
end $$;
create trigger invoice_lines_issue_warranty after insert on public.invoice_lines for each row execute function app.issue_warranty();

-- ───────────── تصنيف المصروفات ─────────────
alter table public.cash_movements add column category text;
create or replace function app.cash_movement_category() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.category is null and new.movement_type in ('cash_in', 'cash_out') and new.source_type is null then
    new.category := nullif(current_setting('app.cash_category', true), '');
  end if;
  return new;
end $$;
create trigger cash_movements_category before insert on public.cash_movements for each row execute function app.cash_movement_category();

create or replace function public.record_cash_movement_cat(p_operation_id uuid, p_cash_session_id uuid, p_type text, p_amount_baisa bigint, p_note text, p_category text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_r jsonb;
begin
  perform set_config('app.cash_category', coalesce(btrim(p_category), ''), true);
  v_r := public.record_cash_movement(p_operation_id, p_cash_session_id, p_type, p_amount_baisa, p_note);
  perform set_config('app.cash_category', '', true);
  return v_r;
end $$;

-- حركات الدرج غير البيع في وردية (مصروفات، قبض، مرتجعات، مشتريات نقدية، تحصيل)
create or replace function public.session_movements(p_cash_session_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_sess public.cash_sessions;
begin
  select * into v_sess from public.cash_sessions where id = p_cash_session_id;
  if not found or not (app.can_close_session(v_sess.branch_id, v_sess.opened_by) or app.has_perm(v_sess.branch_id, 'reports.view')) then
    perform app.fail('NOT_FOUND'); end if;
  return coalesce((select jsonb_agg(jsonb_build_object('at', m.created_at, 'type', m.movement_type, 'source_type', m.source_type,
      'category', m.category, 'note', m.note, 'amount_baisa', m.amount_baisa) order by m.created_at)
    from public.cash_movements m where m.cash_session_id = v_sess.id and m.movement_type not in ('opening', 'sale', 'closing')), '[]'::jsonb);
end $$;

-- ───────────── تعديل الدوال القائمة في موضعها ─────────────
do $$
declare d text; r record;
begin
  for r in select * from (values
    ('public.save_product(jsonb)', 'if p_product ?| array[''default_supplier_id'', ', 'if p_product ?| array[''warranty_months'', ''default_supplier_id'', '),
    ('public.save_product(jsonb)', '      tire_year = case when p_product ? ''tire_year''',
       '      warranty_months = case when p_product ? ''warranty_months'' then (p_product->>''warranty_months'')::int else warranty_months end,
      tire_year = case when p_product ? ''tire_year'''),
    ('app.invoice_json(uuid)', '''note'', i.note, ''print_count'', i.print_count,',
       '''note'', i.note, ''print_count'', i.print_count,
    ''warranties'', coalesce((select jsonb_agg(jsonb_build_object(''warranty_no'', w.warranty_no, ''product_name'', w.product_name, ''months'', w.months,
        ''starts_on'', w.starts_on, ''expires_on'', w.expires_on) order by w.warranty_no) from public.warranties w where w.invoice_id = i.id), ''[]''::jsonb),')
  ) as t(fn, target, repl) loop
    d := pg_get_functiondef(r.fn::regprocedure);
    if position(r.target in d) = 0 then raise exception 'patch target missing in %: %', r.fn, r.target; end if;
    execute replace(d, r.target, r.repl);
  end loop;
end $$;

-- ───────────── ملف العميل ─────────────
create or replace function public.add_vehicle(p_branch_id uuid, p_customer_id uuid, p_plate text, p_make text, p_model text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_org uuid; v_veh public.vehicles; v_plate text := nullif(btrim(p_plate), '');
begin
  select organization_id into v_org from public.branches where id = p_branch_id;
  if v_org is null or not app.has_perm(p_branch_id, 'pos.sell') then perform app.fail('FORBIDDEN'); end if;
  if v_plate is null then perform app.fail('INVALID_REQUEST'); end if;
  if not exists (select 1 from public.customers where id = p_customer_id and organization_id = v_org) then perform app.fail('CUSTOMER_NOT_FOUND'); end if;
  select * into v_veh from public.vehicles where organization_id = v_org and customer_id = p_customer_id and plate = v_plate;
  if not found then
    insert into public.vehicles (organization_id, customer_id, plate, make, model)
    values (v_org, p_customer_id, v_plate, nullif(btrim(p_make), ''), nullif(btrim(p_model), '')) returning * into v_veh;
  end if;
  return to_jsonb(v_veh);
end $$;

-- العميل ومركباته وضماناته ورصيده الآجل وكشف حسابه وآخر فواتيره (ضمن الفروع المتاحة للمستخدم)
create or replace function public.customer_profile(p_customer_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_c public.customers; v_today date := (now() at time zone 'Asia/Muscat')::date;
begin
  select * into v_c from public.customers where id = p_customer_id;
  if not found or not app.has_org(v_c.organization_id) then perform app.fail('CUSTOMER_NOT_FOUND'); end if;
  return jsonb_build_object(
    'customer', jsonb_build_object('id', v_c.id, 'name', v_c.name, 'phone', v_c.phone, 'notes', v_c.notes),
    'balance_baisa', app.customer_balance(v_c.id),
    'vehicles', coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'plate', v.plate, 'make', v.make, 'model', v.model) order by v.created_at)
      from public.vehicles v where v.customer_id = v_c.id), '[]'::jsonb),
    'warranties', coalesce((select jsonb_agg(jsonb_build_object('warranty_no', w.warranty_no, 'product_name', w.product_name, 'months', w.months,
        'starts_on', w.starts_on, 'expires_on', w.expires_on, 'active', w.expires_on >= v_today, 'invoice_id', w.invoice_id,
        'plate', (select plate from public.vehicles where id = w.vehicle_id)) order by w.expires_on desc)
      from public.warranties w where w.customer_id = v_c.id and app.has_perm(w.branch_id, 'invoice.view')), '[]'::jsonb),
    'invoices', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'invoice_no', i.invoice_no, 'status', i.status, 'approved_at', i.approved_at,
        'total_baisa', i.total_baisa, 'plate', (select plate from public.vehicles where id = i.vehicle_id)) order by i.approved_at desc)
      from (select * from public.invoices where customer_id = v_c.id order by approved_at desc limit 50) i where app.has_perm(i.branch_id, 'invoice.view')), '[]'::jsonb),
    'statement', coalesce((select jsonb_agg(jsonb_build_object('at', s.at, 'kind', s.kind, 'ref', s.ref, 'debit_baisa', s.debit, 'credit_baisa', s.credit) order by s.at)
      from (
        select p.created_at as at, 'sale' as kind, i.invoice_no as ref, p.amount_baisa as debit, 0::bigint as credit
          from public.payments p join public.invoices i on i.id = p.invoice_id where i.customer_id = v_c.id and p.method = 'credit'
        union all
        select f.created_at, 'refund', f.refund_no, 0, f.amount_baisa
          from public.refunds f join public.invoices i on i.id = f.invoice_id where i.customer_id = v_c.id and f.method = 'credit'
        union all
        select r.created_at, 'receipt', coalesce(r.reference, r.method), 0, r.amount_baisa from public.customer_receipts r where r.customer_id = v_c.id
      ) s), '[]'::jsonb));
end $$;

-- ───────────── التحويل بين الفرعين ─────────────
-- يُخصم من الفرع المصدر FIFO ويُضاف للفرع المستلم بالتكلفة نفسها فورًا (بلا مرحلة «في الطريق»).
create or replace function public.transfer_stock(p_operation_id uuid, p_from_branch uuid, p_to_branch uuid, p_product_id uuid, p_qty numeric, p_note text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); v_org uuid; v_org2 uuid; v_prod public.products; v_r jsonb; v_lot record; v_new uuid;
  v_need numeric(12,3); v_take numeric(12,3); v_ref uuid := gen_random_uuid(); v_value bigint := 0;
  v_hash text := md5(jsonb_build_object('f', p_from_branch, 't', p_to_branch, 'p', p_product_id, 'q', p_qty, 'n', p_note)::text);
begin
  v_r := app.op_replay(p_operation_id, 'stock_transfer', v_hash); if v_r is not null then return v_r; end if;
  select organization_id into v_org from public.branches where id = p_from_branch;
  select organization_id into v_org2 from public.branches where id = p_to_branch and is_active;
  if v_org is null or not app.has_perm(p_from_branch, 'inventory.manage') then perform app.fail('FORBIDDEN'); end if;
  if v_org2 is distinct from v_org or p_from_branch = p_to_branch then perform app.fail('INVALID_REQUEST'); end if;
  select * into v_prod from public.products where id = p_product_id and organization_id = v_org and track_stock;
  if not found then perform app.fail('PRODUCT_NOT_FOUND'); end if;
  if p_qty is null or p_qty <= 0 or (v_prod.whole_units_only and p_qty <> trunc(p_qty)) then perform app.fail('INVALID_QUANTITY'); end if;
  v_need := p_qty;
  for v_lot in select id, qty_on_hand, unit_cost_baisa, lot_code, dot_code from public.inventory_lots
               where branch_id = p_from_branch and product_id = p_product_id and qty_on_hand > 0 order by received_at, id for update loop
    v_take := least(v_need, v_lot.qty_on_hand);
    update public.inventory_lots set qty_on_hand = qty_on_hand - v_take where id = v_lot.id;
    insert into public.stock_movements (organization_id, branch_id, product_id, lot_id, movement_type, qty_delta, unit_cost_baisa, source_type, source_id, created_by)
    values (v_org, p_from_branch, p_product_id, v_lot.id, 'transfer_out', -v_take, v_lot.unit_cost_baisa, 'transfer', v_ref, v_uid);
    insert into public.inventory_lots (organization_id, branch_id, product_id, lot_code, dot_code, unit_cost_baisa, qty_received, qty_on_hand)
    values (v_org, p_to_branch, p_product_id, coalesce(v_lot.lot_code, 'TRF'), v_lot.dot_code, v_lot.unit_cost_baisa, v_take, v_take) returning id into v_new;
    insert into public.stock_movements (organization_id, branch_id, product_id, lot_id, movement_type, qty_delta, unit_cost_baisa, source_type, source_id, created_by)
    values (v_org, p_to_branch, p_product_id, v_new, 'transfer_in', v_take, v_lot.unit_cost_baisa, 'transfer', v_ref, v_uid);
    v_value := v_value + app.round_baisa(v_take * v_lot.unit_cost_baisa); v_need := v_need - v_take; exit when v_need = 0;
  end loop;
  if v_need > 0 then perform app.fail('INSUFFICIENT_STOCK', jsonb_build_object('name_ar', v_prod.name_ar, 'requested', p_qty, 'available', p_qty - v_need)); end if;
  perform app.audit(v_org, p_from_branch, 'stock.transfer', 'product', p_product_id, nullif(btrim(p_note), ''), null,
    jsonb_build_object('to_branch', p_to_branch, 'qty', p_qty, 'value_baisa', v_value));
  return app.op_store(p_operation_id, v_org, p_from_branch, null, 'stock_transfer', v_hash,
    jsonb_build_object('status', 'transferred', 'qty', p_qty, 'value_baisa', v_value));
end $$;

-- ───────────── لوحة المالك ─────────────
create or replace function public.owner_dashboard(p_from date, p_to date) returns jsonb
language sql stable security definer set search_path = '' as $$
  with br as (select b.* from public.branches b where b.is_active and app.has_perm(b.id, 'reports.view')),
  inv as (select i.*, d.business_date from public.invoices i join public.business_days d on d.id = i.business_day_id
          where i.branch_id in (select id from br) and i.status = 'approved' and d.business_date between p_from and p_to),
  ref as (select f.* from public.refunds f join public.business_days d on d.id = f.business_day_id
          where f.branch_id in (select id from br) and f.kind = 'refund' and d.business_date between p_from and p_to)
  select jsonb_build_object(
    'branches', coalesce((select jsonb_agg(jsonb_build_object('branch_id', b.id, 'name_ar', b.name_ar,
        'invoice_count', (select count(*) from inv where inv.branch_id = b.id),
        'total_baisa', (select coalesce(sum(total_baisa), 0) from inv where inv.branch_id = b.id),
        'net_baisa', (select coalesce(sum(net_baisa), 0) from inv where inv.branch_id = b.id) - (select coalesce(sum(net_baisa), 0) from ref where ref.branch_id = b.id),
        'gross_profit_baisa', case when app.has_perm(b.id, 'inventory.cost.view') then
            (select coalesce(sum(net_baisa), 0) from inv where inv.branch_id = b.id) - (select coalesce(sum(net_baisa), 0) from ref where ref.branch_id = b.id)
            - (select coalesce(sum(c.cost_baisa), 0) from public.invoice_line_costs c join public.invoice_lines l on l.id = c.invoice_line_id join inv on inv.id = l.invoice_id where inv.branch_id = b.id)
            + (select coalesce(sum(rl.cost_baisa), 0) from public.refund_lines rl join ref on ref.id = rl.refund_id where ref.branch_id = b.id and rl.restocked) end,
        'low_stock', (select count(*) from public.products p where p.organization_id = b.organization_id and p.track_stock and p.is_active
            and coalesce((select sum(qty_on_hand) from public.inventory_lots where branch_id = b.id and product_id = p.id), 0) <= coalesce(p.reorder_level, 3))
      ) order by b.code) from br b), '[]'::jsonb),
    'top_products', coalesce((select jsonb_agg(t) from (
        select l.description_ar as name_ar, sum(l.qty) as qty, sum(l.net_baisa) as net_baisa
        from public.invoice_lines l join inv on inv.id = l.invoice_id group by l.description_ar order by sum(l.net_baisa) desc limit 8) t), '[]'::jsonb),
    'series', coalesce((select jsonb_agg(jsonb_build_object('date', g.d::date, 'total_baisa',
          (select coalesce(sum(i.total_baisa), 0) from public.invoices i join public.business_days bd on bd.id = i.business_day_id
           where i.branch_id in (select id from br) and i.status = 'approved' and bd.business_date = g.d::date)) order by g.d)
      from generate_series(p_to - 6, p_to, interval '1 day') g(d)), '[]'::jsonb),
    'receivables_baisa', (select coalesce(sum(app.customer_balance(c.id)), 0) from public.customers c
        where c.organization_id in (select organization_id from br) and exists (select 1 from public.payments p join public.invoices i on i.id = p.invoice_id where i.customer_id = c.id and p.method = 'credit')),
    'payables_baisa', (select coalesce(sum(app.supplier_balance(s.id)), 0) from public.suppliers s where s.organization_id in (select organization_id from br)
        and exists (select 1 from br where app.has_perm(br.id, 'inventory.cost.view'))));
$$;

-- ───────────── تقرير ضريبة القيمة المضافة ─────────────
-- المخرجات من الفواتير المعتمدة ناقص المرتجعات حسب اليوم المحاسبي؛ المدخلات من المشتريات حسب تاريخ فاتورة المورّد.
create or replace function public.vat_report(p_branch_id uuid, p_from date, p_to date) returns jsonb
language sql stable security definer set search_path = '' as $$
  with br as (select b.id from public.branches b where (p_branch_id is null or b.id = p_branch_id) and app.has_perm(b.id, 'reports.view')),
  o as (select to_char(d.business_date, 'YYYY-MM') m, i.net_baisa net, i.tax_baisa tax from public.invoices i join public.business_days d on d.id = i.business_day_id
        where i.branch_id in (select id from br) and i.status = 'approved' and d.business_date between p_from and p_to
        union all
        select to_char(d.business_date, 'YYYY-MM'), -f.net_baisa, -f.tax_baisa from public.refunds f join public.business_days d on d.id = f.business_day_id
        where f.branch_id in (select id from br) and f.kind = 'refund' and d.business_date between p_from and p_to),
  i as (select to_char(coalesce(r.supplier_invoice_date, (r.created_at at time zone 'Asia/Muscat')::date), 'YYYY-MM') m, r.total_cost_baisa net, r.tax_baisa tax
        from public.purchase_receipts r where r.branch_id in (select id from br)
          and coalesce(r.supplier_invoice_date, (r.created_at at time zone 'Asia/Muscat')::date) between p_from and p_to),
  months as (select m from o union select m from i)
  select jsonb_build_object(
    'from', p_from, 'to', p_to,
    'months', coalesce((select jsonb_agg(jsonb_build_object('month', mm.m,
        'sales_net_baisa', (select coalesce(sum(net), 0) from o where o.m = mm.m), 'output_tax_baisa', (select coalesce(sum(tax), 0) from o where o.m = mm.m),
        'purchases_net_baisa', (select coalesce(sum(net), 0) from i where i.m = mm.m), 'input_tax_baisa', (select coalesce(sum(tax), 0) from i where i.m = mm.m)) order by mm.m)
      from months mm), '[]'::jsonb),
    'sales_net_baisa', (select coalesce(sum(net), 0) from o), 'output_tax_baisa', (select coalesce(sum(tax), 0) from o),
    'purchases_net_baisa', (select coalesce(sum(net), 0) from i), 'input_tax_baisa', (select coalesce(sum(tax), 0) from i),
    'net_tax_baisa', (select coalesce(sum(tax), 0) from o) - (select coalesce(sum(tax), 0) from i));
$$;

-- ───────────── المستخدمون والصلاحيات ─────────────
create or replace function public.list_users(p_organization_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if not app.has_org_perm(p_organization_id, 'users.manage') then perform app.fail('FORBIDDEN'); end if;
  return coalesce((select jsonb_agg(jsonb_build_object('user_id', p.id, 'full_name', p.full_name, 'is_active', p.is_active,
      'username', (select split_part(u.email, '@', 1) from auth.users u where u.id = p.id),
      'memberships', (select jsonb_agg(jsonb_build_object('id', m.id, 'role_code', m.role_code, 'branch_id', m.branch_id,
          'branch_name', (select name_ar from public.branches where id = m.branch_id), 'max_discount_bp', m.max_discount_bp, 'is_active', m.is_active) order by m.created_at)
        from public.memberships m where m.user_id = p.id and m.organization_id = p_organization_id)) order by p.created_at)
    from public.profiles p where exists (select 1 from public.memberships m where m.user_id = p.id and m.organization_id = p_organization_id)), '[]'::jsonb);
end $$;

-- p: { organization_id, user_id, full_name?, is_active?, role_code, branch_id (null = كل الفروع), max_discount_bp }
-- للمستخدم دور واحد في المنشأة: يُستبدل ما قبله. لا يستطيع المدير تعطيل نفسه أو نزع دوره.
create or replace function public.save_user_role(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_org uuid := (p->>'organization_id')::uuid; v_user uuid := (p->>'user_id')::uuid; v_role text := p->>'role_code';
  v_branch uuid := (p->>'branch_id')::uuid; v_disc int := coalesce((p->>'max_discount_bp')::int, 0);
begin
  if v_org is null or not app.has_org_perm(v_org, 'users.manage') then perform app.fail('FORBIDDEN'); end if;
  if not exists (select 1 from public.profiles where id = v_user) or not exists (select 1 from public.roles where code = v_role) then perform app.fail('NOT_FOUND'); end if;
  if v_branch is not null and not exists (select 1 from public.branches where id = v_branch and organization_id = v_org) then perform app.fail('NOT_FOUND'); end if;
  if v_disc not between 0 and 10000 then perform app.fail('INVALID_AMOUNT'); end if;
  if v_user = (select auth.uid()) and (v_role <> 'owner' or coalesce((p->>'is_active')::boolean, true) = false) then perform app.fail('CANNOT_CHANGE_SELF'); end if;
  if v_role in ('cashier', 'branch_manager') and v_branch is null then perform app.fail('BRANCH_REQUIRED'); end if;
  update public.profiles set full_name = coalesce(nullif(btrim(p->>'full_name'), ''), full_name),
    is_active = coalesce((p->>'is_active')::boolean, is_active) where id = v_user;
  delete from public.memberships where user_id = v_user and organization_id = v_org;
  insert into public.memberships (organization_id, user_id, branch_id, role_code, max_discount_bp) values (v_org, v_user, v_branch, v_role, v_disc);
  perform app.audit(v_org, v_branch, 'user.role.save', 'user', v_user, null, null, p - 'organization_id');
  return jsonb_build_object('status', 'saved');
end $$;

revoke all on function public.record_cash_movement_cat(uuid, uuid, text, bigint, text, text), public.session_movements(uuid), public.add_vehicle(uuid, uuid, text, text, text),
  public.customer_profile(uuid), public.transfer_stock(uuid, uuid, uuid, uuid, numeric, text), public.owner_dashboard(date, date), public.vat_report(uuid, date, date),
  public.list_users(uuid), public.save_user_role(jsonb) from public, anon;
grant execute on function public.record_cash_movement_cat(uuid, uuid, text, bigint, text, text), public.session_movements(uuid), public.add_vehicle(uuid, uuid, text, text, text),
  public.customer_profile(uuid), public.transfer_stock(uuid, uuid, uuid, uuid, numeric, text), public.owner_dashboard(date, date), public.vat_report(uuid, date, date),
  public.list_users(uuid), public.save_user_role(jsonb) to authenticated;
grant execute on function public.save_user_role(jsonb), public.list_users(uuid) to service_role;
