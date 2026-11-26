-- لمسات | المرحلة 1 — التأسيس: المنشآت، الفروع، الأجهزة، المستخدمون، الأدوار والصلاحيات
-- كل المبالغ بالبيسة (bigint). 1 ر.ع = 1000 بيسة.

create schema if not exists app;            -- دوال داخلية غير معروضة عبر API
revoke all on schema app from public;
grant usage on schema app to authenticated, service_role;

-- ───────────── المنشآت والفروع ─────────────
create table public.organizations (
  id          uuid primary key default gen_random_uuid(),
  name_ar     text not null,
  name_en     text,
  tax_registration_no text,
  timezone    text not null default 'Asia/Muscat',
  created_at  timestamptz not null default now()
);

create table public.branches (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  code            text not null,
  name_ar         text not null,
  name_en         text,
  phone           text,
  address_ar      text,
  latitude        numeric(9,6),
  longitude       numeric(9,6),
  geofence_radius_m int,
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  unique (organization_id, code),
  unique (id, organization_id)
);

create table public.branch_settings (
  branch_id          uuid primary key references public.branches(id),
  organization_id    uuid not null references public.organizations(id),
  tax_enabled        boolean not null default false,
  tax_rate_bp        int not null default 500 check (tax_rate_bp between 0 and 10000),
  prices_include_tax boolean not null default true,
  invoice_prefix     text not null,
  receipt_header_ar  text,
  receipt_footer_ar  text,
  updated_at         timestamptz not null default now()
);

create table public.branch_counters (
  branch_id   uuid not null references public.branches(id),
  counter_key text not null,
  last_value  bigint not null default 0,
  primary key (branch_id, counter_key)
);

create table public.devices (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  branch_id       uuid not null,
  code            text not null,
  name            text not null,
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  unique (organization_id, code),
  foreign key (branch_id, organization_id) references public.branches(id, organization_id)
);

-- ───────────── المستخدمون والأدوار ─────────────
create table public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  full_name  text not null,
  phone      text,
  is_active  boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.roles (
  code    text primary key,
  name_ar text not null,
  name_en text not null
);

create table public.permissions (
  code           text primary key,
  description_ar text not null
);

create table public.role_permissions (
  role_code       text not null references public.roles(code) on delete cascade,
  permission_code text not null references public.permissions(code) on delete cascade,
  primary key (role_code, permission_code)
);

-- branch_id = null يعني جميع فروع المنشأة
create table public.memberships (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  user_id         uuid not null references public.profiles(id) on delete cascade,
  branch_id       uuid,
  role_code       text not null references public.roles(code),
  max_discount_bp int not null default 0 check (max_discount_bp between 0 and 10000),
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  foreign key (branch_id, organization_id) references public.branches(id, organization_id)
);
create unique index memberships_uniq on public.memberships
  (user_id, organization_id, coalesce(branch_id, '00000000-0000-0000-0000-000000000000'::uuid), role_code);
create index memberships_user_idx on public.memberships (user_id) where is_active;

-- ───────────── سجل التدقيق ─────────────
create table public.audit_log (
  id              bigint generated always as identity primary key,
  organization_id uuid not null references public.organizations(id),
  branch_id       uuid references public.branches(id),
  user_id         uuid,
  action          text not null,
  entity_type     text not null,
  entity_id       uuid,
  reason          text,
  old_values      jsonb,
  new_values      jsonb,
  created_at      timestamptz not null default now()
);
create index audit_log_branch_time_idx on public.audit_log (organization_id, branch_id, created_at desc);
create index audit_log_entity_idx on public.audit_log (entity_type, entity_id);

-- ───────────── دوال التحقق من الصلاحيات ─────────────
create or replace function app.has_org(p_org uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.memberships m
    join public.profiles p on p.id = m.user_id and p.is_active
    where m.user_id = (select auth.uid()) and m.is_active and m.organization_id = p_org);
$$;

create or replace function app.has_branch(p_branch uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.memberships m
    join public.profiles p on p.id = m.user_id and p.is_active
    join public.branches b on b.id = p_branch and b.organization_id = m.organization_id
    where m.user_id = (select auth.uid()) and m.is_active
      and (m.branch_id is null or m.branch_id = p_branch));
$$;

create or replace function app.has_perm(p_branch uuid, p_perm text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.memberships m
    join public.profiles p on p.id = m.user_id and p.is_active
    join public.branches b on b.id = p_branch and b.organization_id = m.organization_id
    join public.role_permissions rp on rp.role_code = m.role_code and rp.permission_code = p_perm
    where m.user_id = (select auth.uid()) and m.is_active
      and (m.branch_id is null or m.branch_id = p_branch));
