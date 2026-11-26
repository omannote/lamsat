-- لمسات | دوال RPC: السياق، البحث، فتح الوردية، اعتماد البيع، التحقق من العملية، المؤشرات

-- ───────────── سياق المستخدم ─────────────
create or replace function public.my_context() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'user', (select jsonb_build_object('id', p.id, 'full_name', p.full_name)
             from public.profiles p where p.id = (select auth.uid()) and p.is_active),
    'branches', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', b.id, 'organization_id', b.organization_id, 'code', b.code,
        'name_ar', b.name_ar, 'name_en', b.name_en,
        'tax_enabled', s.tax_enabled, 'tax_rate_bp', s.tax_rate_bp, 'prices_include_tax', s.prices_include_tax,
        'roles', (select jsonb_agg(distinct m.role_code) from public.memberships m
                  where m.user_id = (select auth.uid()) and m.is_active and m.organization_id = b.organization_id
                    and (m.branch_id is null or m.branch_id = b.id)),
        'max_discount_bp', (select coalesce(max(m.max_discount_bp), 0) from public.memberships m
                  join public.role_permissions rp on rp.role_code = m.role_code and rp.permission_code = 'pos.discount'
                  where m.user_id = (select auth.uid()) and m.is_active and m.organization_id = b.organization_id
                    and (m.branch_id is null or m.branch_id = b.id)),
        'permissions', (select coalesce(jsonb_agg(distinct rp.permission_code), '[]'::jsonb)
                  from public.memberships m join public.role_permissions rp on rp.role_code = m.role_code
                  where m.user_id = (select auth.uid()) and m.is_active and m.organization_id = b.organization_id
                    and (m.branch_id is null or m.branch_id = b.id))
      ) order by b.code)
      from public.branches b join public.branch_settings s on s.branch_id = b.id
      where b.is_active and app.has_branch(b.id)), '[]'::jsonb));
$$;

