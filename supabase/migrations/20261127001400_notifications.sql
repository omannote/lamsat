-- إشعارات العملاء (المرحلة 4): إعدادات لكل منشأة وسجل محاولات. الإرسال تنفذه دالة الخادم notify-worker.
-- الإرسال الحقيقي معطّل افتراضيًا: يتطلب تفعيله من الإعدادات ووجود أسرار المزوّد في الخادم؛ وإلا تُسجَّل الرسالة «تجريبية» ولا تُرسل.

create table public.notification_settings (
  organization_id uuid primary key references public.organizations(id),
  enabled boolean not null default false,
  whatsapp_template text not null default 'invoice_issued',
  whatsapp_lang text not null default 'ar',
  sms_fallback boolean not null default true,
  updated_at timestamptz not null default now());
alter table public.notification_settings enable row level security;
create policy notification_settings_read on public.notification_settings for select to authenticated using (app.has_org_perm(organization_id, 'notifications.manage'));
insert into public.notification_settings (organization_id) select id from public.organizations on conflict do nothing;

alter table public.notification_events
  add column attempts int not null default 0,
  add column channel text,
  add column last_error text,
  add column message text,
  add column sent_at timestamptz;

create or replace function public.notification_overview(p_organization_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if not app.has_org_perm(p_organization_id, 'notifications.manage') then perform app.fail('FORBIDDEN'); end if;
  return jsonb_build_object(
    'settings', (select to_jsonb(s) from public.notification_settings s where s.organization_id = p_organization_id),
    'pending', (select count(*) from public.notification_events where organization_id = p_organization_id and status = 'pending'),
    'events', coalesce((select jsonb_agg(jsonb_build_object('created_at', e.created_at, 'event_type', e.event_type, 'status', e.status, 'channel', e.channel,
        'attempts', e.attempts, 'last_error', e.last_error, 'customer', (select name from public.customers where id = e.customer_id),
        'invoice_no', e.payload->>'invoice_no') order by e.created_at desc)
      from (select * from public.notification_events where organization_id = p_organization_id order by created_at desc limit 50) e), '[]'::jsonb));
end $$;

create or replace function public.update_notification_settings(p_organization_id uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v public.notification_settings;
begin
  if not app.has_org_perm(p_organization_id, 'notifications.manage') then perform app.fail('FORBIDDEN'); end if;
  insert into public.notification_settings (organization_id) values (p_organization_id) on conflict do nothing;
  update public.notification_settings set
    enabled = coalesce((p->>'enabled')::boolean, enabled),
    sms_fallback = coalesce((p->>'sms_fallback')::boolean, sms_fallback),
    whatsapp_template = coalesce(nullif(btrim(p->>'whatsapp_template'), ''), whatsapp_template),
    whatsapp_lang = coalesce(nullif(btrim(p->>'whatsapp_lang'), ''), whatsapp_lang),
    updated_at = now()
  where organization_id = p_organization_id returning * into v;
  perform app.audit(p_organization_id, null, 'notifications.settings', 'organization', p_organization_id, null, null, to_jsonb(v));
  return to_jsonb(v);
end $$;

revoke all on function public.notification_overview(uuid), public.update_notification_settings(uuid, jsonb) from public, anon;
grant execute on function public.notification_overview(uuid), public.update_notification_settings(uuid, jsonb) to authenticated, service_role;