$$;

-- صلاحية على مستوى المنشأة (في أي فرع من فروعها)
create or replace function app.has_org_perm(p_org uuid, p_perm text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.memberships m
    join public.profiles p on p.id = m.user_id and p.is_active
    join public.role_permissions rp on rp.role_code = m.role_code and rp.permission_code = p_perm
    where m.user_id = (select auth.uid()) and m.is_active and m.organization_id = p_org);
$$;

-- صلاحية تشمل كل فروع المنشأة (عضوية بلا فرع محدد)
create or replace function app.has_orgwide_perm(p_org uuid, p_perm text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.memberships m
    join public.profiles p on p.id = m.user_id and p.is_active
    join public.role_permissions rp on rp.role_code = m.role_code and rp.permission_code = p_perm
    where m.user_id = (select auth.uid()) and m.is_active
      and m.organization_id = p_org and m.branch_id is null);
$$;

create or replace function app.fail(p_code text, p_detail jsonb default null) returns void
language plpgsql as $$
begin
  raise exception using errcode = 'P0001', message = p_code, detail = coalesce(p_detail::text, '');
end $$;

create or replace function app.round_baisa(p numeric) returns bigint
language sql immutable as $$ select round(p)::bigint $$;   -- نصف فأكثر يُقرّب لأعلى (بعيدًا عن الصفر)

create or replace function app.audit(p_org uuid, p_branch uuid, p_action text, p_entity_type text,
  p_entity_id uuid, p_reason text default null, p_old jsonb default null, p_new jsonb default null)
returns void language sql security definer set search_path = '' as $$
  insert into public.audit_log (organization_id, branch_id, user_id, action, entity_type, entity_id, reason, old_values, new_values)
  values (p_org, p_branch, (select auth.uid()), p_action, p_entity_type, p_entity_id, p_reason, p_old, p_new);
$$;

revoke all on all functions in schema app from public;
grant execute on all functions in schema app to authenticated, service_role;

-- ───────────── بيانات مرجعية: الأدوار والصلاحيات ─────────────
insert into public.roles (code, name_ar, name_en) values
  ('owner', 'المالك', 'Owner'),
  ('branch_manager', 'مدير الفرع', 'Branch manager'),
  ('accountant', 'المحاسب', 'Accountant'),
  ('cashier', 'الكاشير', 'Cashier');

insert into public.permissions (code, description_ar) values
  ('pos.sell', 'إنشاء واعتماد فواتير البيع'),
  ('pos.discount', 'منح خصم ضمن الحد المسموح'),
  ('cash.open', 'فتح وردية صندوق'),
  ('cash.close', 'إقفال وردية صندوق'),
  ('cash.movement', 'تسجيل قبض وصرف نقدي'),
  ('invoice.view', 'عرض الفواتير'),
  ('invoice.reprint', 'إعادة طباعة الفاتورة'),
  ('invoice.adjust', 'تصحيح فاتورة معتمدة'),
  ('invoice.void', 'إلغاء فاتورة معتمدة'),
  ('invoice.refund', 'تنفيذ مرتجع'),
  ('draft.delete', 'حذف مسودة'),
  ('catalog.view', 'عرض الكتالوج والأسعار'),
  ('catalog.manage', 'إدارة الأصناف والأسعار'),
  ('inventory.view', 'عرض أرصدة المخزون'),
  ('inventory.cost.view', 'عرض التكلفة والهوامش'),
  ('inventory.manage', 'استلام وتسوية وتحويل المخزون'),
  ('reports.view', 'عرض التقارير والمؤشرات'),
  ('reports.export', 'تصدير التقارير'),
  ('accounting.view', 'عرض القيود ودليل الحسابات'),
  ('accounting.manage', 'إدارة القيود والحسابات'),
  ('users.manage', 'إدارة المستخدمين والأدوار'),
  ('settings.manage', 'إدارة إعدادات النظام والفروع'),
  ('notifications.manage', 'إدارة الإشعارات'),
  ('audit.view', 'عرض سجل التدقيق');

insert into public.role_permissions (role_code, permission_code)
select 'owner', code from public.permissions;

insert into public.role_permissions (role_code, permission_code)
select 'branch_manager', unnest(array[
  'pos.sell','pos.discount','cash.open','cash.close','cash.movement','invoice.view','invoice.reprint',
  'invoice.adjust','invoice.void','invoice.refund','draft.delete','catalog.view','inventory.view',
  'inventory.cost.view','inventory.manage','reports.view','reports.export','audit.view']);