-- ───────────── الجهاز والوردية الحالية ─────────────
create or replace function public.resolve_device(p_code text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_dev public.devices; v_sess public.cash_sessions;
begin
  select d.* into v_dev from public.devices d
  where d.code = p_code and d.is_active and app.has_branch(d.branch_id);
  if not found then perform app.fail('DEVICE_NOT_FOUND'); end if;
  select * into v_sess from public.cash_sessions where device_id = v_dev.id and status = 'open';
  return jsonb_build_object(
    'device', jsonb_build_object('id', v_dev.id, 'code', v_dev.code, 'name', v_dev.name, 'branch_id', v_dev.branch_id),
    'open_session', case when v_sess.id is null then null else jsonb_build_object(
        'id', v_sess.id, 'opened_by', v_sess.opened_by, 'opened_at', v_sess.opened_at,
        'opening_cash_baisa', v_sess.opening_cash_baisa, 'mine', v_sess.opened_by = (select auth.uid()),
        'opened_by_name', (select full_name from public.profiles where id = v_sess.opened_by)) end);
end $$;

create or replace function public.open_cash_session(p_operation_id uuid, p_device_id uuid, p_opening_cash_baisa bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_dev public.devices; v_day public.business_days; v_sess public.cash_sessions;
  v_op public.operation_requests; v_hash text; v_result jsonb; v_tz text;
begin
  if v_uid is null then perform app.fail('NOT_AUTHENTICATED'); end if;
  if p_operation_id is null then perform app.fail('INVALID_REQUEST'); end if;
  v_hash := md5(jsonb_build_object('device_id', p_device_id, 'opening', p_opening_cash_baisa)::text);

  select * into v_op from public.operation_requests where operation_id = p_operation_id;
  if found then
    if v_op.user_id <> v_uid or v_op.op_type <> 'open_session' or v_op.request_hash <> v_hash then
      perform app.fail('OPERATION_MISMATCH'); end if;
    return v_op.result || jsonb_build_object('replayed', true);
  end if;

  if p_opening_cash_baisa is null or p_opening_cash_baisa < 0 then perform app.fail('INVALID_AMOUNT'); end if;
  select * into v_dev from public.devices where id = p_device_id and is_active for update;
  if not found then perform app.fail('DEVICE_NOT_FOUND'); end if;
  if not app.has_perm(v_dev.branch_id, 'cash.open') then perform app.fail('FORBIDDEN'); end if;

  select * into v_sess from public.cash_sessions where device_id = v_dev.id and status = 'open';
  if found then
    perform app.fail('SESSION_ALREADY_OPEN', jsonb_build_object('session_id', v_sess.id, 'mine', v_sess.opened_by = v_uid));
  end if;

  -- اليوم المحاسبي: يُستخدم اليوم المفتوح إن وُجد (حتى بعد منتصف الليل)، وإلا يُفتح يوم بتاريخ مسقط
  select * into v_day from public.business_days where branch_id = v_dev.branch_id and status = 'open';
  if not found then
    select timezone into v_tz from public.organizations where id = v_dev.organization_id;
    insert into public.business_days (organization_id, branch_id, business_date, opened_by)
    values (v_dev.organization_id, v_dev.branch_id, (now() at time zone v_tz)::date, v_uid)
    on conflict (branch_id, business_date) do nothing
    returning * into v_day;
    if v_day.id is null then
      select * into v_day from public.business_days where branch_id = v_dev.branch_id and status = 'open';
      if not found then perform app.fail('BUSINESS_DAY_CLOSED'); end if;
    end if;
  end if;

  insert into public.cash_sessions (organization_id, branch_id, device_id, business_day_id, opened_by, opening_cash_baisa)
  values (v_dev.organization_id, v_dev.branch_id, v_dev.id, v_day.id, v_uid, p_opening_cash_baisa)
  returning * into v_sess;

  insert into public.cash_movements (organization_id, branch_id, cash_session_id, movement_type, amount_baisa, created_by)
  values (v_sess.organization_id, v_sess.branch_id, v_sess.id, 'opening', p_opening_cash_baisa, v_uid);

  perform app.audit(v_sess.organization_id, v_sess.branch_id, 'cash_session.open', 'cash_session', v_sess.id, null, null,
    jsonb_build_object('opening_cash_baisa', p_opening_cash_baisa, 'device', v_dev.code, 'business_date', v_day.business_date));

  v_result := jsonb_build_object('status', 'opened', 'session', jsonb_build_object(
    'id', v_sess.id, 'branch_id', v_sess.branch_id, 'device_id', v_sess.device_id, 'opened_at', v_sess.opened_at,
    'opening_cash_baisa', v_sess.opening_cash_baisa, 'business_day_id', v_day.id, 'business_date', v_day.business_date));

  insert into public.operation_requests (operation_id, organization_id, branch_id, device_id, cash_session_id, user_id, op_type, request_hash, result)
  values (p_operation_id, v_sess.organization_id, v_sess.branch_id, v_dev.id, v_sess.id, v_uid, 'open_session', v_hash, v_result);
  return v_result || jsonb_build_object('replayed', false);
end $$;

-- ───────────── السعر النافذ والبحث ─────────────
create or replace function app.effective_price(p_branch uuid, p_product uuid) returns bigint
language sql stable security definer set search_path = '' as $$
  select coalesce((select bp.price_baisa from public.branch_prices bp where bp.branch_id = p_branch and bp.product_id = p_product),
                  (select pr.base_price_baisa from public.products pr where pr.id = p_product));
$$;
revoke all on function app.effective_price(uuid, uuid) from public;
grant execute on function app.effective_price(uuid, uuid) to authenticated, service_role;

create or replace function public.pos_search(p_branch_id uuid, p_query text, p_limit int default 30)
returns table (product_id uuid, sku text, kind text, category text, name_ar text, name_en text, brand text,
               unit text, whole_units_only boolean, track_stock boolean, taxable boolean,
               tire_size text, unit_price_baisa bigint, stock_qty numeric, exact_barcode boolean)
language plpgsql stable security definer set search_path = '' as $$
#variable_conflict use_column
declare
  v_q text := btrim(coalesce(p_query, ''));
  v_digits text := regexp_replace(v_q, '[^0-9]', '', 'g');
  v_org uuid;
begin
  if not app.has_perm(p_branch_id, 'catalog.view') then perform app.fail('FORBIDDEN'); end if;
  select organization_id into v_org from public.branches where id = p_branch_id;
  return query
  select p.id, p.sku, p.kind, p.category, p.name_ar, p.name_en, p.brand, p.unit, p.whole_units_only,
         p.track_stock, p.taxable,
         case when p.tire_size_key is not null then p.tire_width || '/' || p.tire_aspect || 'R' || p.tire_rim end,
         app.effective_price(p_branch_id, p.id),
         case when p.track_stock then coalesce((select sum(l.qty_on_hand) from public.inventory_lots l
              where l.branch_id = p_branch_id and l.product_id = p.id), 0) end,
         exists (select 1 from public.product_barcodes pb where pb.organization_id = v_org and pb.product_id = p.id and pb.barcode = v_q)
  from public.products p
  where p.organization_id = v_org and p.is_active
    and (v_q = ''
      or exists (select 1 from public.product_barcodes pb where pb.organization_id = v_org and pb.product_id = p.id and pb.barcode = v_q)
      or p.sku ilike v_q || '%'
      or p.name_ar ilike '%' || v_q || '%'
      or p.name_en ilike '%' || v_q || '%'
      or p.brand ilike '%' || v_q || '%'
      or (length(v_digits) >= 3 and p.tire_size_key like v_digits || '%'))
  order by 15 desc, (p.sku ilike v_q) desc, p.category, p.name_ar
  limit least(greatest(coalesce(p_limit, 30), 1), 100);
end $$;

-- ───────────── تمثيل الفاتورة (للإيصال وإعادة الطباعة) ─────────────
create or replace function app.invoice_json(p_invoice_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', i.id, 'invoice_no', i.invoice_no, 'status', i.status, 'approved_at', i.approved_at,
    'business_date', d.business_date, 'branch_id', i.branch_id,
    'branch', jsonb_build_object('code', b.code, 'name_ar', b.name_ar, 'phone', b.phone, 'address_ar', b.address_ar,
       'receipt_header_ar', s.receipt_header_ar, 'receipt_footer_ar', s.receipt_footer_ar),
    'organization', jsonb_build_object('name_ar', o.name_ar, 'tax_registration_no', o.tax_registration_no),
    'cashier_name', (select full_name from public.profiles where id = i.cashier_id),
    'customer', (select jsonb_build_object('id', c.id, 'name', c.name, 'phone', c.phone) from public.customers c where c.id = i.customer_id),
    'vehicle', (select jsonb_build_object('id', v.id, 'plate', v.plate, 'make', v.make, 'model', v.model) from public.vehicles v where v.id = i.vehicle_id),
    'tax_rate_bp', i.tax_rate_bp, 'prices_include_tax', i.prices_include_tax,
    'subtotal_baisa', i.subtotal_baisa, 'discount_baisa', i.discount_baisa, 'net_baisa', i.net_baisa,
    'tax_baisa', i.tax_baisa, 'total_baisa', i.total_baisa, 'paid_baisa', i.paid_baisa, 'change_baisa', i.change_baisa,
    'note', i.note, 'print_count', i.print_count,
    'lines', (select jsonb_agg(jsonb_build_object(
        'line_no', l.line_no, 'product_id', l.product_id, 'sku', l.sku, 'kind', l.kind, 'description_ar', l.description_ar,
        'unit', l.unit, 'qty', l.qty, 'unit_price_baisa', l.unit_price_baisa, 'gross_baisa', l.gross_baisa,
        'discount_baisa', l.discount_baisa, 'net_baisa', l.net_baisa, 'tax_baisa', l.tax_baisa, 'total_baisa', l.total_baisa)
        order by l.line_no) from public.invoice_lines l where l.invoice_id = i.id),
    'payments', (select jsonb_agg(jsonb_build_object('method', p.method, 'amount_baisa', p.amount_baisa,
        'tendered_baisa', p.tendered_baisa, 'card_reference', p.card_reference) order by p.method, p.created_at)
        from public.payments p where p.invoice_id = i.id))
  from public.invoices i
  join public.branches b on b.id = i.branch_id
  join public.branch_settings s on s.branch_id = i.branch_id
  join public.organizations o on o.id = i.organization_id
  join public.business_days d on d.id = i.business_day_id
  where i.id = p_invoice_id;
$$;
revoke all on function app.invoice_json(uuid) from public;
grant execute on function app.invoice_json(uuid) to service_role;

create or replace function public.get_invoice(p_invoice_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_branch uuid;
begin
  select branch_id into v_branch from public.invoices where id = p_invoice_id;
  if v_branch is null or not app.has_perm(v_branch, 'invoice.view') then perform app.fail('NOT_FOUND'); end if;
  return app.invoice_json(p_invoice_id);
end $$;

create or replace function public.record_invoice_print(p_invoice_id uuid, p_is_reprint boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare v_inv public.invoices;
begin
  select * into v_inv from public.invoices where id = p_invoice_id;
  if not found or not app.has_perm(v_inv.branch_id, case when p_is_reprint then 'invoice.reprint' else 'invoice.view' end) then
    perform app.fail('FORBIDDEN'); end if;
  update public.invoices set print_count = print_count + 1 where id = p_invoice_id;
  if p_is_reprint then
    perform app.audit(v_inv.organization_id, v_inv.branch_id, 'invoice.reprint', 'invoice', v_inv.id, null, null,
      jsonb_build_object('invoice_no', v_inv.invoice_no, 'print_count', v_inv.print_count + 1));
  end if;
end $$;

-- ───────────── اعتماد البيع ─────────────
-- p_payload: { cash_session_id, customer_id?, vehicle_id?, note?, expected_total_baisa,
--              lines:[{product_id, qty, unit_price_baisa, discount_baisa?}],
--              payments:[{method:'cash'|'card', amount_baisa, card_reference?}], cash_tendered_baisa? }
create or replace function public.approve_sale(p_operation_id uuid, p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_hash text;
  v_op public.operation_requests;
  v_sess public.cash_sessions;
  v_day public.business_days;
  v_set public.branch_settings;
  v_prod public.products;
  v_line jsonb; v_pay jsonb; v_lot record;
  v_lines jsonb := '[]'::jsonb;
  v_changes jsonb := '[]'::jsonb;
  v_idx int := 0;
  v_qty numeric(12,3); v_price bigint; v_expected bigint; v_gross bigint; v_disc bigint;
  v_base bigint; v_tax bigint; v_net bigint; v_ltotal bigint; v_rate int;
  v_subtotal bigint := 0; v_discount bigint := 0; v_net_total bigint := 0; v_tax_total bigint := 0; v_total bigint := 0;
  v_net_goods bigint := 0; v_net_services bigint := 0;
  v_max_disc int;
  v_cash bigint := 0; v_card bigint := 0; v_tendered bigint; v_change bigint := 0; v_amt bigint;
  v_customer uuid; v_vehicle uuid; v_cust public.customers;
  v_seq bigint; v_invoice_no text; v_invoice_id uuid := gen_random_uuid(); v_line_id uuid;
  v_need numeric(12,3); v_take numeric(12,3); v_line_cost bigint; v_cost_total bigint := 0; v_avail numeric;
  v_entry uuid; v_result jsonb; v_inserted int;
begin
  if v_uid is null then perform app.fail('NOT_AUTHENTICATED'); end if;
  if p_operation_id is null or p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    perform app.fail('INVALID_REQUEST'); end if;
  v_hash := md5(p_payload::text);

  -- 1) طلب مُعاد: أعِد النتيجة الأصلية بعد مطابقة الطلب
  select * into v_op from public.operation_requests where operation_id = p_operation_id;
  if found then
    if v_op.op_type = 'cancelled' then perform app.fail('OPERATION_CANCELLED'); end if;
    if v_op.user_id <> v_uid or v_op.op_type <> 'sale' or v_op.request_hash <> v_hash then
      perform app.fail('OPERATION_MISMATCH'); end if;
    return v_op.result || jsonb_build_object('replayed', true);
  end if;

  -- 2) الوردية والصلاحية
  select * into v_sess from public.cash_sessions where id = (p_payload->>'cash_session_id')::uuid;
  if not found then perform app.fail('SESSION_NOT_FOUND'); end if;
  if not app.has_perm(v_sess.branch_id, 'pos.sell') then perform app.fail('FORBIDDEN'); end if;
  if v_sess.status <> 'open' then perform app.fail('SESSION_CLOSED'); end if;
  if v_sess.opened_by <> v_uid then perform app.fail('SESSION_NOT_YOURS'); end if;
  select * into v_day from public.business_days where id = v_sess.business_day_id;
  if v_day.status <> 'open' then perform app.fail('BUSINESS_DAY_CLOSED'); end if;
  select * into v_set from public.branch_settings where branch_id = v_sess.branch_id;
  v_rate := case when v_set.tax_enabled then v_set.tax_rate_bp else 0 end;

  select coalesce(max(m.max_discount_bp), 0) into v_max_disc
  from public.memberships m
  join public.role_permissions rp on rp.role_code = m.role_code and rp.permission_code = 'pos.discount'
  where m.user_id = v_uid and m.is_active and m.organization_id = v_sess.organization_id
    and (m.branch_id is null or m.branch_id = v_sess.branch_id);

  -- 3) تسعير البنود من السجل المركزي
  if jsonb_typeof(p_payload->'lines') <> 'array' or jsonb_array_length(p_payload->'lines') not between 1 and 200 then
    perform app.fail('EMPTY_CART'); end if;

  for v_line in select * from jsonb_array_elements(p_payload->'lines') loop
    v_idx := v_idx + 1;
    select * into v_prod from public.products
    where id = (v_line->>'product_id')::uuid and organization_id = v_sess.organization_id and is_active;
    if not found then perform app.fail('PRODUCT_NOT_FOUND', jsonb_build_object('line_no', v_idx)); end if;

    v_qty := (v_line->>'qty')::numeric;
    if v_qty is null or v_qty <= 0 or (v_prod.whole_units_only and v_qty <> trunc(v_qty)) then
      perform app.fail('INVALID_QUANTITY', jsonb_build_object('line_no', v_idx, 'sku', v_prod.sku)); end if;

    v_price := app.effective_price(v_sess.branch_id, v_prod.id);
    v_expected := (v_line->>'unit_price_baisa')::bigint;
    if v_expected is distinct from v_price then
      v_changes := v_changes || jsonb_build_object('line_no', v_idx, 'product_id', v_prod.id, 'sku', v_prod.sku,
        'name_ar', v_prod.name_ar, 'expected_baisa', v_expected, 'current_baisa', v_price);
    end if;

    v_gross := app.round_baisa(v_qty * v_price);
    v_disc := coalesce((v_line->>'discount_baisa')::bigint, 0);
    if v_disc < 0 or v_disc > v_gross then perform app.fail('INVALID_DISCOUNT', jsonb_build_object('line_no', v_idx)); end if;
    if v_disc > 0 and v_disc * 10000 > v_gross * v_max_disc then
      perform app.fail('DISCOUNT_LIMIT_EXCEEDED', jsonb_build_object('line_no', v_idx, 'max_discount_bp', v_max_disc)); end if;

    v_base := v_gross - v_disc;
    if v_prod.taxable and v_rate > 0 then
      if v_set.prices_include_tax then
        v_tax := app.round_baisa(v_base::numeric * v_rate / (10000 + v_rate));
        v_net := v_base - v_tax;
      else
        v_tax := app.round_baisa(v_base::numeric * v_rate / 10000);
        v_net := v_base;
      end if;
    else
      v_tax := 0; v_net := v_base;
    end if;
    v_ltotal := v_net + v_tax;

    v_subtotal := v_subtotal + v_gross; v_discount := v_discount + v_disc;
    v_net_total := v_net_total + v_net; v_tax_total := v_tax_total + v_tax; v_total := v_total + v_ltotal;
    if v_prod.kind = 'service' then v_net_services := v_net_services + v_net; else v_net_goods := v_net_goods + v_net; end if;

    v_lines := v_lines || jsonb_build_object('line_no', v_idx, 'product_id', v_prod.id, 'kind', v_prod.kind, 'sku', v_prod.sku,
      'description_ar', v_prod.name_ar, 'unit', v_prod.unit, 'qty', v_qty, 'unit_price_baisa', v_price, 'gross_baisa', v_gross,
      'discount_baisa', v_disc, 'taxable', (v_prod.taxable and v_rate > 0), 'tax_rate_bp', case when v_prod.taxable then v_rate else 0 end,
      'net_baisa', v_net, 'tax_baisa', v_tax, 'total_baisa', v_ltotal, 'track_stock', v_prod.track_stock);
  end loop;

  -- تغيّر السعر أو الإجمالي منذ الإضافة للسلة: لا يُحفظ شيء، ويُعرض الفرق للكاشير ليؤكده
  if jsonb_array_length(v_changes) > 0 then
    return jsonb_build_object('status', 'price_changed', 'changes', v_changes, 'server_total_baisa', v_total);
  end if;
  if (p_payload->>'expected_total_baisa')::bigint is distinct from v_total then
    return jsonb_build_object('status', 'total_changed', 'server_total_baisa', v_total,
      'tax_enabled', v_set.tax_enabled, 'tax_rate_bp', v_set.tax_rate_bp, 'prices_include_tax', v_set.prices_include_tax);
  end if;

  -- 4) المدفوعات
  if jsonb_typeof(p_payload->'payments') <> 'array' or jsonb_array_length(p_payload->'payments') not between 1 and 10 then
    perform app.fail('PAYMENT_REQUIRED'); end if;
  for v_pay in select * from jsonb_array_elements(p_payload->'payments') loop
    v_amt := (v_pay->>'amount_baisa')::bigint;
    if v_amt is null or v_amt <= 0 then perform app.fail('INVALID_PAYMENT'); end if;
    if v_pay->>'method' = 'cash' then v_cash := v_cash + v_amt;
    elsif v_pay->>'method' = 'card' then v_card := v_card + v_amt;
    else perform app.fail('INVALID_PAYMENT'); end if;
  end loop;
  if v_cash + v_card <> v_total then
    perform app.fail('PAYMENT_MISMATCH', jsonb_build_object('total_baisa', v_total, 'paid_baisa', v_cash + v_card)); end if;
  if v_cash > 0 then
    v_tendered := coalesce((p_payload->>'cash_tendered_baisa')::bigint, v_cash);
    if v_tendered < v_cash then perform app.fail('INVALID_PAYMENT'); end if;
    v_change := v_tendered - v_cash;
  end if;

  -- 5) العميل والمركبة
  v_customer := (p_payload->>'customer_id')::uuid;
  v_vehicle := (p_payload->>'vehicle_id')::uuid;
  if v_customer is not null then
    select * into v_cust from public.customers where id = v_customer and organization_id = v_sess.organization_id;
    if not found then perform app.fail('CUSTOMER_NOT_FOUND'); end if;
  end if;
  if v_vehicle is not null and not exists (select 1 from public.vehicles where id = v_vehicle and organization_id = v_sess.organization_id) then
    perform app.fail('VEHICLE_NOT_FOUND'); end if;

  -- 6) حجز معرّف العملية. إن سبقنا طلب مطابق في الوقت نفسه ننتظره ثم نعيد نتيجته.
  insert into public.operation_requests (operation_id, organization_id, branch_id, device_id, cash_session_id, user_id, op_type, request_hash, result)
  values (p_operation_id, v_sess.organization_id, v_sess.branch_id, v_sess.device_id, v_sess.id, v_uid, 'sale', v_hash, '{}'::jsonb)
  on conflict (operation_id) do nothing;
  get diagnostics v_inserted = row_count;
  if v_inserted = 0 then
    select * into v_op from public.operation_requests where operation_id = p_operation_id;
    if v_op.op_type = 'cancelled' then perform app.fail('OPERATION_CANCELLED'); end if;
    if v_op.user_id <> v_uid or v_op.op_type <> 'sale' or v_op.request_hash <> v_hash then
      perform app.fail('OPERATION_MISMATCH'); end if;
    return v_op.result || jsonb_build_object('replayed', true);
  end if;

  -- 7) رقم الفاتورة: تسلسل مركزي لكل فرع (قفل صف العدّاد يرتّب اعتمادات الفرع)
  insert into public.branch_counters (branch_id, counter_key, last_value) values (v_sess.branch_id, 'invoice', 1)
  on conflict (branch_id, counter_key) do update set last_value = public.branch_counters.last_value + 1
  returning last_value into v_seq;
  v_invoice_no := v_set.invoice_prefix || '-' || to_char(v_day.business_date, 'YY') || '-' || lpad(v_seq::text, 6, '0');

  insert into public.invoices (id, organization_id, branch_id, invoice_no, seq, business_day_id, cash_session_id, device_id,
    cashier_id, customer_id, vehicle_id, tax_rate_bp, prices_include_tax, subtotal_baisa, discount_baisa, net_baisa,
    tax_baisa, total_baisa, paid_baisa, change_baisa, note, operation_id)
  values (v_invoice_id, v_sess.organization_id, v_sess.branch_id, v_invoice_no, v_seq, v_day.id, v_sess.id, v_sess.device_id,
    v_uid, v_customer, v_vehicle, v_rate, v_set.prices_include_tax, v_subtotal, v_discount, v_net_total,
    v_tax_total, v_total, v_cash + v_card, v_change, nullif(btrim(p_payload->>'note'), ''), p_operation_id);

  -- 8) البنود وخصم المخزون FIFO مع قفل الدفعات والتحقق من الكمية
  for v_line in select * from jsonb_array_elements(v_lines) loop
    insert into public.invoice_lines (organization_id, branch_id, invoice_id, line_no, product_id, kind, sku, description_ar, unit,
      qty, unit_price_baisa, gross_baisa, discount_baisa, taxable, tax_rate_bp, net_baisa, tax_baisa, total_baisa)
    values (v_sess.organization_id, v_sess.branch_id, v_invoice_id, (v_line->>'line_no')::int, (v_line->>'product_id')::uuid,
      v_line->>'kind', v_line->>'sku', v_line->>'description_ar', v_line->>'unit', (v_line->>'qty')::numeric,
      (v_line->>'unit_price_baisa')::bigint, (v_line->>'gross_baisa')::bigint, (v_line->>'discount_baisa')::bigint,
      (v_line->>'taxable')::boolean, (v_line->>'tax_rate_bp')::int, (v_line->>'net_baisa')::bigint,
      (v_line->>'tax_baisa')::bigint, (v_line->>'total_baisa')::bigint)
    returning id into v_line_id;

    v_line_cost := 0;
    if (v_line->>'track_stock')::boolean then
      v_need := (v_line->>'qty')::numeric;
      for v_lot in
        select id, qty_on_hand, unit_cost_baisa from public.inventory_lots
        where branch_id = v_sess.branch_id and product_id = (v_line->>'product_id')::uuid and qty_on_hand > 0
        order by received_at, id for update
      loop
        v_take := least(v_need, v_lot.qty_on_hand);
        update public.inventory_lots set qty_on_hand = qty_on_hand - v_take where id = v_lot.id;
        insert into public.stock_movements (organization_id, branch_id, product_id, lot_id, movement_type, qty_delta,
          unit_cost_baisa, source_type, source_id, created_by)
        values (v_sess.organization_id, v_sess.branch_id, (v_line->>'product_id')::uuid, v_lot.id, 'sale', -v_take,
          v_lot.unit_cost_baisa, 'invoice', v_invoice_id, v_uid);
        v_line_cost := v_line_cost + app.round_baisa(v_take * v_lot.unit_cost_baisa);
        v_need := v_need - v_take;
        exit when v_need = 0;
      end loop;
      if v_need > 0 then
        select coalesce(sum(qty_on_hand), 0) + ((v_line->>'qty')::numeric - v_need) into v_avail
        from public.inventory_lots where branch_id = v_sess.branch_id and product_id = (v_line->>'product_id')::uuid;
        perform app.fail('INSUFFICIENT_STOCK', jsonb_build_object('line_no', (v_line->>'line_no')::int, 'sku', v_line->>'sku',
          'name_ar', v_line->>'description_ar', 'requested', (v_line->>'qty')::numeric, 'available', v_avail));
      end if;
    end if;
    insert into public.invoice_line_costs (invoice_line_id, organization_id, branch_id, cost_baisa)
    values (v_line_id, v_sess.organization_id, v_sess.branch_id, v_line_cost);
    v_cost_total := v_cost_total + v_line_cost;
  end loop;

  -- 9) المدفوعات وحركة الصندوق
  for v_pay in select * from jsonb_array_elements(p_payload->'payments') loop
    insert into public.payments (organization_id, branch_id, invoice_id, cash_session_id, method, amount_baisa, tendered_baisa, card_reference)
    values (v_sess.organization_id, v_sess.branch_id, v_invoice_id, v_sess.id, v_pay->>'method', (v_pay->>'amount_baisa')::bigint,
      case when v_pay->>'method' = 'cash' then v_tendered end,
      case when v_pay->>'method' = 'card' then nullif(btrim(v_pay->>'card_reference'), '') end);
  end loop;
  if v_cash > 0 then
    insert into public.cash_movements (organization_id, branch_id, cash_session_id, movement_type, amount_baisa, source_type, source_id, created_by)
    values (v_sess.organization_id, v_sess.branch_id, v_sess.id, 'sale', v_cash, 'invoice', v_invoice_id, v_uid);
  end if;

  -- 10) القيد المحاسبي المزدوج
  insert into public.journal_entries (organization_id, branch_id, business_day_id, source_type, source_id, description, created_by)
  values (v_sess.organization_id, v_sess.branch_id, v_day.id, 'invoice', v_invoice_id, 'فاتورة بيع ' || v_invoice_no, v_uid)
  returning id into v_entry;

  insert into public.journal_lines (entry_id, organization_id, branch_id, account_id, debit_baisa, credit_baisa)
  select v_entry, v_sess.organization_id, v_sess.branch_id, a.id, x.debit, x.credit
  from (values ('cash_on_hand', v_cash, 0::bigint), ('card_clearing', v_card, 0),
               ('sales_goods', 0, v_net_goods), ('sales_services', 0, v_net_services), ('vat_output', 0, v_tax_total),
               ('cogs', v_cost_total, 0), ('inventory', 0, v_cost_total)) as x(system_key, debit, credit)
  join public.accounts a on a.organization_id = v_sess.organization_id and a.system_key = x.system_key
  where x.debit > 0 or x.credit > 0;
  -- غياب حساب نظامي يُخلّ بالتوازن فيُرفض القيد عند نهاية المعاملة (JOURNAL_UNBALANCED)

  -- 11) حدث الإشعار المؤهل (الإرسال في المرحلة 4)
  if v_customer is not null and v_cust.phone is not null then
    insert into public.notification_events (organization_id, branch_id, event_type, customer_id, invoice_id, lang, payload)
    values (v_sess.organization_id, v_sess.branch_id, 'invoice_issued', v_customer, v_invoice_id, v_cust.preferred_lang,
      jsonb_build_object('invoice_no', v_invoice_no, 'total_baisa', v_total));
  end if;

  perform app.audit(v_sess.organization_id, v_sess.branch_id, 'invoice.approve', 'invoice', v_invoice_id, null, null,
    jsonb_build_object('invoice_no', v_invoice_no, 'total_baisa', v_total, 'cash_baisa', v_cash, 'card_baisa', v_card));

  v_result := jsonb_build_object('status', 'approved', 'invoice', app.invoice_json(v_invoice_id));
  update public.operation_requests set result = v_result where operation_id = p_operation_id;
  return v_result || jsonb_build_object('replayed', false);
