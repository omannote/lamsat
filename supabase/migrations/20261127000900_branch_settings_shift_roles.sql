-- لمسات | إعدادات الفرع من لوحة الإدارة، والأدوار المسموح لها بفتح وردية (الكاشير افتراضيًا فقط)

alter table public.branch_settings add column shift_roles text[] not null default '{cashier}';

-- فتح الوردية لحساب دوره غير مفعّل في إعدادات الفرع يُرفض، حتى لو استُدعيت الدالة مباشرة.
create or replace function app.session_role_allowed() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (
    select 1 from public.memberships m join public.branch_settings s on s.branch_id = new.branch_id
    where m.user_id = new.opened_by and m.is_active and m.organization_id = new.organization_id
      and (m.branch_id is null or m.branch_id = new.branch_id) and m.role_code = any (s.shift_roles)) then
    raise exception using errcode = 'P0001', message = 'SHIFT_NOT_ENABLED_FOR_ROLE', detail = '';
  end if;
  return new;
end $$;
create trigger cash_sessions_role_allowed before insert on public.cash_sessions
  for each row execute function app.session_role_allowed();

-- p_settings: { shift_roles?, tax_enabled?, tax_rate_bp?, prices_include_tax?, receipt_header_ar?, receipt_footer_ar? }
create or replace function public.update_branch_settings(p_branch_id uuid, p_settings jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_old public.branch_settings; v_new public.branch_settings; v_roles text[];
begin
  if not app.has_perm(p_branch_id, 'settings.manage') then perform app.fail('FORBIDDEN'); end if;
  select * into v_old from public.branch_settings where branch_id = p_branch_id for update;
  if not found then perform app.fail('NOT_FOUND'); end if;
  if p_settings ? 'shift_roles' then
    select array_agg(distinct r) into v_roles from jsonb_array_elements_text(p_settings->'shift_roles') r where r in (select code from public.roles);
    v_roles := coalesce(v_roles, '{}') || case when 'cashier' = any (coalesce(v_roles, '{}')) then '{}'::text[] else '{cashier}'::text[] end;
  end if;
  if (p_settings->>'tax_rate_bp')::int not between 0 and 10000 then perform app.fail('INVALID_AMOUNT'); end if;
  update public.branch_settings set
    shift_roles = coalesce(v_roles, shift_roles),
    tax_enabled = coalesce((p_settings->>'tax_enabled')::boolean, tax_enabled),
    tax_rate_bp = coalesce((p_settings->>'tax_rate_bp')::int, tax_rate_bp),
    prices_include_tax = coalesce((p_settings->>'prices_include_tax')::boolean, prices_include_tax),
    receipt_header_ar = case when p_settings ? 'receipt_header_ar' then nullif(btrim(p_settings->>'receipt_header_ar'), '') else receipt_header_ar end,
    receipt_footer_ar = case when p_settings ? 'receipt_footer_ar' then nullif(btrim(p_settings->>'receipt_footer_ar'), '') else receipt_footer_ar end,
    updated_at = now()
  where branch_id = p_branch_id returning * into v_new;
  perform app.audit(v_new.organization_id, p_branch_id, 'branch_settings.update', 'branch', p_branch_id, null,
    to_jsonb(v_old) - 'updated_at', to_jsonb(v_new) - 'updated_at');
  return to_jsonb(v_new);
end $$;
revoke all on function public.update_branch_settings(uuid, jsonb) from public, anon;
grant execute on function public.update_branch_settings(uuid, jsonb) to authenticated, service_role;
