import { useCallback, useEffect, useState, type FormEvent } from 'react';
import { rpc, supabase } from '../../lib/supabase';
import { errorText, formatOmr, parseOmr } from '../../lib/money';
import { can, type Ctx } from '../../lib/types';

interface Product {
  id: string; sku: string; kind: 'item' | 'service'; category: string; name_ar: string; name_en: string | null; brand: string | null; unit: string;
  taxable: boolean; track_stock: boolean; base_price_baisa: number; tire_width: number | null; tire_aspect: number | null; tire_rim: number | null; is_active: boolean;
}
const CATS: Record<string, string> = { tire: 'إطارات', tint: 'عازل', accessory: 'إكسسوارات', service: 'خدمات', general: 'عام' };
const blank = { id: '', sku: '', kind: 'item', category: 'tire', name_ar: '', name_en: '', brand: '', unit: 'حبة', price: '', taxable: true, is_active: true, w: '', a: '', r: '', barcodes: '' };

/** الكتالوج: الأصناف والخدمات والباركود وأسعار المنشأة والفروع. */
export function Catalog({ ctx }: { ctx: Ctx }) {
  const org = ctx.branches[0].organization_id;
  const canEdit = can(ctx, 'catalog.manage');
  const [rows, setRows] = useState<Product[] | null>(null);
  const [barcodes, setBarcodes] = useState<Record<string, string[]>>({});
  const [q, setQ] = useState('');
  const [form, setForm] = useState<typeof blank | null>(null);
  const [branchPrices, setBranchPrices] = useState<Record<string, string>>({});
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    const [{ data: p, error }, { data: b }] = await Promise.all([
      supabase.from('products').select('*').order('category').order('name_ar'),
      supabase.from('product_barcodes').select('barcode, product_id'),
    ]);
    if (error) { setMsg({ ok: false, text: 'تعذّر تحميل الكتالوج.' }); return; }
    setRows((p ?? []).map((x) => ({ ...x, base_price_baisa: Number(x.base_price_baisa) })) as Product[]);
    const map: Record<string, string[]> = {};
    (b ?? []).forEach((x) => { (map[x.product_id as string] ??= []).push(x.barcode as string); });
    setBarcodes(map);
  }, []);
  useEffect(() => { void load(); }, [load]);

  const edit = async (p: Product) => {
    setMsg(null);
    setForm({ id: p.id, sku: p.sku, kind: p.kind, category: p.category, name_ar: p.name_ar, name_en: p.name_en ?? '', brand: p.brand ?? '', unit: p.unit,
      price: formatOmr(p.base_price_baisa), taxable: p.taxable, is_active: p.is_active, w: String(p.tire_width ?? ''), a: String(p.tire_aspect ?? ''),
      r: String(p.tire_rim ?? ''), barcodes: (barcodes[p.id] ?? []).join(', ') });
    const { data } = await supabase.from('branch_prices').select('branch_id, price_baisa').eq('product_id', p.id);
    setBranchPrices(Object.fromEntries((data ?? []).map((x) => [x.branch_id as string, formatOmr(Number(x.price_baisa))])));
  };

  const save = async (e: FormEvent) => {
    e.preventDefault();
    if (!form) return;
    const price = parseOmr(form.price);
    if (price === null) { setMsg({ ok: false, text: 'السعر غير صالح. مثال: 28 أو 28.500' }); return; }
    setBusy(true); setMsg(null);
    try {
      const saved = await rpc<Product>('save_product', { p_product: {
        id: form.id || null, organization_id: org, sku: form.sku, kind: form.kind, category: form.kind === 'service' && form.category === 'tire' ? 'service' : form.category,
        name_ar: form.name_ar, name_en: form.name_en, brand: form.brand, unit: form.unit, base_price_baisa: price, taxable: form.taxable, is_active: form.is_active,
        tire_width: form.category === 'tire' && form.w ? Number(form.w) : null, tire_aspect: form.category === 'tire' && form.a ? Number(form.a) : null,
        tire_rim: form.category === 'tire' && form.r ? Number(form.r) : null, barcodes: form.barcodes.split(/[,\s]+/).filter(Boolean) } });
      for (const b of ctx.branches) {
        const text = (branchPrices[b.id] ?? '').trim();
        const v = text === '' ? null : parseOmr(text);
        if (text !== '' && v === null) throw new Error('INVALID_AMOUNT');
        if (form.id || v !== null) await rpc('set_branch_price', { p_branch_id: b.id, p_product_id: saved.id, p_price_baisa: v });
      }
      setMsg({ ok: true, text: `حُفظ الصنف «${saved.name_ar}». السعر الجديد يُطبَّق على أي فاتورة تُعتمد بعد الآن.` });
      setForm(null); await load();
    } catch (err) { setMsg({ ok: false, text: errorText((err as Error).message) }); }
    setBusy(false);
  };

  const shown = rows?.filter((p) => !q || [p.sku, p.name_ar, p.name_en, p.brand, ...(barcodes[p.id] ?? [])].some((x) => x?.toLowerCase().includes(q.toLowerCase())));
  const set = (k: keyof typeof blank, v: string | boolean) => setForm((f) => (f ? { ...f, [k]: v } : f));

  return (
    <>
      <header className="page-head">
        <h1>الكتالوج</h1>
        <div className="filters">
          <input type="search" placeholder="بحث بالاسم أو الرمز أو الباركود" value={q} onChange={(e) => setQ(e.target.value)} />
          {canEdit && <button className="btn primary" onClick={() => { setForm({ ...blank }); setBranchPrices({}); setMsg(null); }}>صنف جديد</button>}
        </div>
      </header>
      {msg && <div className={`notice ${msg.ok ? 'ok' : 'error'}`}>{msg.text}</div>}
      {form && (
        <form className="card form-grid" onSubmit={save}>
          <h2 className="span-all">{form.id ? 'تعديل صنف' : 'صنف جديد'}</h2>
          <label>الرمز (SKU)<input required dir="ltr" value={form.sku} onChange={(e) => set('sku', e.target.value)} /></label>
          <label>الاسم بالعربية<input required value={form.name_ar} onChange={(e) => set('name_ar', e.target.value)} /></label>
          <label>الاسم بالإنجليزية<input dir="ltr" value={form.name_en} onChange={(e) => set('name_en', e.target.value)} /></label>
          <label>النوع<select value={form.kind} onChange={(e) => set('kind', e.target.value)}><option value="item">صنف مخزني</option><option value="service">خدمة / باقة</option></select></label>
          <label>الفئة<select value={form.category} onChange={(e) => set('category', e.target.value)}>{Object.entries(CATS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select></label>
          <label>الماركة<input value={form.brand} onChange={(e) => set('brand', e.target.value)} /></label>
          <label>الوحدة<input value={form.unit} onChange={(e) => set('unit', e.target.value)} /></label>
          <label>سعر المنشأة (ر.ع)<input required dir="ltr" value={form.price} onChange={(e) => set('price', e.target.value)} /></label>
          {form.category === 'tire' && form.kind === 'item' && (
            <label>المقاس (عرض / نسبة / جنط)
              <span className="inline3" dir="ltr">
                <input placeholder="205" value={form.w} onChange={(e) => set('w', e.target.value.replace(/\D/g, ''))} />
                <input placeholder="55" value={form.a} onChange={(e) => set('a', e.target.value.replace(/\D/g, ''))} />
                <input placeholder="16" value={form.r} onChange={(e) => set('r', e.target.value.replace(/\D/g, ''))} />
              </span>
            </label>)}
          <label className="span-2">الباركود (افصل بفاصلة)<input dir="ltr" value={form.barcodes} onChange={(e) => set('barcodes', e.target.value)} /></label>
          {ctx.branches.map((b) => (
            <label key={b.id}>سعر فرع {b.code} (فارغ = سعر المنشأة)
              <input dir="ltr" value={branchPrices[b.id] ?? ''} onChange={(e) => setBranchPrices((m) => ({ ...m, [b.id]: e.target.value }))} /></label>))}
          <label className="check"><input type="checkbox" checked={form.taxable} onChange={(e) => set('taxable', e.target.checked)} /> خاضع للضريبة</label>
          <label className="check"><input type="checkbox" checked={form.is_active} onChange={(e) => set('is_active', e.target.checked)} /> مفعّل للبيع</label>
          <div className="span-all actions">
            <button className="btn primary" disabled={busy}>{busy ? 'جارٍ الحفظ…' : 'حفظ'}</button>
            <button type="button" className="btn" onClick={() => setForm(null)}>إلغاء</button>
          </div>
        </form>
      )}
      <div className="card table-wrap">
        <table>
          <thead><tr><th>الرمز</th><th>الاسم</th><th>الفئة</th><th>الباركود</th><th className="num">السعر</th><th>الحالة</th></tr></thead>
          <tbody>
            {shown?.map((p) => (
              <tr key={p.id} className={canEdit ? '' : 'static'} onClick={() => canEdit && void edit(p)}>
                <td dir="ltr" className="mono">{p.sku}</td><td className="wrap">{p.name_ar}</td><td>{CATS[p.category] ?? p.category}</td>
                <td dir="ltr" className="mono">{(barcodes[p.id] ?? []).join(' ') || '—'}</td>
                <td className="num strong">{formatOmr(p.base_price_baisa)}</td>
                <td><span className={`badge ${p.is_active ? 'approved' : 'voided'}`}>{p.is_active ? 'مفعّل' : 'موقوف'}</span></td>
              </tr>))}
            {shown?.length === 0 && <tr><td colSpan={6} className="empty">لا توجد أصناف مطابقة.</td></tr>}
            {!rows && <tr><td colSpan={6} className="empty">جارٍ التحميل…</td></tr>}
          </tbody>
        </table>
      </div>
    </>
  );
}