end $$;

-- التخلي عن عملية لم تُعرف نتيجتها: يحجز المعرّف كملغى حتى لا يُعتمد طلب متأخر ما زال في الطريق.
-- إن كانت العملية قد اعتُمدت فعلًا تُعاد نتيجتها ولا يُلغى شيء.
create or replace function public.cancel_operation(p_operation_id uuid, p_cash_session_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); v_sess public.cash_sessions; v_op public.operation_requests;
begin
  if v_uid is null then perform app.fail('NOT_AUTHENTICATED'); end if;
  select * into v_sess from public.cash_sessions where id = p_cash_session_id;
  if not found or v_sess.opened_by <> v_uid or not app.has_perm(v_sess.branch_id, 'pos.sell') then perform app.fail('FORBIDDEN'); end if;
  insert into public.operation_requests (operation_id, organization_id, branch_id, device_id, cash_session_id, user_id, op_type, request_hash, result)
  values (p_operation_id, v_sess.organization_id, v_sess.branch_id, v_sess.device_id, v_sess.id, v_uid, 'cancelled', '', jsonb_build_object('status', 'cancelled'))
  on conflict (operation_id) do nothing;
  select * into v_op from public.operation_requests where operation_id = p_operation_id;
  if v_op.user_id <> v_uid then perform app.fail('OPERATION_MISMATCH'); end if;
  return v_op.result;
