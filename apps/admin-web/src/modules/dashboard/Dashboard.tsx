import { useCallback, useEffect, useState } from 'react';
import { rpc } from '../../lib/supabase';
import { formatOmr, muscatToday } from '../../lib/money';
import type { Ctx, Summary } from '../../lib/types';

export function Dashboard({ ctx }: { ctx: Ctx }) {
  const branches = ctx.branches.filter((b) => b.permissions.includes('reports.view'));
  const [branchId, setBranchId] = useState<string>('');
  const [from, setFrom] = useState(muscatToday());
  const [to, setTo] = useState(muscatToday());
  const [data, setData] = useState<Summary | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(() => {
    rpc<Summary>('dashboard_summary', { p_branch_id: branchId || null, p_from: from, p_to: to })
      .then((d) => { setData(d); setError(null); })
      .catch((e: Error) => setError(e.message));
  }, [branchId, from, to]);
  useEffect(() => {
    load();
    const t = window.setInterval(load, 15000);
    return () => window.clearInterval(t);
  }, [load]);

  const tiles: [string, string, string?][] = data ? [
    ['صافي المبيعات (قبل الضريبة)', formatOmr(data.net_sales_baisa)],
    ['الإجمالي شاملًا الضريبة', formatOmr(data.total_baisa)],
    ['عدد الفواتير', String(data.invoice_count)],
    ['مدفوعات نقدية', formatOmr(data.cash_baisa)],
    ['مدفوعات بطاقة', formatOmr(data.card_baisa)],
    ['تحويل بنكي', formatOmr(data.transfer_baisa ?? 0)],
    ['مبيعات آجلة', formatOmr(data.credit_baisa ?? 0)],
    ['الضريبة', formatOmr(data.tax_baisa)],
    ['الخصومات', formatOmr(data.discount_baisa)],
    ['المرتجعات', formatOmr(data.refunds_baisa ?? 0)],
    ['الربح الإجمالي', formatOmr(data.gross_profit_baisa), data.gross_profit_baisa === null ? 'يتطلب صلاحية عرض التكلفة' : undefined],
  ] : [];

  return (
    <>
      <header className="page-head">
        <h1>لوحة المؤشرات</h1>
        <div className="filters">
          <select value={branchId} onChange={(e) => setBranchId(e.target.value)} aria-label="الفرع">
            {branches.length > 1 && <option value="">كل الفروع</option>}
            {branches.map((b) => <option key={b.id} value={b.id}>{b.name_ar}</option>)}
          </select>
          <label>من <input type="date" value={from} max={to} onChange={(e) => setFrom(e.target.value)} /></label>
          <label>إلى <input type="date" value={to} min={from} onChange={(e) => setTo(e.target.value)} /></label>
        </div>
      </header>
      {error && <div className="notice error">تعذّر تحميل المؤشرات ({error}).</div>}
      <section className="tiles">
        {tiles.map(([label, value, hint]) => (
          <div className="tile" key={label}>
            <div className="tile-label">{label}</div>
            <div className="tile-value">{value}</div>
            {hint && <div className="muted small">{hint}</div>}
          </div>
        ))}
      </section>
      <p className="muted small">المبالغ بالريال العُماني. الفترة حسب اليوم المحاسبي. صافي المبيعات بعد طرح المرتجعات؛ الفواتير الملغاة مستبعدة.</p>
    </>
  );
}