insert into public.role_permissions (role_code, permission_code)
select 'accountant', unnest(array[
  'invoice.view','invoice.adjust','catalog.view','inventory.view','inventory.cost.view','reports.view',
  'reports.export','accounting.view','accounting.manage','audit.view']);

insert into public.role_permissions (role_code, permission_code)
select 'cashier', unnest(array[
  'pos.sell','cash.open','cash.close','cash.movement','invoice.view','invoice.reprint','catalog.view','inventory.view']);
-- لمسات | الكتالوج والمخزون والعملاء

create table public.products (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  sku             text not null,
  kind            text not null check (kind in ('item','service')),
  category        text not null default 'general' check (category in ('tire','tint','accessory','service','general')),
  name_ar         text not null,
  name_en         text,
  brand           text,
  unit            text not null default 'قطعة',
  whole_units_only boolean not null default true,
  track_stock     boolean not null default true,
  taxable         boolean not null default true,
  base_price_baisa bigint not null check (base_price_baisa >= 0),
  tire_width      int,
  tire_aspect     int,
  tire_rim        int,
  -- مفتاح بحث المقاس: 205/55R16 → 2055516
  tire_size_key   text generated always as (
    case when tire_width is not null and tire_aspect is not null and tire_rim is not null
         then tire_width::text || tire_aspect::text || tire_rim::text end) stored,
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (organization_id, sku),
  unique (id, organization_id),
  check (kind = 'item' or track_stock = false)
);
create index products_org_name_idx on public.products (organization_id, name_ar);
create index products_tire_size_idx on public.products (organization_id, tire_size_key) where tire_size_key is not null;

create table public.product_barcodes (
  organization_id uuid not null,
  barcode         text not null,
  product_id      uuid not null,
  primary key (organization_id, barcode),
  foreign key (product_id, organization_id) references public.products(id, organization_id) on delete cascade
);

-- سعر خاص بالفرع يتقدّم على سعر المنشأة
create table public.branch_prices (
  branch_id       uuid not null,
  product_id      uuid not null,
  organization_id uuid not null,
  price_baisa     bigint not null check (price_baisa >= 0),
  updated_at      timestamptz not null default now(),
  primary key (branch_id, product_id),
  foreign key (branch_id, organization_id) references public.branches(id, organization_id),
  foreign key (product_id, organization_id) references public.products(id, organization_id)
);

-- دفعات المخزون (FIFO). الرصيد = مجموع qty_on_hand، وكل تغيير له حركة في stock_movements.
create table public.inventory_lots (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  branch_id       uuid not null,
  product_id      uuid not null,
  lot_code        text,
  dot_code        text,
  received_at     timestamptz not null default now(),
  unit_cost_baisa bigint not null check (unit_cost_baisa >= 0),
  qty_received    numeric(12,3) not null check (qty_received > 0),
  qty_on_hand     numeric(12,3) not null check (qty_on_hand >= 0),
  foreign key (branch_id, organization_id) references public.branches(id, organization_id),
  foreign key (product_id, organization_id) references public.products(id, organization_id),
  check (qty_on_hand <= qty_received)
);
create index inventory_lots_fifo_idx on public.inventory_lots (branch_id, product_id, received_at, id) where qty_on_hand > 0;

create table public.stock_movements (
  id              bigint generated always as identity primary key,
  organization_id uuid not null,
  branch_id       uuid not null,
  product_id      uuid not null,
  lot_id          uuid not null references public.inventory_lots(id),
  movement_type   text not null check (movement_type in
    ('opening','purchase_receipt','sale','sale_return','void_reversal','adjustment','transfer_out','transfer_in')),
  qty_delta       numeric(12,3) not null check (qty_delta <> 0),
  unit_cost_baisa bigint not null,
  source_type     text,
  source_id       uuid,
  created_by      uuid,
  created_at      timestamptz not null default now(),
  foreign key (branch_id, organization_id) references public.branches(id, organization_id),
  foreign key (product_id, organization_id) references public.products(id, organization_id)
);
create index stock_movements_product_idx on public.stock_movements (branch_id, product_id, created_at);
create index stock_movements_source_idx on public.stock_movements (source_type, source_id);

create table public.customers (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  name            text not null,
  phone           text,
  preferred_lang  text not null default 'ar' check (preferred_lang in ('ar','en')),
  notes           text,
  created_at      timestamptz not null default now(),
  unique (id, organization_id)
);
create unique index customers_phone_uniq on public.customers (organization_id, phone) where phone is not null;

