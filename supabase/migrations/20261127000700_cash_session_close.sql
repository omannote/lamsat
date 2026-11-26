-- لمسات | إقفال الوردية: النقد المتوقع والفعلي، فرق الصندوق، إجمالي البطاقة منفصلًا، وتدوير اليوم المحاسبي

alter table public.cash_sessions
  add column card_total_baisa bigint,
  add column difference_baisa bigint,
  add column close_note text;

insert into public.permissions (code, description_ar) values
  ('cash.close.any', 'إقفال وردية موظف آخر في الفرع');
insert into public.role_permissions (role_code, permission_code) values
  ('owner', 'cash.close.any'), ('branch_manager', 'cash.close.any');

-- لا تُدرج فاتورة في وردية مقفلة. القفل المشترك هنا مع قفل الإقفال الحصري يضمن أن الإقفال
-- ينتظر أي بيع جارٍ فيحسبه، وأن أي بيع يصل بعد الإقفال يُرفض.
create or replace function app.invoice_session_open() returns trigger
language plpgsql set search_path = '' as $$
declare v_status text;
begin
  select status into v_status from public.cash_sessions where id = new.cash_session_id for share;
  if v_status is distinct from 'open' then
    raise exception using errcode = 'P0001', message = 'SESSION_CLOSED', detail = '';
  end if;
  return new;
end $$;
create trigger invoices_session_open before insert on public.invoices
  for each row execute function app.invoice_session_open();

