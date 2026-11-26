-- محاكاة الحد الأدنى من بيئة Supabase لتشغيل الترحيلات على PostgreSQL محلي في الاختبارات فقط
create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;
create schema auth;
create table auth.users (id uuid primary key, email text unique);
create function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claims', true)::json->>'sub', '')::uuid $$;
grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;
grant usage on schema public to anon, authenticated, service_role;
insert into auth.users (id, email) values
  ('a0000000-0000-4000-8000-000000000001', 'owner@lamsat.test'),
  ('a0000000-0000-4000-8000-000000000002', 'manager.tires@lamsat.test'),
  ('a0000000-0000-4000-8000-000000000003', 'accountant@lamsat.test'),
  ('a0000000-0000-4000-8000-000000000004', 'cashier.tint@lamsat.test'),
  ('a0000000-0000-4000-8000-000000000005', 'cashier.tires@lamsat.test');
