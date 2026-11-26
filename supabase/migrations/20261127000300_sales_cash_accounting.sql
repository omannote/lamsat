-- لمسات | اليوم المحاسبي، الورديات، الفواتير، المدفوعات، القيود، طلبات العمليات، أحداث الإشعار

create table public.business_days (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  branch_id       uuid not null,
  business_date   date not null,
  status          text not null default 'open' check (status in ('open','closed')),
  opened_at       timestamptz not null default now(),
  opened_by       uuid,
  closed_at       timestamptz,
  closed_by       uuid,
  unique (branch_id, business_date),
  foreign key (branch_id, organization_id) references public.branches(id, organization_id)
);
create unique index business_days_one_open on public.business_days (branch_id) where status = 'open';

create table public.cash_sessions (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  branch_id       uuid not null,
  device_id       uuid not null references public.devices(id),
  business_day_id uuid not null references public.business_days(id),
  opened_by       uuid not null references public.profiles(id),
  opened_at       timestamptz not null default now(),
  opening_cash_baisa bigint not null check (opening_cash_baisa >= 0),
  status          text not null default 'open' check (status in ('open','closed')),
  closed_at       timestamptz,
  closed_by       uuid,
  expected_cash_baisa bigint,
  counted_cash_baisa  bigint,
  foreign key (branch_id, organization_id) references public.branches(id, organization_id)
);
create unique index cash_sessions_one_open_per_device on public.cash_sessions (device_id) where status = 'open';
create index cash_sessions_branch_idx on public.cash_sessions (branch_id, opened_at desc);

create table public.invoices (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  branch_id       uuid not null,
  invoice_no      text not null,
  seq             bigint not null,
  status          text not null default 'approved' check (status in ('approved','voided')),
  business_day_id uuid not null references public.business_days(id),
  cash_session_id uuid not null references public.cash_sessions(id),
  device_id       uuid not null references public.devices(id),
  cashier_id      uuid not null references public.profiles(id),
  customer_id     uuid,
  vehicle_id      uuid,
  tax_rate_bp     int not null,
  prices_include_tax boolean not null,
  subtotal_baisa  bigint not null,          -- إجمالي البنود قبل الخصم
  discount_baisa  bigint not null,
  net_baisa       bigint not null,          -- الصافي قبل الضريبة
  tax_baisa       bigint not null,
  total_baisa     bigint not null,          -- المستحق شاملًا الضريبة
  paid_baisa      bigint not null,
  change_baisa    bigint not null default 0,
  note            text,
  operation_id    uuid not null unique,
  version         int not null default 1,
  print_count     int not null default 0,
  approved_at     timestamptz not null default now(),
  unique (organization_id, invoice_no),
  unique (branch_id, seq),
  foreign key (branch_id, organization_id) references public.branches(id, organization_id),
  foreign key (customer_id, organization_id) references public.customers(id, organization_id),
  foreign key (vehicle_id, organization_id) references public.vehicles(id, organization_id),
  check (total_baisa = net_baisa + tax_baisa),
  check (paid_baisa = total_baisa)
);
create index invoices_branch_time_idx on public.invoices (branch_id, approved_at desc);
create index invoices_day_idx on public.invoices (business_day_id);
create index invoices_customer_idx on public.invoices (customer_id) where customer_id is not null;

create table public.invoice_lines (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  branch_id       uuid not null,
  invoice_id      uuid not null references public.invoices(id),
  line_no         int not null,
  product_id      uuid not null references public.products(id),
  kind            text not null,
  sku             text not null,
  description_ar  text not null,
  unit            text not null,
  qty             numeric(12,3) not null check (qty > 0),
  unit_price_baisa bigint not null,
  gross_baisa     bigint not null,
  discount_baisa  bigint not null default 0 check (discount_baisa >= 0),
  taxable         boolean not null,
  tax_rate_bp     int not null,
  net_baisa       bigint not null,
  tax_baisa       bigint not null,
  total_baisa     bigint not null,
  unique (invoice_id, line_no),
  check (discount_baisa <= gross_baisa),
  check (total_baisa = net_baisa + tax_baisa)
);

-- التكلفة في جدول مستقل حتى لا تُعرض للكاشير
create table public.invoice_line_costs (
  invoice_line_id uuid primary key references public.invoice_lines(id),
  organization_id uuid not null,
  branch_id       uuid not null,
  cost_baisa      bigint not null default 0
);

create table public.payments (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  branch_id       uuid not null,
  invoice_id      uuid not null references public.invoices(id),
  cash_session_id uuid not null references public.cash_sessions(id),
  method          text not null check (method in ('cash','card')),
  amount_baisa    bigint not null check (amount_baisa > 0),
  tendered_baisa  bigint,
  card_reference  text,
  created_at      timestamptz not null default now()
);
create index payments_invoice_idx on public.payments (invoice_id);
create index payments_session_idx on public.payments (cash_session_id, method);

