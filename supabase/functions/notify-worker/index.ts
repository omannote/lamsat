// عامل إشعارات العملاء: يعالج الأحداث المعلّقة في notification_events.
// القناة الأولى واتساب Cloud API (قالب معتمد)، وعند فشل مؤكد يُجرَّب iSmartSMS إن كان مفعّلًا.
// بلا أسرار المزوّد أو والإشعارات غير مفعّلة: تُسجَّل الرسالة بحالة mock ولا يُرسل شيء لأي عميل.
// الاستدعاء: مالك المنشأة من التطبيق (JWT)، أو مهمة مجدولة بترويسة x-worker-secret.
import { createClient } from 'npm:@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-worker-secret',
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
const omr = (baisa: number) => `${Math.floor(baisa / 1000)}.${String(baisa % 1000).padStart(3, '0')}`;

function phoneIntl(raw: string | null): string | null {
  let d = (raw ?? '').replace(/[^0-9]/g, '');
  if (d.startsWith('00')) d = d.slice(2);
  if (d.length === 8) d = '968' + d;
  return d.length >= 10 && d.length <= 15 ? d : null;
}

async function sendWhatsApp(to: string, template: string, lang: string, params: string[]) {
  const token = Deno.env.get('WHATSAPP_TOKEN'), phoneId = Deno.env.get('WHATSAPP_PHONE_ID');
  if (!token || !phoneId) return { configured: false, ok: false, error: 'not_configured' };
  const res = await fetch(`https://graph.facebook.com/v21.0/${phoneId}/messages`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      messaging_product: 'whatsapp', to, type: 'template',
      template: { name: template, language: { code: lang }, components: [{ type: 'body', parameters: params.map((text) => ({ type: 'text', text })) }] },
    }),
  });
  return { configured: true, ok: res.ok, error: res.ok ? null : `whatsapp_${res.status}` };
}

async function sendSms(to: string, message: string, arabic: boolean) {
  const user = Deno.env.get('ISMART_USER'), pass = Deno.env.get('ISMART_PASSWORD'), header = Deno.env.get('ISMART_HEADER');
  if (!user || !pass || !header) return { configured: false, ok: false, error: 'not_configured' };
  const body = new URLSearchParams({ UserId: user, Password: pass, MobileNo: to, Message: message, Lang: arabic ? '64' : '0', Header: header });
  const res = await fetch('https://www.ismartsms.net/iBulkSMS/HttpWS/SMSDynamicRefIntlAPI.aspx', { method: 'POST', body });
  const text = (await res.text()).trim();
  return { configured: true, ok: res.ok && text === '1', error: res.ok && text === '1' ? null : `sms_${text.slice(0, 20) || res.status}` };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  const url = Deno.env.get('SUPABASE_URL')!;
  const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
  const body = await req.json().catch(() => ({}));

  // التفويض
  let orgFilter: string | null = null;
  const secret = Deno.env.get('WORKER_SECRET');
  if (secret && req.headers.get('x-worker-secret') === secret) {
    orgFilter = null; // المهمة المجدولة تعالج كل المنشآت المفعّلة
  } else {
    const auth = req.headers.get('Authorization') ?? '';
    const caller = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: auth } } });
    const { error } = await caller.rpc('notification_overview', { p_organization_id: body.organization_id });
    if (error) return json({ error: 'FORBIDDEN' });
    orgFilter = String(body.organization_id);
  }

  let q = admin.from('notification_events').select('*').eq('status', 'pending').lt('attempts', 3).order('created_at').limit(20);
  if (orgFilter) q = q.eq('organization_id', orgFilter);
  const { data: events, error } = await q;
  if (error) return json({ error: 'INVALID_REQUEST' }, 500);

  const result = { processed: 0, sent: 0, mock: 0, failed: 0 };
  for (const e of events ?? []) {
    result.processed++;
    const { data: s } = await admin.from('notification_settings').select('*').eq('organization_id', e.organization_id).maybeSingle();
    const { data: c } = await admin.from('customers').select('name, phone').eq('id', e.customer_id).maybeSingle();
    const { data: b } = await admin.from('branches').select('name_ar').eq('id', e.branch_id).maybeSingle();
    const to = phoneIntl(c?.phone ?? null);
    const invoiceNo = String(e.payload?.invoice_no ?? '');
    const total = omr(Number(e.payload?.total_baisa ?? 0));
    const message = e.lang === 'en'
      ? `Thank you for visiting ${b?.name_ar ?? ''}. Invoice ${invoiceNo}, total ${total} OMR.`
      : `شكرًا لزيارتكم ${b?.name_ar ?? ''}. فاتورتكم ${invoiceNo} بإجمالي ${total} ر.ع`;
    const patch: Record<string, unknown> = { attempts: (e.attempts ?? 0) + 1, message };

    if (!to) {
      Object.assign(patch, { status: 'failed', last_error: 'invalid_phone' }); result.failed++;
    } else if (!s?.enabled) {
      Object.assign(patch, { status: 'mock', channel: 'mock', last_error: 'notifications_disabled', sent_at: new Date().toISOString() }); result.mock++;
    } else {
      const wa = await sendWhatsApp(to, s.whatsapp_template, s.whatsapp_lang, [c?.name ?? '', invoiceNo, total]);
      if (wa.ok) {
        Object.assign(patch, { status: 'sent', channel: 'whatsapp', last_error: null, sent_at: new Date().toISOString() }); result.sent++;
      } else {
        const sms = s.sms_fallback ? await sendSms(to, message, e.lang !== 'en') : { configured: false, ok: false, error: 'sms_disabled' };
        if (sms.ok) {
          Object.assign(patch, { status: 'sent', channel: 'sms', last_error: wa.error, sent_at: new Date().toISOString() }); result.sent++;
        } else if (!wa.configured && !sms.configured) {
          Object.assign(patch, { status: 'mock', channel: 'mock', last_error: 'no_provider_secrets', sent_at: new Date().toISOString() }); result.mock++;
        } else {
          const final = (e.attempts ?? 0) + 1 >= 3;
          Object.assign(patch, { status: final ? 'failed' : 'pending', last_error: [wa.error, sms.error].filter(Boolean).join(' / ') });
          if (final) result.failed++;
        }
      }
    }
    await admin.from('notification_events').update(patch).eq('id', e.id);
  }
  return json(result);
});
