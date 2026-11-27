import { useCallback, useEffect, useRef, useState } from 'react';
import { rpc } from '../../lib/supabase';
import { errorText, formatDateTime, formatOmr } from '../../lib/money';

interface State {
  status: string;
  lines: { line_no: number; description_ar: string; unit: string; qty: number; remaining_qty: number; remaining_baisa: number; track_stock: boolean }[];
  refunds: { id: string; refund_no: string; kind: string; method: string; reason: string; amount_baisa: number; created_at: string; created_by_name: string }[];
  open_sessions: { id: string; device_name: string; opened_by_name: string }[];
}

/** المرتجع الجزئي أو الكلي وإلغاء الفاتورة، مع معاينة الأثر قبل التنفيذ وسجل المرتجعات السابقة. */
type Method = 'cash' | 'card' | 'transfer' | 'credit';
const METHOD_LABEL: Record<string, string> = { cash: 'نقدي', card: 'بطاقة', transfer: 'تحويل بنكي', credit: 'رصيد للعميل' };

export function RefundPanel({ invoiceId, canRefund, canVoid, onDone }: { invoiceId: string; canRefund: boolean; canVoid: boolean; onDone: () => void }) {
  const [st, setSt] = useState<State | null>(null);
  const [open, setOpen] = useState(false);
  const [qty, setQty] = useState<Record<number, string>>({});
  const [restock, setRestock] = useState<Record<number, boolean>>({});
  const [method, setMethod] = useState<Method>('cash');
  const [session, setSession] = useState('');
  const [reason, setReason] = useState('');
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [busy, setBusy] = useState(false);
  const opId = useRef(crypto.randomUUID());

  const load = useCallback(() => {
    rpc<State>('invoice_refund_state', { p_invoice_id: invoiceId }).then((s) => { setSt(s); setSession((x) => x || s.open_sessions[0]?.id || ''); }).catch(() => undefined);
  }, [invoiceId]);
  useEffect(load, [load]);
  if (!st) return null;

  const picked = st.lines.map((l) => ({ l, q: Number(qty[l.line_no] ?? 0) })).filter((x) => x.q > 0);
  const invalid = picked.some((x) => x.q > x.l.remaining_qty);
  const estimate = picked.reduce((s, x) => s + Math.round((x.l.remaining_baisa * x.q) / x.l.remaining_qty), 0);
  const remainingTotal = st.lines.reduce((s, l) => s + l.remaining_baisa, 0);
  const backToStock = picked.filter((x) => x.l.track_stock && restock[x.l.line_no]).reduce((s, x) => s + x.q, 0);

  const run = async (kind: 'refund' | 'void') => {
    if (!reason.trim()) { setMsg({ ok: false, text: 'اكتب سبب العملية.' }); return; }
    if (method === 'cash' && !session) { setMsg({ ok: false, text: 'لا توجد وردية مفتوحة في الفرع يخرج منها النقد. اختر «بطاقة» أو افتح وردية.' }); return; }
    if (kind === 'void' && !window.confirm(`إلغاء الفاتورة كاملة ورد ${formatOmr(remainingTotal)} ر.ع وإعادة بضاعتها للمخزون؟`)) return;
    setBusy(true); setMsg(null);
    try {
      const r = await rpc<{ refund_no: string; amount_baisa: number }>('refund_invoice', { p_operation_id: opId.current, p_payload: {
        invoice_id: invoiceId, kind, method, cash_session_id: method === 'cash' ? session : null, reason,
        lines: kind === 'refund' ? picked.map((x) => ({ line_no: x.l.line_no, qty: x.q, restock: !!restock[x.l.line_no] })) : undefined } });
      opId.current = crypto.randomUUID();
      setMsg({ ok: true, text: `${kind === 'void' ? 'أُلغيت الفاتورة' : 'سُجّل المرتجع'} برقم ${r.refund_no} بمبلغ ${formatOmr(r.amount_baisa)} ر.ع.` });
      setQty({}); setReason(''); setOpen(false); load(); onDone();
    } catch (e) { setMsg({ ok: false, text: errorText((e as Error).message) }); }
    setBusy(false);
  };

  const actionable = st.status === 'approved' && remainingTotal > 0 && (canRefund || canVoid);
  return (
    <div className="card">
      <div className="page-head"><h2>المرتجعات والإلغاء</h2>
        {actionable && !open && <button className="btn" onClick={() => { setOpen(true); setMsg(null); }}>مرتجع أو إلغاء</button>}</div>
      {msg && <div className={`notice ${msg.ok ? 'ok' : 'error'}`}>{msg.text}</div>}
      {st.refunds.length > 0 && (
        <ul className="audit">{st.refunds.map((f) => (
          <li key={f.id}><span><span dir="ltr" className="mono">{f.refund_no}</span> — {f.kind === 'void' ? 'إلغاء' : 'مرتجع'} {METHOD_LABEL[f.method] ?? f.method} — {f.reason} — {f.created_by_name}</span>
            <span><strong dir="ltr">{formatOmr(f.amount_baisa)}</strong> <span className="muted">{formatDateTime(f.created_at)}</span></span></li>))}</ul>)}
      {st.refunds.length === 0 && !open && <p className="muted small">لا توجد مرتجعات على هذه الفاتورة.</p>}
      {open && (
        <>
          <table className="lines">
            <thead><tr><th>البند</th><th className="num">المتبقي</th><th className="num">قيمة المتبقي</th><th>كمية المرتجع</th><th>إعادة للمخزون</th></tr></thead>
            <tbody>{st.lines.map((l) => (
              <tr key={l.line_no} className="static">
                <td>{l.description_ar}</td><td className="num">{l.remaining_qty} {l.unit}</td><td className="num">{formatOmr(l.remaining_baisa)}</td>
                <td><input dir="ltr" inputMode="decimal" disabled={l.remaining_qty <= 0} value={qty[l.line_no] ?? ''} onChange={(e) => setQty({ ...qty, [l.line_no]: e.target.value })} /></td>
                <td>{l.track_stock ? <input type="checkbox" checked={!!restock[l.line_no]} onChange={(e) => setRestock({ ...restock, [l.line_no]: e.target.checked })} /> : <span className="muted">خدمة</span>}</td>
              </tr>))}</tbody>
          </table>
          <div className="form-grid">
            <label>طريقة رد المبلغ<select value={method} onChange={(e) => setMethod(e.target.value as Method)}><option value="cash">نقدي من الدرج</option><option value="card">بطاقة (يُرد على جهاز البطاقة)</option><option value="transfer">تحويل بنكي (يُرد بتحويل)</option><option value="credit">رصيد للعميل (يُخصم من حسابه الآجل)</option></select></label>
            {method === 'cash' && <label>الوردية التي يخرج منها النقد<select value={session} onChange={(e) => setSession(e.target.value)}>
              {st.open_sessions.length === 0 && <option value="">لا توجد وردية مفتوحة</option>}
              {st.open_sessions.map((s) => <option key={s.id} value={s.id}>{s.device_name} — {s.opened_by_name}</option>)}</select></label>}
            <label className="span-2">السبب (إلزامي)<input value={reason} onChange={(e) => setReason(e.target.value)} /></label>
          </div>
          <div className="notice">
            <strong>معاينة الأثر:</strong> يُرد للعميل نحو <strong dir="ltr">{formatOmr(estimate)}</strong> ر.ع {method === 'cash' ? 'نقدًا ويُخصم من النقد المتوقع للوردية' : method === 'card' ? 'على البطاقة' : method === 'transfer' ? 'بتحويل بنكي' : 'رصيدًا في حسابه الآجل (الفاتورة يجب أن تكون مرتبطة بعميل)'}،
            ويعود للمخزون {backToStock} وحدة، ويُسجَّل قيد عكسي في اليوم المحاسبي المفتوح مع بقاء الفاتورة الأصلية وإقفالها التاريخي كما هما. المبلغ النهائي يحسبه الخادم.
          </div>
          <div className="actions">
            {canRefund && <button className="btn primary" disabled={busy || picked.length === 0 || invalid} onClick={() => void run('refund')}>تنفيذ المرتجع</button>}
            {canVoid && st.refunds.length === 0 && <button className="btn danger" disabled={busy} onClick={() => void run('void')}>إلغاء الفاتورة كاملة</button>}
            <button className="btn" onClick={() => setOpen(false)}>رجوع</button>
            {invalid && <span className="muted">كمية تتجاوز المتبقي.</span>}
          </div>
        </>)}
    </div>
  );
}