create table public.cash_movements (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  branch_id       uuid not null,
  cash_session_id uuid not null references public.cash_sessions(id),
  movement_type   text not null check (movement_type in ('opening','sale','refund','cash_in','cash_out','closing')),
  amount_baisa    bigint not null,           -- موجب = دخول للدرج، سالب = خروج
  source_type     text,
  source_id       uuid,
  note            text,
  created_by      uuid,
  created_at      timestamptz not null default now()
);
create index cash_movements_session_idx on public.cash_movements (cash_session_id);

-- ───────────── المحاسبة ─────────────
create table public.accounts (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  code            text not null,
  name_ar         text not null,
  name_en         text,
  account_type    text not null check (account_type in ('asset','liability','equity','revenue','expense')),
  system_key      text,
  is_active       boolean not null default true,
  unique (organization_id, code)
);
create unique index accounts_system_key_uniq on public.accounts (organization_id, system_key) where system_key is not null;

create table public.journal_entries (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  branch_id       uuid not null,
  business_day_id uuid references public.business_days(id),
  entry_no        bigint generated always as identity,
  source_type     text not null,
  source_id       uuid not null,
  description     text,
  created_by      uuid,
  created_at      timestamptz not null default now(),
  foreign key (branch_id, organization_id) references public.branches(id, organization_id)
);
create index journal_entries_source_idx on public.journal_entries (source_type, source_id);
create index journal_entries_branch_idx on public.journal_entries (branch_id, created_at desc);

create table public.journal_lines (
  id              bigint generated always as identity primary key,
  entry_id        uuid not null references public.journal_entries(id),
  organization_id uuid not null,
  branch_id       uuid not null,
  account_id      uuid not null references public.accounts(id),
  debit_baisa     bigint not null default 0 check (debit_baisa >= 0),
  credit_baisa    bigint not null default 0 check (credit_baisa >= 0),
  check ((debit_baisa = 0) <> (credit_baisa = 0))
);
create index journal_lines_entry_idx on public.journal_lines (entry_id);
create index journal_lines_account_idx on public.journal_lines (account_id);

-- القيد يجب أن يتوازن عند نهاية المعاملة
create or replace function app.check_journal_balanced() returns trigger
language plpgsql set search_path = '' as $$
declare v_d bigint; v_c bigint;
begin
  select coalesce(sum(debit_baisa),0), coalesce(sum(credit_baisa),0) into v_d, v_c
  from public.journal_lines where entry_id = new.entry_id;
  if v_d <> v_c then
    raise exception using errcode = 'P0001', message = 'JOURNAL_UNBALANCED',
      detail = format('entry %s debit %s credit %s', new.entry_id, v_d, v_c);
  end if;
  return null;
end $$;
create constraint trigger journal_lines_balanced after insert or update on public.journal_lines
  deferrable initially deferred for each row execute function app.check_journal_balanced();

-- ───────────── طلبات العمليات (منع التكرار) ─────────────
create table public.operation_requests (
  operation_id    uuid primary key,
  organization_id uuid not null,
  branch_id       uuid not null,
  device_id       uuid,
  cash_session_id uuid,
  user_id         uuid not null,
  op_type         text not null,
  request_hash    text not null,
  result          jsonb not null,
  created_at      timestamptz not null default now()
);
create index operation_requests_session_idx on public.operation_requests (cash_session_id, created_at desc);

-- ───────────── أحداث الإشعار (الطابور يُنفَّذ في المرحلة 4) ─────────────
create table public.notification_events (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  branch_id       uuid not null,
  event_type      text not null check (event_type in
    ('invoice_issued','deposit_recorded','vehicle_ready','invoice_voided','invoice_adjusted')),
  customer_id     uuid not null,
  invoice_id      uuid references public.invoices(id),
  lang            text not null default 'ar',
  payload         jsonb not null default '{}',
  status          text not null default 'pending',
  created_at      timestamptz not null default now(),
  foreign key (customer_id, organization_id) references public.customers(id, organization_id)
);
create index notification_events_pending_idx on public.notification_events (created_at) where status = 'pending';

-- منع التعديل والحذف المباشر على السجلات المالية حتى لمالك الجدول عبر الدوال الخاطئة
create or replace function app.forbid_change() returns trigger language plpgsql as $$
begin
  raise exception using errcode = 'P0001', message = 'IMMUTABLE_RECORD', detail = tg_table_name;
end $$;
create trigger invoice_lines_immutable before update or delete on public.invoice_lines for each row execute function app.forbid_change();
create trigger payments_immutable      before update or delete on public.payments      for each row execute function app.forbid_change();
create trigger journal_lines_immutable before update or delete on public.journal_lines for each row execute function app.forbid_change();
create trigger stock_movements_immutable before update or delete on public.stock_movements for each row execute function app.forbid_change();
create trigger audit_log_immutable     before update or delete on public.audit_log     for each row execute function app.forbid_change();