create table public.vehicles (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  customer_id     uuid,
  plate           text not null,
  make            text,
  model           text,
  created_at      timestamptz not null default now(),
  unique (id, organization_id),
  foreign key (customer_id, organization_id) references public.customers(id, organization_id)
);
create index vehicles_plate_idx on public.vehicles (organization_id, plate);
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
-- لمسات | RLS: القراءة عبر السياسات، والكتابة المالية عبر دوال RPC فقط

create or replace function app.shares_org(p_user uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.memberships mine
    join public.memberships theirs on theirs.organization_id = mine.organization_id
    where mine.user_id = (select auth.uid()) and mine.is_active and theirs.user_id = p_user);
$$;
revoke all on function app.shares_org(uuid) from public;
grant execute on function app.shares_org(uuid) to authenticated, service_role;

do $$
declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated, public', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('grant all on public.%I to service_role', t);
  end loop;
end $$;
-- جداول داخلية لا تُقرأ مباشرة
revoke select on public.branch_counters, public.operation_requests from authenticated;

create policy org_read on public.organizations for select to authenticated using (app.has_org(id));
create policy branch_read on public.branches for select to authenticated using (app.has_branch(id));
create policy branch_settings_read on public.branch_settings for select to authenticated using (app.has_branch(branch_id));
create policy devices_read on public.devices for select to authenticated using (app.has_branch(branch_id));

create policy profiles_read on public.profiles for select to authenticated
  using (id = (select auth.uid()) or app.shares_org(id));
create policy roles_read on public.roles for select to authenticated using (true);
create policy permissions_read on public.permissions for select to authenticated using (true);
create policy role_permissions_read on public.role_permissions for select to authenticated using (true);
create policy memberships_read on public.memberships for select to authenticated
  using (user_id = (select auth.uid()) or app.has_org_perm(organization_id, 'users.manage'));

create policy audit_read on public.audit_log for select to authenticated
  using (case when branch_id is null then app.has_orgwide_perm(organization_id, 'audit.view')
              else app.has_perm(branch_id, 'audit.view') end);

create policy products_read on public.products for select to authenticated
  using (app.has_org_perm(organization_id, 'catalog.view'));
create policy barcodes_read on public.product_barcodes for select to authenticated
  using (app.has_org_perm(organization_id, 'catalog.view'));
create policy branch_prices_read on public.branch_prices for select to authenticated
  using (app.has_perm(branch_id, 'catalog.view'));
create policy lots_read on public.inventory_lots for select to authenticated
  using (app.has_perm(branch_id, 'inventory.cost.view'));
create policy stock_movements_read on public.stock_movements for select to authenticated
  using (app.has_perm(branch_id, 'inventory.cost.view'));

create policy customers_read on public.customers for select to authenticated using (app.has_org(organization_id));
create policy vehicles_read on public.vehicles for select to authenticated using (app.has_org(organization_id));

create policy business_days_read on public.business_days for select to authenticated using (app.has_branch(branch_id));
create policy cash_sessions_read on public.cash_sessions for select to authenticated using (app.has_branch(branch_id));
create policy cash_movements_read on public.cash_movements for select to authenticated using (app.has_branch(branch_id));

create policy invoices_read on public.invoices for select to authenticated using (app.has_perm(branch_id, 'invoice.view'));
create policy invoice_lines_read on public.invoice_lines for select to authenticated using (app.has_perm(branch_id, 'invoice.view'));
create policy payments_read on public.payments for select to authenticated using (app.has_perm(branch_id, 'invoice.view'));
create policy invoice_line_costs_read on public.invoice_line_costs for select to authenticated
  using (app.has_perm(branch_id, 'inventory.cost.view'));

create policy accounts_read on public.accounts for select to authenticated
  using (app.has_org_perm(organization_id, 'accounting.view'));
create policy journal_entries_read on public.journal_entries for select to authenticated
  using (app.has_perm(branch_id, 'accounting.view'));
create policy journal_lines_read on public.journal_lines for select to authenticated
  using (app.has_perm(branch_id, 'accounting.view'));

create policy notification_events_read on public.notification_events for select to authenticated
  using (app.has_perm(branch_id, 'notifications.manage'));

-- ظهور الفاتورة فورًا في لوحة الويب (Supabase Realtime)
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.invoices;
  end if;
end $$;
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
-- لمسات | تثبيت search_path للدوال المساعدة (توصية فاحص الأمان في Supabase)
alter function app.fail(text, jsonb) set search_path = '';
alter function app.round_baisa(numeric) set search_path = '';
alter function app.forbid_change() set search_path = '';
