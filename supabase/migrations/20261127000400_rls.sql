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
