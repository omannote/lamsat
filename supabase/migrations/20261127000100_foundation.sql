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