end $$;

-- ───────────── التحقق من نتيجة عملية (بعد انقطاع الرد أو إعادة التشغيل) ─────────────
create or replace function public.get_operation(p_operation_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select jsonb_build_object('found', true, 'op_type', o.op_type, 'created_at', o.created_at, 'result', o.result)
     from public.operation_requests o
     where o.operation_id = p_operation_id and (o.user_id = (select auth.uid()) or app.has_perm(o.branch_id, 'invoice.view'))),
    jsonb_build_object('found', false));
$$;

create or replace function public.recent_operations(p_cash_session_id uuid, p_limit int default 20) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(x order by x->>'created_at' desc), '[]'::jsonb) from (
    select jsonb_build_object('operation_id', o.operation_id, 'op_type', o.op_type, 'created_at', o.created_at,
      'invoice_id', o.result->'invoice'->>'id', 'invoice_no', o.result->'invoice'->>'invoice_no',
      'total_baisa', (o.result->'invoice'->>'total_baisa')::bigint) as x
    from public.operation_requests o
    where o.cash_session_id = p_cash_session_id and app.has_branch(o.branch_id)
      and (o.user_id = (select auth.uid()) or app.has_perm(o.branch_id, 'invoice.view'))
    order by o.created_at desc limit least(greatest(coalesce(p_limit, 20), 1), 100)) s;
