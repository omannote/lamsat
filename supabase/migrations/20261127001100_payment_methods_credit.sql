-- طرق الدفع حسب شاشة الدفع: نقدي، بطاقة، تحويل بنكي، آجل (على حساب العميل)، وتحصيل الآجل لاحقًا.
-- paid_baisa في الفاتورة يبقى مساويًا للإجمالي؛ الجزء الآجل يُعرف من سطر الدفع method='credit' ومن حساب «العملاء — ذمم مدينة».

alter table public.payments drop constraint payments_method_check;
alter table public.payments add constraint payments_method_check check (method in ('cash', 'card', 'transfer', 'credit'));
alter table public.refunds drop constraint refunds_method_check;
alter table public.refunds add constraint refunds_method_check check (method in ('cash', 'card', 'transfer', 'credit'));
alter table public.cash_sessions add column transfer_total_baisa bigint, add column credit_total_baisa bigint;

create or replace function app.ensure_system_accounts(p_org uuid) returns void
language sql security definer set search_path = '' as $$
  insert into public.accounts (organization_id, code, name_ar, name_en, account_type, system_key)
  select p_org, v.code, v.name_ar, v.name_en, v.t, v.k from (values
    ('1130', 'تحويلات بنكية تحت التسوية', 'Bank transfers clearing', 'asset', 'bank_transfer_clearing'),
    ('1210', 'العملاء — ذمم مدينة', 'Accounts receivable', 'asset', 'accounts_receivable'),
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
    ('public.approve_sale(uuid,jsonb)', 'v_cash bigint := 0; v_card bigint := 0;', 'v_cash bigint := 0; v_card bigint := 0; v_transfer bigint := 0; v_credit bigint := 0;'),
    ('public.approve_sale(uuid,jsonb)', 'elsif v_pay->>''method'' = ''card'' then v_card := v_card + v_amt;',
       'elsif v_pay->>''method'' = ''card'' then v_card := v_card + v_amt;
    elsif v_pay->>''method'' = ''transfer'' then v_transfer := v_transfer + v_amt;
    elsif v_pay->>''method'' = ''credit'' then v_credit := v_credit + v_amt;'),
    ('public.approve_sale(uuid,jsonb)', 'if v_cash + v_card <> v_total then', 'if v_cash + v_card + v_transfer + v_credit <> v_total then'),
    ('public.approve_sale(uuid,jsonb)', '''paid_baisa'', v_cash + v_card)); end if;', '''paid_baisa'', v_cash + v_card + v_transfer + v_credit)); end if;'),
    ('public.approve_sale(uuid,jsonb)', 'v_vehicle := (p_payload->>''vehicle_id'')::uuid;',
       'v_vehicle := (p_payload->>''vehicle_id'')::uuid;
  if v_credit > 0 and v_customer is null then perform app.fail(''CREDIT_REQUIRES_CUSTOMER''); end if;'),
    ('public.approve_sale(uuid,jsonb)', 'v_tax_total, v_total, v_cash + v_card, v_change,', 'v_tax_total, v_total, v_cash + v_card + v_transfer + v_credit, v_change,'),
    ('public.approve_sale(uuid,jsonb)', 'case when v_pay->>''method'' = ''card'' then nullif', 'case when v_pay->>''method'' in (''card'', ''transfer'') then nullif'),
    ('public.approve_sale(uuid,jsonb)', '(''card_clearing'', v_card, 0),', '(''card_clearing'', v_card, 0), (''bank_transfer_clearing'', v_transfer, 0), (''accounts_receivable'', v_credit, 0),'),
    ('public.approve_sale(uuid,jsonb)', '''card_baisa'', v_card));', '''card_baisa'', v_card, ''transfer_baisa'', v_transfer, ''credit_baisa'', v_credit));'),
    ('public.refund_invoice(uuid,jsonb)', 'v_method not in (''cash'', ''card'')', 'v_method not in (''cash'', ''card'', ''transfer'', ''credit'')'),
    ('public.refund_invoice(uuid,jsonb)', 'case when v_method = ''cash'' then ''cash_on_hand'' else ''card_clearing'' end',
       'case v_method when ''cash'' then ''cash_on_hand'' when ''card'' then ''card_clearing'' when ''transfer'' then ''bank_transfer_clearing'' else ''accounts_receivable'' end'),
    ('public.close_cash_session(uuid,uuid,bigint,text)', 'card_total_baisa = v_card,',
       'card_total_baisa = v_card,
    transfer_total_baisa = (select coalesce(sum(amount_baisa), 0) from public.payments where cash_session_id = v_sess.id and method = ''transfer''),
    credit_total_baisa = (select coalesce(sum(amount_baisa), 0) from public.payments where cash_session_id = v_sess.id and method = ''credit''),'),
    ('public.dashboard_summary(uuid,date,date)', '''gross_profit_baisa'', case',
       '''transfer_baisa'', (select coalesce(sum(p.amount_baisa), 0) from public.payments p join inv on inv.id = p.invoice_id where p.method = ''transfer''),
    ''credit_baisa'', (select coalesce(sum(p.amount_baisa), 0) from public.payments p join inv on inv.id = p.invoice_id where p.method = ''credit''),
    ''gross_profit_baisa'', case')
  ) as t(fn, target, repl) loop
    d := pg_get_functiondef(r.fn::regprocedure);
    if position(r.target in d) = 0 then raise exception 'patch target missing in %: %', r.fn, r.target; end if;
    execute replace(d, r.target, r.repl);
  end loop;
end $$;

-- إن كان المرتجع «على حساب العميل» فلا بد أن تكون للفاتورة عميل
create or replace function app.refund_credit_needs_customer() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.method = 'credit' and (select customer_id from public.invoices where id = new.invoice_id) is null then
    perform app.fail('CREDIT_REQUIRES_CUSTOMER'); end if;
  return new;
end $$;
create trigger refunds_credit_needs_customer before insert on public.refunds for each row execute function app.refund_credit_needs_customer();

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
    select coalesce(sum(amount_baisa) filter (where method = 'card'), 0) as card,
           coalesce(sum(amount_baisa) filter (where method = 'transfer'), 0) as transfer,
           coalesce(sum(amount_baisa) filter (where method = 'credit'), 0) as credit
    from public.payments where cash_session_id = p_session.id)
  select jsonb_build_object(
    'session_id', p_session.id, 'status', p_session.status, 'branch_id', p_session.branch_id,
    'opened_at', p_session.opened_at, 'closed_at', p_session.closed_at,
    'opened_by_name', (select full_name from public.profiles where id = p_session.opened_by),
    'business_date', (select business_date from public.business_days where id = p_session.business_day_id),
    'opening_cash_baisa', p_session.opening_cash_baisa,
    'cash_sales_baisa', m.cash_sales, 'cash_other_baisa', m.cash_other,
    'expected_cash_baisa', coalesce(p_session.expected_cash_baisa, m.expected),
    'card_baisa', coalesce(p_session.card_total_baisa, c.card),
    'transfer_baisa', coalesce(p_session.transfer_total_baisa, c.transfer),
    'credit_baisa', coalesce(p_session.credit_total_baisa, c.credit),
    'invoice_count', i.n, 'total_sales_baisa', i.total,
    'counted_cash_baisa', p_session.counted_cash_baisa, 'difference_baisa', p_session.difference_baisa,
    'close_note', p_session.close_note)
  from m, i, c;
$$;

-- ───────────── حساب العميل الآجل وتحصيله ─────────────
create table public.customer_receipts (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  branch_id       uuid not null,
  customer_id     uuid not null,
  cash_session_id uuid not null references public.cash_sessions(id),
  method          text not null check (method in ('cash', 'card', 'transfer')),
  amount_baisa    bigint not null check (amount_baisa > 0),
  reference       text,
  created_by      uuid not null,
  created_at      timestamptz not null default now(),
  foreign key (customer_id, organization_id) references public.customers(id, organization_id)
);
create index customer_receipts_customer_idx on public.customer_receipts (customer_id);
alter table public.customer_receipts enable row level security;
create policy customer_receipts_read on public.customer_receipts for select to authenticated using (app.has_perm(branch_id, 'invoice.view'));
create trigger customer_receipts_immutable before update or delete on public.customer_receipts for each row execute function app.forbid_change();

create or replace function app.customer_balance(p_customer uuid) returns bigint
language sql stable security definer set search_path = '' as $$
  select (select coalesce(sum(p.amount_baisa), 0) from public.payments p join public.invoices i on i.id = p.invoice_id where i.customer_id = p_customer and p.method = 'credit')
       - (select coalesce(sum(f.amount_baisa), 0) from public.refunds f join public.invoices i on i.id = f.invoice_id where i.customer_id = p_customer and f.method = 'credit')
       - (select coalesce(sum(amount_baisa), 0) from public.customer_receipts where customer_id = p_customer);
$$;
revoke all on function app.customer_balance(uuid) from public;

-- رصيد العميل الآجل على مستوى المنشأة وآخر التحصيلات
create or replace function public.customer_account(p_customer_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_c public.customers;
begin
  select * into v_c from public.customers where id = p_customer_id;
  if not found or not app.has_org(v_c.organization_id) then perform app.fail('CUSTOMER_NOT_FOUND'); end if;
  return jsonb_build_object('customer_id', v_c.id, 'name', v_c.name, 'phone', v_c.phone,
    'balance_baisa', app.customer_balance(v_c.id),
    'receipts', coalesce((select jsonb_agg(jsonb_build_object('created_at', r.created_at, 'method', r.method, 'amount_baisa', r.amount_baisa, 'reference', r.reference) order by r.created_at desc)
      from (select * from public.customer_receipts where customer_id = v_c.id order by created_at desc limit 20) r), '[]'::jsonb));
end $$;

-- تحصيل من رصيد العميل الآجل داخل وردية مفتوحة. النقدي يدخل درج الوردية.
create or replace function public.collect_customer_payment(p_operation_id uuid, p_cash_session_id uuid, p_customer_id uuid, p_method text, p_amount_baisa bigint, p_reference text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_sess public.cash_sessions; v_c public.customers; v_r jsonb; v_id uuid; v_bal bigint;
  v_hash text := md5(jsonb_build_object('s', p_cash_session_id, 'c', p_customer_id, 'm', p_method, 'a', p_amount_baisa, 'r', p_reference)::text);
begin
  v_r := app.op_replay(p_operation_id, 'customer_receipt', v_hash); if v_r is not null then return v_r; end if;
  select * into v_sess from public.cash_sessions where id = p_cash_session_id for update;
  if not found then perform app.fail('SESSION_NOT_FOUND'); end if;
  if not app.has_perm(v_sess.branch_id, 'pos.sell') then perform app.fail('FORBIDDEN'); end if;
  if v_sess.status <> 'open' then perform app.fail('SESSION_CLOSED'); end if;
  if v_sess.opened_by <> (select auth.uid()) then perform app.fail('SESSION_NOT_YOURS'); end if;
  select * into v_c from public.customers where id = p_customer_id and organization_id = v_sess.organization_id for update;
  if not found then perform app.fail('CUSTOMER_NOT_FOUND'); end if;
  if p_method not in ('cash', 'card', 'transfer') or p_amount_baisa is null or p_amount_baisa <= 0 then perform app.fail('INVALID_AMOUNT'); end if;
  v_bal := app.customer_balance(v_c.id);
  if p_amount_baisa > v_bal then perform app.fail('AMOUNT_EXCEEDS_BALANCE', jsonb_build_object('balance_baisa', v_bal)); end if;
  insert into public.customer_receipts (organization_id, branch_id, customer_id, cash_session_id, method, amount_baisa, reference, created_by)
  values (v_sess.organization_id, v_sess.branch_id, v_c.id, v_sess.id, p_method, p_amount_baisa, nullif(btrim(p_reference), ''), (select auth.uid()))
  returning id into v_id;
  if p_method = 'cash' then
    insert into public.cash_movements (organization_id, branch_id, cash_session_id, movement_type, amount_baisa, source_type, source_id, note, created_by)
    values (v_sess.organization_id, v_sess.branch_id, v_sess.id, 'cash_in', p_amount_baisa, 'customer_receipt', v_id, 'تحصيل آجل — ' || v_c.name, (select auth.uid()));
  end if;
  perform app.post_journal(v_sess.organization_id, v_sess.branch_id, v_sess.business_day_id, 'customer_receipt', v_id, 'تحصيل من العميل ' || v_c.name,
    jsonb_build_array(
      jsonb_build_array(case p_method when 'cash' then 'cash_on_hand' when 'card' then 'card_clearing' else 'bank_transfer_clearing' end, p_amount_baisa, 0),
      jsonb_build_array('accounts_receivable', 0, p_amount_baisa)));
  perform app.audit(v_sess.organization_id, v_sess.branch_id, 'customer.receipt', 'customer', v_c.id, null, null, jsonb_build_object('amount_baisa', p_amount_baisa, 'method', p_method));
  return app.op_store(p_operation_id, v_sess.organization_id, v_sess.branch_id, v_sess.id, 'customer_receipt', v_hash,
    jsonb_build_object('status', 'recorded', 'receipt_id', v_id, 'balance_baisa', v_bal - p_amount_baisa));
end $$;

revoke all on function public.customer_account(uuid), public.collect_customer_payment(uuid, uuid, uuid, text, bigint, text) from public, anon;
grant execute on function public.customer_account(uuid), public.collect_customer_payment(uuid, uuid, uuid, text, bigint, text) to authenticated;
