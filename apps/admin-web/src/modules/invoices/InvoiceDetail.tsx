import { useEffect, useState } from 'react';
import { rpc, supabase } from '../../lib/supabase';
import { formatDateTime, formatOmr } from '../../lib/money';
import { can, type Ctx, type Invoice } from '../../lib/types';
import { RefundPanel } from './RefundPanel';

interface JournalLine { account: string; debit_baisa: number; credit_baisa: number }
interface AuditRow { id: number; action: string; created_at: string; user_id: string | null }

const ACTIONS: Record<string, string> = { 'invoice.approve': 'اعتماد الفاتورة', 'invoice.reprint': 'إعادة طباعة', 'invoice.refund': 'مرتجع', 'invoice.void': 'إلغاء الفاتورة' };

export function InvoiceDetail({ ctx, id }: { ctx: Ctx; id: string }) {
  const [inv, setInv] = useState<Invoice | null>(null);
  const [journal, setJournal] = useState<JournalLine[] | null>(null);
  const [audit, setAudit] = useState<AuditRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [version, setVersion] = useState(0);

  useEffect(() => {
    let alive = true;
    setJournal(null); setAudit(null); setError(null);
    rpc<Invoice>('get_invoice', { p_invoice_id: id }).then(async (i) => {
      if (!alive) return;
      setInv(i);
      if (can(ctx, 'accounting.view', i.branch_id)) {
        const { data: entries } = await supabase.from('journal_entries').select('id').eq('source_type', 'invoice').eq('source_id', id);
        const ids = (entries ?? []).map((e) => e.id as string);
        if (ids.length) {
          const [{ data: lines }, { data: accounts }] = await Promise.all([
            supabase.from('journal_lines').select('account_id, debit_baisa, credit_baisa').in('entry_id', ids).order('id'),
            supabase.from('accounts').select('id, code, name_ar'),
          ]);
          const names = new Map((accounts ?? []).map((a) => [a.id as string, `${a.code} — ${a.name_ar}`]));
          if (alive) setJournal((lines ?? []).map((l) => ({
            account: names.get(l.account_id as string) ?? '—', debit_baisa: Number(l.debit_baisa), credit_baisa: Number(l.credit_baisa) })));
        }
      }
      if (can(ctx, 'audit.view', i.branch_id)) {
        const { data } = await supabase.from('audit_log').select('id, action, created_at, user_id')
          .eq('entity_type', 'invoice').eq('entity_id', id).order('created_at');
        if (alive) setAudit((data ?? []) as AuditRow[]);
      }
    }).catch((e: Error) => alive && setError(e.message === 'NOT_FOUND' ? 'الفاتورة غير موجودة أو لا تملك صلاحية عرضها.' : `تعذّر تحميل الفاتورة (${e.message}).`));
    return () => { alive = false; };
  }, [id, ctx, version]);

  if (error) return <div className="notice error">{error} <a href="#/invoices">العودة للقائمة</a></div>;
  if (!inv) return <div className="muted">جارٍ التحميل…</div>;

  return (
    <>
      <header className="page-head">
        <h1><a href="#/invoices" className="back">الفواتير</a> / <span dir="ltr" className="mono">{inv.invoice_no}</span>
          <span className={`badge ${inv.status}`}>{inv.status === 'approved' ? 'معتمدة' : 'ملغاة'}</span></h1>
      </header>
      <div className="grid2">
        <div className="card">
          <dl className="meta">
            <dt>الفرع</dt><dd>{inv.branch.name_ar}</dd>
            <dt>وقت الاعتماد</dt><dd>{formatDateTime(inv.approved_at)}</dd>
            <dt>اليوم المحاسبي</dt><dd dir="ltr">{inv.business_date}</dd>
            <dt>الكاشير</dt><dd>{inv.cashier_name}</dd>
            <dt>العميل</dt><dd>{inv.customer ? `${inv.customer.name}${inv.customer.phone ? ` — ${inv.customer.phone}` : ''}` : '—'}</dd>
            <dt>المركبة</dt><dd>{inv.vehicle ? [inv.vehicle.plate, inv.vehicle.make, inv.vehicle.model].filter(Boolean).join(' · ') : '—'}</dd>
            <dt>مرات الطباعة</dt><dd>{inv.print_count}</dd>
          </dl>
        </div>
        <div className="card">
          <dl className="meta totals">
            <dt>إجمالي البنود</dt><dd>{formatOmr(inv.subtotal_baisa)}</dd>
            <dt>الخصم</dt><dd>{formatOmr(inv.discount_baisa)}</dd>
            <dt>الصافي قبل الضريبة</dt><dd>{formatOmr(inv.net_baisa)}</dd>
            <dt>الضريبة {inv.tax_rate_bp / 100}%{inv.prices_include_tax ? ' (ضمن السعر)' : ''}</dt><dd>{formatOmr(inv.tax_baisa)}</dd>
            <dt className="strong">الإجمالي</dt><dd className="strong">{formatOmr(inv.total_baisa)}</dd>
            {inv.payments.map((p, i) => (
              <div key={i} className="pair">
                <dt>{p.method === 'cash' ? 'نقدي' : `بطاقة${p.card_reference ? ` (${p.card_reference})` : ''}`}</dt><dd>{formatOmr(p.amount_baisa)}</dd>
              </div>
            ))}
            {inv.change_baisa > 0 && <><dt>الباقي للعميل</dt><dd>{formatOmr(inv.change_baisa)}</dd></>}
          </dl>
        </div>
      </div>
      <div className="card table-wrap">
        <table>
          <thead><tr><th>#</th><th>الرمز</th><th>الوصف</th><th className="num">الكمية</th><th className="num">السعر</th>
            <th className="num">الخصم</th><th className="num">الضريبة</th><th className="num">الإجمالي</th></tr></thead>
          <tbody>
            {inv.lines.map((l) => (
              <tr key={l.line_no} className="static">
                <td>{l.line_no}</td><td dir="ltr" className="mono">{l.sku}</td><td>{l.description_ar}</td>
                <td className="num">{l.qty} {l.unit}</td><td className="num">{formatOmr(l.unit_price_baisa)}</td>
                <td className="num">{l.discount_baisa ? formatOmr(l.discount_baisa) : '—'}</td>
                <td className="num">{formatOmr(l.tax_baisa)}</td><td className="num strong">{formatOmr(l.total_baisa)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {journal && (
        <div className="card table-wrap">
          <h2>القيد المحاسبي</h2>
          <table>
            <thead><tr><th>الحساب</th><th className="num">مدين</th><th className="num">دائن</th></tr></thead>
            <tbody>{journal.map((j, i) => (
              <tr key={i} className="static"><td>{j.account}</td>
                <td className="num">{j.debit_baisa ? formatOmr(j.debit_baisa) : ''}</td>
                <td className="num">{j.credit_baisa ? formatOmr(j.credit_baisa) : ''}</td></tr>))}
            </tbody>
            <tfoot><tr><td>المجموع</td>
              <td className="num strong">{formatOmr(journal.reduce((s, j) => s + j.debit_baisa, 0))}</td>
              <td className="num strong">{formatOmr(journal.reduce((s, j) => s + j.credit_baisa, 0))}</td></tr></tfoot>
          </table>
        </div>
      )}
      {audit && audit.length > 0 && (
        <div className="card">
          <h2>سجل التدقيق</h2>
          <ul className="audit">{audit.map((a) => <li key={a.id}><span>{ACTIONS[a.action] ?? a.action}</span><span className="muted">{formatDateTime(a.created_at)}</span></li>)}</ul>
        </div>
      )}
      <RefundPanel invoiceId={inv.id} canRefund={can(ctx, 'invoice.refund', inv.branch_id)} canVoid={can(ctx, 'invoice.void', inv.branch_id)}
        onDone={() => setVersion((v) => v + 1)} />
    </>
  );
}
