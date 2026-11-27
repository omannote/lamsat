import { useCallback, useEffect, useRef, useState, type FormEvent } from 'react';
import { rpc, supabase } from '../../lib/supabase';
import { errorText, formatOmr, parseOmr } from '../../lib/money';
import type { Ctx } from '../../lib/types';

interface StockRow { product_id: string; sku: string; name_ar: string; unit: string; tire_size: string | null; qty: number; value_baisa: number | null; price_baisa: number;
  lots: { lot_code: string | null; dot_code: string | null; qty: number; unit_cost_baisa: number }[] | null }
interface Line { product_id: string; qty: string; cost: string; dot: string }
const newLine = (): Line => ({ product_id: '', qty: '', cost: '', dot: '' });

/** المخزون والمشتريات: أرصدة الفرع، استلام المشتريات، وتسوية الجرد. */
export function Inventory({ ctx }: { ctx: Ctx }) {
  const branches = ctx.branches.filter((b) => b.permissions.includes('inventory.view'));
  const [branchId, setBranchId] = useState(branches[0]?.id ?? '');
  const branch = branches.find((b) => b.id === branchId);
  const canManage = !!branch?.permissions.includes('inventory.manage');
  const [rows, setRows] = useState<StockRow[] | null>(null);
  const [q, setQ] = useState('');
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [busy, setBusy] = useState(false);
  const [mode, setMode] = useState<'none' | 'receive' | 'adjust'>('none');
  const [suppliers, setSuppliers] = useState<{ id: string; name: string }[]>([]);
  const [rc, setRc] = useState({ supplier_id: '', new_supplier: '', reference: '', lines: [newLine()] });
  const [adj, setAdj] = useState({ product_id: '', delta: '', cost: '', reason: '' });
  const opId = useRef(crypto.randomUUID()); // يتجدد بعد كل نجاح؛ إعادة المحاولة بعد انقطاع تستخدم المعرّف نفسه

  const load = useCallback(() => {
    if (!branchId) return;
    rpc<StockRow[]>('stock_report', { p_branch_id: branchId }).then(setRows).catch((e: Error) => setMsg({ ok: false, text: errorText(e.message) }));
  }, [branchId]);
  useEffect(() => { setRows(null); load(); }, [load]);
  useEffect(() => { void supabase.from('suppliers').select('id, name').eq('is_active', true).order('name').then(({ data }) => setSuppliers((data ?? []) as { id: string; name: string }[])); }, []);

  const receive = async (e: FormEvent) => {
    e.preventDefault();
    const lines = [];
    for (const l of rc.lines.filter((x) => x.product_id)) {
      const cost = parseOmr(l.cost); const qty = Number(l.qty);
      if (cost === null || !(qty > 0)) { setMsg({ ok: false, text: 'تحقق من الكمية والتكلفة في كل سطر.' }); return; }
      lines.push({ product_id: l.product_id, qty, unit_cost_baisa: cost, dot_code: l.dot });
    }
    if (!lines.length) { setMsg({ ok: false, text: 'أضف سطرًا واحدًا على الأقل.' }); return; }
    setBusy(true); setMsg(null);
    try {
      let supplierId = rc.supplier_id || null;
      if (!supplierId && rc.new_supplier.trim()) {
        const s = await rpc<{ id: string; name: string }>('save_supplier', { p_supplier: { organization_id: branch!.organization_id, name: rc.new_supplier } });
        supplierId = s.id; setSuppliers((x) => [...x, s]);
      }
      const r = await rpc<{ total_cost_baisa: number; lines: number }>('receive_purchase', { p_operation_id: opId.current,
        p_payload: { branch_id: branchId, supplier_id: supplierId, reference: rc.reference, lines } });
      opId.current = crypto.randomUUID();
      setMsg({ ok: true, text: `استُلمت ${r.lines} أصناف بتكلفة ${formatOmr(r.total_cost_baisa)} ر.ع وأصبحت متاحة للبيع.` });
      setRc({ supplier_id: '', new_supplier: '', reference: '', lines: [newLine()] }); setMode('none'); load();
    } catch (err) { setMsg({ ok: false, text: errorText((err as Error).message) }); }
    setBusy(false);
  };

  const adjust = async (e: FormEvent) => {
    e.preventDefault();
    const delta = Number(adj.delta); const cost = adj.cost.trim() ? parseOmr(adj.cost) : null;
    if (!adj.product_id || !delta || (adj.cost.trim() && cost === null)) { setMsg({ ok: false, text: 'اختر الصنف وأدخل فرق الكمية (موجب للزيادة، سالب للنقص).' }); return; }
    setBusy(true); setMsg(null);
    try {
      const r = await rpc<{ value_baisa: number }>('adjust_stock', { p_operation_id: opId.current, p_branch_id: branchId, p_product_id: adj.product_id,
        p_qty_delta: delta, p_unit_cost_baisa: cost, p_reason: adj.reason });
      opId.current = crypto.randomUUID();
      setMsg({ ok: true, text: `سُجّلت التسوية بقيمة ${formatOmr(r.value_baisa)} ر.ع.` });
      setAdj({ product_id: '', delta: '', cost: '', reason: '' }); setMode('none'); load();
    } catch (err) { setMsg({ ok: false, text: errorText((err as Error).message) }); }
    setBusy(false);
  };

  const shown = rows?.filter((r) => !q || [r.sku, r.name_ar, r.tire_size].some((x) => x?.toLowerCase().includes(q.toLowerCase())));
  const options = rows?.map((r) => <option key={r.product_id} value={r.product_id}>{r.name_ar} — {r.sku}</option>);
  const setLine = (i: number, k: keyof Line, v: string) => setRc((s) => ({ ...s, lines: s.lines.map((l, j) => (j === i ? { ...l, [k]: v } : l)) }));
  const totalValue = rows?.reduce((s, r) => s + (r.value_baisa ?? 0), 0) ?? 0;

  return (
    <>
      <header className="page-head">
        <h1>المخزون والمشتريات</h1>
        <div className="filters">
          <input type="search" placeholder="بحث بالاسم أو الرمز أو المقاس" value={q} onChange={(e) => setQ(e.target.value)} />
          <select value={branchId} onChange={(e) => setBranchId(e.target.value)} aria-label="الفرع">{branches.map((b) => <option key={b.id} value={b.id}>{b.name_ar}</option>)}</select>
          {canManage && <button className="btn primary" onClick={() => { setMode('receive'); setMsg(null); }}>استلام مشتريات</button>}
          {canManage && <button className="btn" onClick={() => { setMode('adjust'); setMsg(null); }}>تسوية جرد</button>}
        </div>
      </header>
      {msg && <div className={`notice ${msg.ok ? 'ok' : 'error'}`}>{msg.text}</div>}
      {mode === 'receive' && (
        <form className="card" onSubmit={receive}>
          <h2>استلام مشتريات — {branch?.name_ar}</h2>
          <div className="form-grid">
            <label>المورد<select value={rc.supplier_id} onChange={(e) => setRc({ ...rc, supplier_id: e.target.value })}><option value="">— مورد جديد أو بلا مورد —</option>
              {suppliers.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></label>
            {!rc.supplier_id && <label>اسم مورد جديد<input value={rc.new_supplier} onChange={(e) => setRc({ ...rc, new_supplier: e.target.value })} /></label>}
            <label>مرجع فاتورة المورد<input dir="ltr" value={rc.reference} onChange={(e) => setRc({ ...rc, reference: e.target.value })} /></label>
          </div>
          <table className="lines">
            <thead><tr><th>الصنف</th><th>الكمية</th><th>تكلفة الوحدة (ر.ع)</th><th>DOT / الدفعة</th><th /></tr></thead>
            <tbody>{rc.lines.map((l, i) => (
              <tr key={i} className="static">
                <td><select value={l.product_id} onChange={(e) => setLine(i, 'product_id', e.target.value)}><option value="">اختر صنفًا</option>{options}</select></td>
                <td><input dir="ltr" inputMode="decimal" value={l.qty} onChange={(e) => setLine(i, 'qty', e.target.value)} /></td>
                <td><input dir="ltr" value={l.cost} onChange={(e) => setLine(i, 'cost', e.target.value)} /></td>
                <td><input dir="ltr" value={l.dot} onChange={(e) => setLine(i, 'dot', e.target.value)} /></td>
                <td>{rc.lines.length > 1 && <button type="button" className="btn" onClick={() => setRc((s) => ({ ...s, lines: s.lines.filter((_, j) => j !== i) }))}>حذف</button>}</td>
              </tr>))}</tbody>
          </table>
          <div className="actions">
            <button type="button" className="btn" onClick={() => setRc((s) => ({ ...s, lines: [...s.lines, newLine()] }))}>سطر إضافي</button>
            <button className="btn primary" disabled={busy}>{busy ? 'جارٍ الاستلام…' : 'تأكيد الاستلام'}</button>
            <button type="button" className="btn" onClick={() => setMode('none')}>إلغاء</button>
          </div>
          <p className="muted small">القيد: مدين المخزون / دائن الموردين. الأصناف الجديدة تُضاف أولًا من صفحة الكتالوج.</p>
        </form>)}
      {mode === 'adjust' && (
        <form className="card form-grid" onSubmit={adjust}>
          <h2 className="span-all">تسوية جرد — {branch?.name_ar}</h2>
          <label className="span-2">الصنف<select required value={adj.product_id} onChange={(e) => setAdj({ ...adj, product_id: e.target.value })}><option value="">اختر صنفًا</option>{options}</select></label>
          <label>فرق الكمية (+ زيادة / − نقص)<input required dir="ltr" value={adj.delta} onChange={(e) => setAdj({ ...adj, delta: e.target.value })} /></label>
          <label>تكلفة الوحدة للزيادة (اختياري)<input dir="ltr" value={adj.cost} onChange={(e) => setAdj({ ...adj, cost: e.target.value })} /></label>
          <label className="span-2">السبب (إلزامي)<input required value={adj.reason} onChange={(e) => setAdj({ ...adj, reason: e.target.value })} /></label>
          <div className="span-all actions"><button className="btn primary" disabled={busy}>تسجيل التسوية</button><button type="button" className="btn" onClick={() => setMode('none')}>إلغاء</button></div>
        </form>)}
      <div className="card table-wrap">
        <table>
          <thead><tr><th>الرمز</th><th>الصنف</th><th>المقاس</th><th className="num">الرصيد</th><th className="num">سعر البيع</th><th className="num">قيمة المخزون</th><th>الدفعات (الكمية × التكلفة)</th></tr></thead>
          <tbody>
            {shown?.map((r) => (
              <tr key={r.product_id} className="static">
                <td dir="ltr" className="mono">{r.sku}</td><td className="wrap">{r.name_ar}</td><td dir="ltr">{r.tire_size ?? '—'}</td>
                <td className={`num strong ${r.qty <= 0 ? 'neg' : ''}`}>{r.qty} {r.unit}</td>
                <td className="num">{formatOmr(r.price_baisa)}</td><td className="num">{formatOmr(r.value_baisa)}</td>
                <td className="wrap small muted" dir="ltr">{r.lots?.map((l) => `${l.qty} × ${formatOmr(l.unit_cost_baisa)}${l.dot_code ? ` (${l.dot_code})` : ''}`).join('  ·  ') || '—'}</td>
              </tr>))}
            {shown?.length === 0 && <tr><td colSpan={7} className="empty">لا توجد أصناف مخزنية مطابقة.</td></tr>}
            {!rows && <tr><td colSpan={7} className="empty">جارٍ التحميل…</td></tr>}
          </tbody>
          {rows && rows.some((r) => r.value_baisa !== null) && <tfoot><tr><td colSpan={5}>إجمالي قيمة المخزون بالتكلفة (FIFO)</td><td className="num strong">{formatOmr(totalValue)}</td><td /></tr></tfoot>}
        </table>
      </div>
    </>
  );
}
