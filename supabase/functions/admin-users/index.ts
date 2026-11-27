// إنشاء حساب مستخدم أو تغيير رقمه السري. يُستدعى من تطبيق الكاشير بحساب المالك.
// التفويض: الطلب يُتحقق منه بهوية المتصل نفسها (list_users لا تنجح إلا لمن يملك users.manage)،
// ثم تُنفَّذ عملية Auth بمفتاح الخدمة الموجود في أسرار الخادم فقط.
import { createClient } from 'npm:@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};
// الأخطاء التشغيلية تُعاد 200 مع رمز، ليعرض التطبيق رسالة مفهومة.
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  try {
    const url = Deno.env.get('SUPABASE_URL')!;
    const auth = req.headers.get('Authorization') ?? '';
    if (!auth.startsWith('Bearer ')) return json({ error: 'NOT_AUTHENTICATED' }, 401);
    const caller = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: auth } } });
    const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
    const b = await req.json();
    const org = String(b.organization_id ?? '');

    const { error: permErr } = await caller.rpc('list_users', { p_organization_id: org });
    if (permErr) return json({ error: 'FORBIDDEN' });

    const password = String(b.password ?? '');
    if (password.length < 8) return json({ error: 'INVALID_REQUEST' });

    if (b.action === 'set_password') {
      const { data: m } = await admin.from('memberships').select('id').eq('user_id', b.user_id).eq('organization_id', org).limit(1);
      if (!m || m.length === 0) return json({ error: 'NOT_FOUND' });
      const { error } = await admin.auth.admin.updateUserById(b.user_id, { password });
      return error ? json({ error: 'INVALID_REQUEST' }) : json({ status: 'password_set' });
    }

    if (b.action === 'create') {
      const username = String(b.username ?? '').trim().toLowerCase();
      const domain = String(b.login_domain ?? 'lamsat.test').toLowerCase();
      if (!/^[a-z0-9._-]{3,30}$/.test(username) || !/^[a-z0-9.-]{3,60}$/.test(domain) || !String(b.full_name ?? '').trim()) return json({ error: 'INVALID_REQUEST' });
      const { data: created, error } = await admin.auth.admin.createUser({ email: `${username}@${domain}`, password, email_confirm: true });
      if (error || !created?.user) return json({ error: /already|exists|registered/i.test(error?.message ?? '') ? 'USERNAME_EXISTS' : 'INVALID_REQUEST' });
      const id = created.user.id;
      const { error: pErr } = await admin.from('profiles').insert({ id, full_name: String(b.full_name).trim() });
      // الدور يُحفظ بهوية المتصل حتى تُطبَّق قواعد الصلاحيات نفسها
      const { error: rErr } = pErr ? { error: pErr } : await caller.rpc('save_user_role', {
        p: { organization_id: org, user_id: id, role_code: b.role_code, branch_id: b.branch_id ?? null, max_discount_bp: b.max_discount_bp ?? 0, is_active: b.is_active ?? true },
      });
      if (rErr) {
        await admin.auth.admin.deleteUser(id); // لا نترك حسابًا بلا دور
        const code = (rErr.message ?? '').match(/[A-Z_]{4,}/)?.[0];
        return json({ error: code ?? 'INVALID_REQUEST' });
      }
      return json({ status: 'created', user_id: id });
    }
    return json({ error: 'INVALID_REQUEST' });
  } catch (_) {
    return json({ error: 'INVALID_REQUEST' }, 400);
  }
});