$$;

-- ───────────── مؤشرات لوحة الإدارة ─────────────
create or replace function public.dashboard_summary(p_branch_id uuid, p_from date, p_to date) returns jsonb
language sql stable security definer set search_path = '' as $$
  with inv as (
    select i.*, app.has_perm(i.branch_id, 'inventory.cost.view') as can_cost
    from public.invoices i join public.business_days d on d.id = i.business_day_id
    where d.business_date between p_from and p_to and i.status = 'approved'
      and (p_branch_id is null or i.branch_id = p_branch_id)
      and app.has_perm(i.branch_id, 'reports.view')
  )
  select jsonb_build_object(
    'invoice_count', (select count(*) from inv),
    'net_sales_baisa', (select coalesce(sum(net_baisa), 0) from inv),
    'tax_baisa', (select coalesce(sum(tax_baisa), 0) from inv),
    'total_baisa', (select coalesce(sum(total_baisa), 0) from inv),
    'discount_baisa', (select coalesce(sum(discount_baisa), 0) from inv),
    'cash_baisa', (select coalesce(sum(p.amount_baisa), 0) from public.payments p join inv on inv.id = p.invoice_id where p.method = 'cash'),
    'card_baisa', (select coalesce(sum(p.amount_baisa), 0) from public.payments p join inv on inv.id = p.invoice_id where p.method = 'card'),
    'gross_profit_baisa', case when (select bool_and(can_cost) from inv) then
        (select coalesce(sum(net_baisa), 0) from inv)
        - (select coalesce(sum(c.cost_baisa), 0) from public.invoice_line_costs c
           join public.invoice_lines l on l.id = c.invoice_line_id join inv on inv.id = l.invoice_id) end);
