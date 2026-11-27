-- قرار المالك: إعدادات الضريبة ونص الفاتورة يضبطها المالك أو مدير الفرع لفرعه.
-- تحديد من يفتح الورديات يبقى للمالك وحده (حتى لا يمنح المدير الصلاحية لنفسه).
insert into public.role_permissions (role_code, permission_code) values ('branch_manager', 'settings.manage') on conflict do nothing;

do $$
declare d text; target constant text := 'if p_settings ? ''shift_roles'' then';
begin
  d := pg_get_functiondef('public.update_branch_settings(uuid,jsonb)'::regprocedure);
  if position(target in d) = 0 then raise exception 'patch target missing'; end if;
  execute replace(d, target, 'if p_settings ? ''shift_roles'' and not app.has_org_perm(v_old.organization_id, ''users.manage'') then perform app.fail(''FORBIDDEN''); end if;
  ' || target);
end $$;
