-- مستخدمون تجريبيون لبيئة التطوير على Supabase فقط. لا تُشغَّل على الإنتاج.
-- قبل التشغيل:  set lamsat.demo_password = '<كلمة مرور تجريبية>';
do $$
declare
  v_pw text := current_setting('lamsat.demo_password');
  u record;
begin
  if coalesce(length(v_pw), 0) < 10 then raise exception 'set lamsat.demo_password (10+ chars) first'; end if;
  for u in select * from (values
    ('a0000000-0000-4000-8000-000000000001'::uuid, 'owner@lamsat.test'),
    ('a0000000-0000-4000-8000-000000000002'::uuid, 'manager.tires@lamsat.test'),
    ('a0000000-0000-4000-8000-000000000003'::uuid, 'accountant@lamsat.test'),
    ('a0000000-0000-4000-8000-000000000004'::uuid, 'cashier.tint@lamsat.test'),
    ('a0000000-0000-4000-8000-000000000005'::uuid, 'cashier.tires@lamsat.test')) t(id, email)
  loop
    insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
      confirmation_token, email_change, email_change_token_new, recovery_token)
    values ('00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated', u.email,
      extensions.crypt(v_pw, extensions.gen_salt('bf')), now(),
      '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', '', '', '')
    on conflict (id) do nothing;
    insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
    select gen_random_uuid(), u.id, u.id::text,
      jsonb_build_object('sub', u.id::text, 'email', u.email, 'email_verified', true), 'email', now(), now(), now()
    where not exists (select 1 from auth.identities where user_id = u.id);
  end loop;
end $$;
