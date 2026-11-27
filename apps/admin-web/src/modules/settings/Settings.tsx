import { useCallback, useEffect, useState } from 'react';
import { rpc, supabase } from '../../lib/supabase';
import { errorText } from '../../lib/money';
import type { Ctx } from '../../lib/types';

interface BranchSettings {
  branch_id: string; shift_roles: string[]; tax_enabled: boolean; tax_rate_bp: number; prices_include_tax: boolean;
  receipt_header_ar: string | null; receipt_footer_ar: string | null;
}
interface Role { code: string; name_ar: string }

/** إعدادات النظام لكل فرع: من يفتح الورديات، الضريبة، ونص الإيصال. للمالك فقط، وكل تغيير يُسجَّل في التدقيق. */
export function Settings({ ctx }: { ctx: Ctx }) {
  const branches = ctx.branches.filter((b) => b.permissions.includes('settings.manage'));
  const [rows, setRows] = useState<Record<string, BranchSettings>>({});
  const [roles, setRoles] = useState<Role[]>([]);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [busy, setBusy] = useState('');

  const load = useCallback(async () => {
    const [{ data: s }, { data: r }] = await Promise.all([
      supabase.from('branch_settings').select('branch_id, shift_roles, tax_enabled, tax_rate_bp, prices_include_tax, receipt_header_ar, receipt_footer_ar'),
      supabase.from('roles').select('code, name_ar'),
    ]);
    setRows(Object.fromEntries(((s ?? []) as BranchSettings[]).map((x) => [x.branch_id, x])));
    setRoles((r ?? []) as Role[]);
  }, []);
  useEffect(() => { void load(); }, [load]);

  const patch = (id: string, p: Partial<BranchSettings>) => setRows((m) => ({ ...m, [id]: { ...m[id], ...p } }));
  const save = async (id: string) => {
    const s = rows[id];
    setBusy(id); setMsg(null);
    try {
      await rpc('update_branch_settings', { p_branch_id: id, p_settings: {
        shift_roles: s.shift_roles, tax_enabled: s.tax_enabled, tax_rate_bp: s.tax_rate_bp, prices_include_tax: s.prices_include_tax,
        receipt_header_ar: s.receipt_header_ar ?? '', receipt_footer_ar: s.receipt_footer_ar ?? '' } });
      setMsg({ ok: true, text: 'حُفظت الإعدادات. تُطبَّق على أي وردية تُفتح وأي فاتورة تُعتمد بعد الآن.' });
      await load();
    } catch (e) { setMsg({ ok: false, text: errorText((e as Error).message) }); }
    setBusy('');
  };

  return (
    <>
      <header className="page-head"><h1>الإعدادات</h1></header>
      {msg && <div className={`notice ${msg.ok ? 'ok' : 'error'}`}>{msg.text}</div>}
      {branches.map((b) => {
        const s = rows[b.id];
        if (!s) return null;
        return (
          <div className="card" key={b.id}>
            <h2>{b.name_ar}</h2>
            <fieldset>
              <legend>الورديات في تطبيق الكاشير</legend>
              <p className="muted small">الورديات تظهر لحسابات الكاشير دائمًا. فعّل الأدوار الأخرى التي يُسمح لها بفتح وردية والبيع في هذا الفرع.</p>
              <div className="actions">
                {roles.map((r) => (
                  <label className="check" key={r.code}>
                    <input type="checkbox" disabled={r.code === 'cashier'} checked={r.code === 'cashier' || s.shift_roles.includes(r.code)}
                      onChange={(e) => patch(b.id, { shift_roles: e.target.checked ? [...s.shift_roles, r.code] : s.shift_roles.filter((x) => x !== r.code) })} />
                    {r.name_ar}
                  </label>))}
              </div>
            </fieldset>
            <fieldset>
              <legend>الضريبة</legend>
              <div className="form-grid">
                <label className="check"><input type="checkbox" checked={s.tax_enabled} onChange={(e) => patch(b.id, { tax_enabled: e.target.checked })} /> ضريبة القيمة المضافة مفعّلة</label>
                <label>النسبة %<input dir="ltr" inputMode="decimal" value={s.tax_rate_bp / 100}
                  onChange={(e) => patch(b.id, { tax_rate_bp: Math.round(Number(e.target.value || 0) * 100) })} /></label>
                <label className="check"><input type="checkbox" checked={s.prices_include_tax} onChange={(e) => patch(b.id, { prices_include_tax: e.target.checked })} /> الأسعار شاملة الضريبة</label>
              </div>
            </fieldset>
            <fieldset>
              <legend>نص الفاتورة</legend>
              <div className="form-grid">
                <label className="span-2">العنوان أعلى الفاتورة<input value={s.receipt_header_ar ?? ''} onChange={(e) => patch(b.id, { receipt_header_ar: e.target.value })} /></label>
                <label className="span-2">التذييل<input value={s.receipt_footer_ar ?? ''} onChange={(e) => patch(b.id, { receipt_footer_ar: e.target.value })} /></label>
              </div>
            </fieldset>
            <div className="actions"><button className="btn primary" disabled={busy === b.id} onClick={() => void save(b.id)}>{busy === b.id ? 'جارٍ الحفظ…' : 'حفظ إعدادات الفرع'}</button></div>
          </div>);
      })}
      <p className="muted small">نوع الطابعة (حرارية أو A4) يُضبط على كل جهاز كاشير من F12. إدارة المستخدمين وبيانات المنشأة والنسخ الاحتياطي لم تُبنَ بعد.</p>
    </>
  );
}