create or replace function app.can_close_session(p_branch uuid, p_opened_by uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select app.has_perm(p_branch, 'cash.close.any')
      or (p_opened_by = (select auth.uid()) and app.has_perm(p_branch, 'cash.close'));
$$;
revoke all on function app.can_close_session(uuid, uuid) from public;
grant execute on function app.can_close_session(uuid, uuid) to authenticated, service_role;

create or replace function app.session_summary_json(p_session public.cash_sessions) returns jsonb
language sql stable security definer set search_path = '' as $$
  with m as (
    select coalesce(sum(amount_baisa) filter (where movement_type = 'sale'), 0) as cash_sales,
           coalesce(sum(amount_baisa) filter (where movement_type not in ('opening', 'sale')), 0) as cash_other,
           coalesce(sum(amount_baisa), 0) as expected
    from public.cash_movements where cash_session_id = p_session.id),
  i as (
    select count(*) as n, coalesce(sum(total_baisa), 0) as total
    from public.invoices where cash_session_id = p_session.id and status = 'approved'),
  c as (
    select coalesce(sum(amount_baisa), 0) as card
    from public.payments where cash_session_id = p_session.id and method = 'card')
  select jsonb_build_object(
    'session_id', p_session.id, 'status', p_session.status, 'branch_id', p_session.branch_id,
    'opened_at', p_session.opened_at, 'closed_at', p_session.closed_at,
    'opened_by_name', (select full_name from public.profiles where id = p_session.opened_by),
    'business_date', (select business_date from public.business_days where id = p_session.business_day_id),
    'opening_cash_baisa', p_session.opening_cash_baisa,
    'cash_sales_baisa', m.cash_sales, 'cash_other_baisa', m.cash_other,
    'expected_cash_baisa', coalesce(p_session.expected_cash_baisa, m.expected),
    'card_baisa', coalesce(p_session.card_total_baisa, c.card),
    'invoice_count', i.n, 'total_sales_baisa', i.total,
    'counted_cash_baisa', p_session.counted_cash_baisa, 'difference_baisa', p_session.difference_baisa,
    'close_note', p_session.close_note)
  from m, i, c;
$$;
revoke all on function app.session_summary_json(public.cash_sessions) from public;
grant execute on function app.session_summary_json(public.cash_sessions) to service_role;

-- مراجعة الإقفال (F10) قبل التأكيد
create or replace function public.cash_session_summary(p_cash_session_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_sess public.cash_sessions;
begin
  select * into v_sess from public.cash_sessions where id = p_cash_session_id;
  if not found or not (app.can_close_session(v_sess.branch_id, v_sess.opened_by) or app.has_perm(v_sess.branch_id, 'reports.view')) then
    perform app.fail('NOT_FOUND'); end if;
  return app.session_summary_json(v_sess);
end $$;

create or replace function public.close_cash_session(p_operation_id uuid, p_cash_session_id uuid,
  p_counted_cash_baisa bigint, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_sess public.cash_sessions; v_op public.operation_requests;
  v_hash text; v_expected bigint; v_card bigint; v_diff bigint; v_entry uuid; v_result jsonb;
  v_cash_acc uuid; v_diff_acc uuid;
begin
  if v_uid is null then perform app.fail('NOT_AUTHENTICATED'); end if;
  if p_operation_id is null then perform app.fail('INVALID_REQUEST'); end if;
  v_hash := md5(jsonb_build_object('session', p_cash_session_id, 'counted', p_counted_cash_baisa, 'note', coalesce(btrim(p_note), ''))::text);

  select * into v_op from public.operation_requests where operation_id = p_operation_id;
  if found then
    if v_op.user_id <> v_uid or v_op.op_type <> 'close_session' or v_op.request_hash <> v_hash then
      perform app.fail('OPERATION_MISMATCH'); end if;
    return v_op.result || jsonb_build_object('replayed', true);
  end if;

  if p_counted_cash_baisa is null or p_counted_cash_baisa < 0 then perform app.fail('INVALID_AMOUNT'); end if;
  -- القفل الحصري ينتظر أي بيع جارٍ على هذه الوردية
  select * into v_sess from public.cash_sessions where id = p_cash_session_id for update;
  if not found then perform app.fail('SESSION_NOT_FOUND'); end if;
  if not app.can_close_session(v_sess.branch_id, v_sess.opened_by) then perform app.fail('FORBIDDEN'); end if;
  if v_sess.status <> 'open' then perform app.fail('SESSION_CLOSED'); end if;

  select coalesce(sum(amount_baisa), 0) into v_expected from public.cash_movements where cash_session_id = v_sess.id;
  select coalesce(sum(amount_baisa), 0) into v_card from public.payments where cash_session_id = v_sess.id and method = 'card';
  v_diff := p_counted_cash_baisa - v_expected;
  if v_diff <> 0 and coalesce(btrim(p_note), '') = '' then perform app.fail('CLOSE_NOTE_REQUIRED', jsonb_build_object('difference_baisa', v_diff)); end if;

  update public.cash_sessions set status = 'closed', closed_at = now(), closed_by = v_uid,
    expected_cash_baisa = v_expected, counted_cash_baisa = p_counted_cash_baisa, card_total_baisa = v_card,
    difference_baisa = v_diff, close_note = nullif(btrim(p_note), '')
  where id = v_sess.id returning * into v_sess;

  -- فرق الصندوق: عجز = مدين فروقات الصندوق / دائن النقد. زيادة = العكس.
  if v_diff <> 0 then
    select id into v_cash_acc from public.accounts where organization_id = v_sess.organization_id and system_key = 'cash_on_hand';
    select id into v_diff_acc from public.accounts where organization_id = v_sess.organization_id and system_key = 'cash_over_short';
    if v_cash_acc is null or v_diff_acc is null then perform app.fail('ACCOUNT_MAPPING_MISSING'); end if;
    insert into public.journal_entries (organization_id, branch_id, business_day_id, source_type, source_id, description, created_by)
    values (v_sess.organization_id, v_sess.branch_id, v_sess.business_day_id, 'cash_session', v_sess.id,
      case when v_diff < 0 then 'عجز صندوق عند إقفال الوردية' else 'زيادة صندوق عند إقفال الوردية' end, v_uid)
    returning id into v_entry;
    insert into public.journal_lines (entry_id, organization_id, branch_id, account_id, debit_baisa, credit_baisa) values
      (v_entry, v_sess.organization_id, v_sess.branch_id, case when v_diff < 0 then v_diff_acc else v_cash_acc end, abs(v_diff), 0),
      (v_entry, v_sess.organization_id, v_sess.branch_id, case when v_diff < 0 then v_cash_acc else v_diff_acc end, 0, abs(v_diff));
  end if;

  perform app.audit(v_sess.organization_id, v_sess.branch_id, 'cash_session.close', 'cash_session', v_sess.id, v_sess.close_note, null,
    jsonb_build_object('expected_cash_baisa', v_expected, 'counted_cash_baisa', p_counted_cash_baisa,
      'difference_baisa', v_diff, 'card_total_baisa', v_card));

  v_result := jsonb_build_object('status', 'closed', 'summary', app.session_summary_json(v_sess));
  insert into public.operation_requests (operation_id, organization_id, branch_id, device_id, cash_session_id, user_id, op_type, request_hash, result)
  values (p_operation_id, v_sess.organization_id, v_sess.branch_id, v_sess.device_id, v_sess.id, v_uid, 'close_session', v_hash, v_result);
  return v_result || jsonb_build_object('replayed', false);
end $$;

-- فتح الوردية مع تدوير اليوم المحاسبي: يوم مفتوح بتاريخ سابق وبلا ورديات مفتوحة يُقفل تلقائيًا ويُفتح يوم جديد.
-- الوردية العابرة لمنتصف الليل تبقى على يومها حتى تُقفل.
create or replace function public.open_cash_session(p_operation_id uuid, p_device_id uuid, p_opening_cash_baisa bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_dev public.devices; v_day public.business_days; v_sess public.cash_sessions;
  v_op public.operation_requests; v_hash text; v_result jsonb; v_tz text; v_today date;
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

  select timezone into v_tz from public.organizations where id = v_dev.organization_id;
  v_today := (now() at time zone v_tz)::date;
  -- قفل صف الفرع يرتّب فتح الورديات المتزامن على أجهزة الفرع
  perform 1 from public.branches where id = v_dev.branch_id for update;

  select * into v_day from public.business_days where branch_id = v_dev.branch_id and status = 'open';
  if found and v_day.business_date < v_today
     and not exists (select 1 from public.cash_sessions where business_day_id = v_day.id and status = 'open') then
    update public.business_days set status = 'closed', closed_at = now() where id = v_day.id;
    perform app.audit(v_dev.organization_id, v_dev.branch_id, 'business_day.auto_close', 'business_day', v_day.id, null, null,
      jsonb_build_object('business_date', v_day.business_date));
    v_day := null;
  end if;
  if v_day.id is null then
    insert into public.business_days (organization_id, branch_id, business_date, opened_by)
    values (v_dev.organization_id, v_dev.branch_id, v_today, v_uid)
    on conflict (branch_id, business_date) do nothing
    returning * into v_day;
    if v_day.id is null then perform app.fail('BUSINESS_DAY_CLOSED'); end if;
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

-- قائمة الورديات للوحة الإدارة
create or replace function public.list_cash_sessions(p_branch_id uuid, p_from date, p_to date) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(x.j order by x.opened_at desc), '[]'::jsonb) from (
    select s.opened_at, app.session_summary_json(s) || jsonb_build_object(
      'branch_code', b.code, 'device_name', dv.name,
      'closed_by_name', (select full_name from public.profiles where id = s.closed_by)) as j
    from public.cash_sessions s
    join public.business_days d on d.id = s.business_day_id
    join public.branches b on b.id = s.branch_id
    join public.devices dv on dv.id = s.device_id
    where app.has_perm(s.branch_id, 'reports.view')
      and (p_branch_id is null or s.branch_id = p_branch_id)
      and d.business_date between p_from and p_to
    order by s.opened_at desc limit 300) x;
$$;

revoke all on function public.cash_session_summary(uuid), public.close_cash_session(uuid, uuid, bigint, text),
  public.list_cash_sessions(uuid, date, date) from public, anon;
grant execute on function public.cash_session_summary(uuid), public.close_cash_session(uuid, uuid, bigint, text),
  public.list_cash_sessions(uuid, date, date) to authenticated, service_role;
