import { useCallback, useEffect, useState } from 'react';
import { rpc } from '../../lib/supabase';
import { formatDateTime, formatOmr, muscatToday } from '../../lib/money';
import type { CashSessionRow, Ctx } from '../../lib/types';

/** الورديات والإقفالات: النقد المتوقع والفعلي وفرق الصندوق، وإجمالي البطاقة منفصلًا. */
export function Sessions({ ctx }: { ctx: Ctx }) {
  const branches = ctx.branches.filter((b) => b.permissions.includes('reports.view'));
  const [branchId, setBranchId] = useState('');
  const [from, setFrom] = useState(muscatToday());
  const [to, setTo] = useState(muscatToday());
  const [rows, setRows] = useState<CashSessionRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(() => {
    rpc<CashSessionRow[]>('list_cash_sessions', { p_branch_id: branchId || null, p_from: from, p_to: to })
      .then((d) => { setRows(d); setError(null); })
      .catch((e: Error) => setError(e.message));
  }, [branchId, from, to]);
  useEffect(() => {
    load();
    const t = window.setInterval(load, 15000);
    return () => window.clearInterval(t);
  }, [load]);

  const closed = rows?.filter((r) => r.status === 'closed') ?? [];
  const netDiff = closed.reduce((s, r) => s + (r.difference_baisa ?? 0), 0);

  return (
    <>
      <header className="page-head">
        <h1>الورديات والإقفالات</h1>
        <div className="filters">
          <select value={branchId} onChange={(e) => setBranchId(e.target.value)} aria-label="الفرع">
            {branches.length > 1 && <option value="">كل الفروع</option>}
            {branches.map((b) => <option key={b.id} value={b.id}>{b.name_ar}</option>)}
          </select>
          <label>من <input type="date" value={from} max={to} onChange={(e) => setFrom(e.target.value)} /></label>
          <label>إلى <input type="date" value={to} min={from} onChange={(e) => setTo(e.target.value)} /></label>
        </div>
      </header>
      {error && <div className="notice error">تعذّر تحميل الورديات ({error}).</div>}
      <div className="card table-wrap">
        <table>
          <thead><tr>
            <th>الصندوق / الموظف</th><th>الفتح ← الإقفال</th><th className="num">الفواتير</th>
            <th className="num">الافتتاحي</th><th className="num">نقد المبيعات</th><th className="num">المتوقع</th>
            <th className="num">الفعلي</th><th className="num">الفرق</th><th className="num">البطاقة</th><th>الحالة</th>
          </tr></thead>
          <tbody>
            {rows?.map((r) => (
              <tr key={r.session_id} className="static" title={r.close_note ?? undefined}>
                <td>{r.branch_code} · {r.device_name}<div className="note">{r.opened_by_name}</div></td>
                <td>{formatDateTime(r.opened_at)}<div className="note">{r.closed_at ? formatDateTime(r.closed_at) : 'لم تُقفل بعد'}</div></td>
                <td className="num">{r.invoice_count}</td>
                <td className="num">{formatOmr(r.opening_cash_baisa)}</td>
                <td className="num">{formatOmr(r.cash_sales_baisa)}</td>
                <td className="num">{formatOmr(r.expected_cash_baisa)}</td>
                <td className="num">{r.status === 'closed' ? formatOmr(r.counted_cash_baisa) : '—'}</td>
                <td className={`num strong ${r.difference_baisa ? 'neg' : ''}`}>
                  <bdi dir="ltr">{r.status === 'closed' ? formatOmr(r.difference_baisa) : '—'}</bdi>
                  {r.close_note && <div className="note">{r.close_note}</div>}
                </td>
                <td className="num">{formatOmr(r.card_baisa)}</td>
                <td><span className={`badge ${r.status === 'open' ? 'open' : 'approved'}`}>{r.status === 'open' ? 'مفتوحة' : 'مقفلة'}</span></td>
              </tr>
            ))}
            {rows?.length === 0 && <tr><td colSpan={10} className="empty">لا توجد ورديات في هذه الفترة.</td></tr>}
            {!rows && !error && <tr><td colSpan={10} className="empty">جارٍ التحميل…</td></tr>}
          </tbody>
          {closed.length > 0 && (
            <tfoot><tr><td colSpan={7}>{closed.length} وردية مقفلة — صافي فروقات الصندوق</td>
              <td className={`num strong ${netDiff ? 'neg' : ''}`}><bdi dir="ltr">{formatOmr(netDiff)}</bdi></td><td colSpan={2} /></tr></tfoot>
          )}
        </table>
      </div>
      <p className="muted small">الفترة حسب اليوم المحاسبي. الفرق = الفعلي − المتوقع (السالب عجز). مدفوعات البطاقة لا تدخل في عدّ الدرج.</p>
    </>
  );
}
