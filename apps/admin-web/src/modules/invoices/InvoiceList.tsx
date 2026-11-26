import { useCallback, useEffect, useRef, useState } from 'react';
import { rpc, supabase } from '../../lib/supabase';
import { formatDateTime, formatOmr, muscatToday } from '../../lib/money';
import type { Ctx, InvoiceRow } from '../../lib/types';

export function InvoiceList({ ctx }: { ctx: Ctx }) {
  const branches = ctx.branches.filter((b) => b.permissions.includes('invoice.view'));
  const [branchId, setBranchId] = useState('');
  const [from, setFrom] = useState(muscatToday());
  const [to, setTo] = useState(muscatToday());
  const [search, setSearch] = useState('');
  const [rows, setRows] = useState<InvoiceRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [live, setLive] = useState(false);
  const [fresh, setFresh] = useState<Set<string>>(new Set());
  const known = useRef<Set<string> | null>(null);

  const load = useCallback(() => {
    rpc<InvoiceRow[]>('list_invoices', { p_branch_id: branchId || null, p_from: from, p_to: to, p_search: search || null, p_limit: 200 })
      .then((d) => {
        if (known.current) {
          const added = d.filter((r) => !known.current!.has(r.id)).map((r) => r.id);
          if (added.length) {
            setFresh((f) => new Set([...f, ...added]));
            window.setTimeout(() => setFresh((f) => { const n = new Set(f); added.forEach((a) => n.delete(a)); return n; }), 6000);
          }
        }
        known.current = new Set(d.map((r) => r.id));
        setRows(d); setError(null);
      })
      .catch((e: Error) => setError(e.message));
  }, [branchId, from, to, search]);

  useEffect(() => { known.current = null; const t = window.setTimeout(load, 200); return () => window.clearTimeout(t); }, [load]);

  // ظهور فوري عبر Realtime، مع تحديث دوري احتياطي إذا انقطعت القناة
  const loadRef = useRef(load);
  loadRef.current = load;
  useEffect(() => {
    const ch = supabase.channel('invoices-feed')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'invoices' }, () => loadRef.current())
      .subscribe((status) => setLive(status === 'SUBSCRIBED'));
    const t = window.setInterval(() => loadRef.current(), 10000);
    return () => { window.clearInterval(t); void supabase.removeChannel(ch); };
  }, []);

  const total = rows?.reduce((s, r) => s + (r.status === 'approved' ? r.total_baisa : 0), 0) ?? 0;

  return (
    <>
      <header className="page-head">
        <h1>الفواتير <span className={`live ${live ? 'on' : ''}`}>{live ? 'تحديث فوري' : 'تحديث كل 10 ثوانٍ'}</span></h1>
        <div className="filters">
          <input type="search" placeholder="رقم الفاتورة، الهاتف، أو اللوحة" value={search} onChange={(e) => setSearch(e.target.value)} />
          <select value={branchId} onChange={(e) => setBranchId(e.target.value)} aria-label="الفرع">
            {branches.length > 1 && <option value="">كل الفروع</option>}
            {branches.map((b) => <option key={b.id} value={b.id}>{b.name_ar}</option>)}
          </select>
          <label>من <input type="date" value={from} max={to} onChange={(e) => setFrom(e.target.value)} /></label>
          <label>إلى <input type="date" value={to} min={from} onChange={(e) => setTo(e.target.value)} /></label>
        </div>
      </header>
      {error && <div className="notice error">تعذّر تحميل الفواتير ({error}).</div>}
      <div className="card table-wrap">
        <table>
          <thead><tr>
            <th>رقم الفاتورة</th><th>الوقت</th><th>الفرع</th><th>الكاشير</th><th>العميل / اللوحة</th>
            <th className="num">نقدي</th><th className="num">بطاقة</th><th className="num">الإجمالي</th><th>الحالة</th>
          </tr></thead>
          <tbody>
            {rows?.map((r) => (
              <tr key={r.id} className={fresh.has(r.id) ? 'fresh' : ''} onClick={() => { window.location.hash = `#/invoices/${r.id}`; }}>
                <td dir="ltr" className="mono">{r.invoice_no}</td>
                <td>{formatDateTime(r.approved_at)}</td>
                <td>{r.branch_code}</td>
                <td>{r.cashier_name}</td>
                <td className="wrap">{[r.customer_name, r.plate].filter(Boolean).join(' · ') || '—'}</td>
                <td className="num">{r.cash_baisa ? formatOmr(r.cash_baisa) : '—'}</td>
                <td className="num">{r.card_baisa ? formatOmr(r.card_baisa) : '—'}</td>
                <td className="num strong">{formatOmr(r.total_baisa)}</td>
                <td><span className={`badge ${r.status}`}>{r.status === 'approved' ? 'معتمدة' : 'ملغاة'}</span></td>
              </tr>
            ))}
            {rows?.length === 0 && <tr><td colSpan={9} className="empty">لا توجد فواتير في هذه الفترة.</td></tr>}
            {!rows && !error && <tr><td colSpan={9} className="empty">جارٍ التحميل…</td></tr>}
          </tbody>
          {rows && rows.length > 0 && (
            <tfoot><tr><td colSpan={7}>{rows.length} فاتورة</td><td className="num strong">{formatOmr(total)}</td><td /></tr></tfoot>
          )}
        </table>
      </div>
    </>
  );
}