$$;

-- ───────────── قائمة الفواتير (لوحة الإدارة وسجل الكاشير) ─────────────
create or replace function public.list_invoices(p_branch_id uuid, p_from date, p_to date, p_search text default null, p_limit int default 100)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(s.j order by s.approved_at desc), '[]'::jsonb) from (
    select i.approved_at, jsonb_build_object(
      'id', i.id, 'invoice_no', i.invoice_no, 'status', i.status, 'approved_at', i.approved_at, 'business_date', d.business_date,
      'branch_id', i.branch_id, 'branch_code', b.code, 'branch_name_ar', b.name_ar,
      'total_baisa', i.total_baisa, 'tax_baisa', i.tax_baisa, 'discount_baisa', i.discount_baisa,
      'cashier_name', pr.full_name, 'customer_name', c.name, 'customer_phone', c.phone, 'plate', v.plate,
      'cash_baisa', (select coalesce(sum(p.amount_baisa), 0) from public.payments p where p.invoice_id = i.id and p.method = 'cash'),
      'card_baisa', (select coalesce(sum(p.amount_baisa), 0) from public.payments p where p.invoice_id = i.id and p.method = 'card')) as j
    from public.invoices i
    join public.business_days d on d.id = i.business_day_id
    join public.branches b on b.id = i.branch_id
    join public.profiles pr on pr.id = i.cashier_id
    left join public.customers c on c.id = i.customer_id
    left join public.vehicles v on v.id = i.vehicle_id
    where app.has_perm(i.branch_id, 'invoice.view')
      and (p_branch_id is null or i.branch_id = p_branch_id)
      and d.business_date between p_from and p_to
      and (coalesce(btrim(p_search), '') = ''
        or i.invoice_no ilike '%' || btrim(p_search) || '%'
        or c.phone like '%' || btrim(p_search) || '%'
        or v.plate ilike '%' || btrim(p_search) || '%')
    order by i.approved_at desc
    limit least(greatest(coalesce(p_limit, 100), 1), 500)) s;
$$;

-- ───────────── صلاحيات التنفيذ ─────────────
revoke all on all functions in schema public from public, anon;
grant execute on function
  public.my_context(), public.resolve_device(text), public.open_cash_session(uuid, uuid, bigint),
  public.pos_search(uuid, text, int), public.get_invoice(uuid), public.record_invoice_print(uuid, boolean),
  public.approve_sale(uuid, jsonb), public.get_operation(uuid), public.recent_operations(uuid, int),
  public.dashboard_summary(uuid, date, date), public.list_invoices(uuid, date, date, text, int),
  public.cancel_operation(uuid, uuid)
to authenticated, service_role;
