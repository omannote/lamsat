import { useCallback, useEffect, useState } from 'react';
import type { Session } from '@supabase/supabase-js';
import { configError, rpc, supabase } from './lib/supabase';
import { can, type Ctx } from './lib/types';
import { Login } from './modules/auth/Login';
import { Dashboard } from './modules/dashboard/Dashboard';
import { InvoiceList } from './modules/invoices/InvoiceList';
import { InvoiceDetail } from './modules/invoices/InvoiceDetail';
import { Sessions } from './modules/cash/Sessions';
import { Catalog } from './modules/catalog/Catalog';
import { Inventory } from './modules/inventory/Inventory';
import logo from '/lamsat-logo.png';

const useHash = () => {
  const [hash, setHash] = useState(window.location.hash || '#/dashboard');
  useEffect(() => {
    const on = () => setHash(window.location.hash || '#/dashboard');
    window.addEventListener('hashchange', on);
    return () => window.removeEventListener('hashchange', on);
  }, []);
  return hash;
};

export function App() {
  const [session, setSession] = useState<Session | null | undefined>(undefined);
  const [ctx, setCtx] = useState<Ctx | null>(null);
  const [ctxError, setCtxError] = useState<string | null>(null);
  const hash = useHash();

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => setSession(data.session));
    const { data } = supabase.auth.onAuthStateChange((_e, s) => setSession(s));
    return () => data.subscription.unsubscribe();
  }, []);

  const userId = session?.user.id;
  const loadCtx = useCallback(() => {
    setCtxError(null);
    rpc<Ctx>('my_context').then(setCtx).catch((e: Error) => setCtxError(e.message));
  }, []);
  useEffect(() => { if (userId) loadCtx(); else setCtx(null); }, [userId, loadCtx]);

  if (configError) return <div className="center"><div className="card notice error">{configError}</div></div>;
  if (session === undefined) return <div className="center muted">جارٍ التحميل…</div>;
  if (!session) return <Login />;
  if (ctxError) return (
    <div className="center"><div className="card notice error">
      تعذّر تحميل صلاحياتك ({ctxError}). <button className="btn" onClick={loadCtx}>إعادة المحاولة</button>
    </div></div>);
  if (!ctx) return <div className="center muted">جارٍ تحميل الصلاحيات…</div>;
  if (!ctx.user || ctx.branches.length === 0) return (
    <div className="center"><div className="card notice">
      <p>حسابك غير مرتبط بأي فرع. تواصل مع مالك النظام.</p>
      <button className="btn" onClick={() => supabase.auth.signOut()}>تسجيل الخروج</button>
    </div></div>);

  const [, route, id] = hash.replace(/^#/, '').split('/');
  const nav = [
    { key: 'dashboard', label: 'لوحة المؤشرات', show: can(ctx, 'reports.view') },
    { key: 'invoices', label: 'الفواتير', show: can(ctx, 'invoice.view') },
    { key: 'sessions', label: 'الورديات والإقفالات', show: can(ctx, 'reports.view') },
    { key: 'catalog', label: 'الكتالوج', show: can(ctx, 'catalog.manage') || can(ctx, 'inventory.cost.view') },
    { key: 'inventory', label: 'المخزون والمشتريات', show: can(ctx, 'inventory.cost.view') },
  ].filter((n) => n.show);
  const current = nav.some((n) => n.key === route) ? route : nav[0]?.key;

  return (
    <div className="shell">
      <aside className="side">
        <div className="brand"><img src={logo} alt="لمسات" /></div>
        <nav>
          {nav.map((n) => (
            <a key={n.key} href={`#/${n.key}`} className={current === n.key ? 'active' : ''}>{n.label}</a>
          ))}
        </nav>
        <div className="side-foot">
          <div className="who">{ctx.user.full_name}</div>
          <div className="muted-light">{ctx.branches.map((b) => b.code).join(' · ')}</div>
          <button className="btn ghost" onClick={() => supabase.auth.signOut()}>تسجيل الخروج</button>
        </div>
      </aside>
      <main className="main">
        {current === 'dashboard' && <Dashboard ctx={ctx} />}
        {current === 'invoices' && !id && <InvoiceList ctx={ctx} />}
        {current === 'invoices' && id && <InvoiceDetail ctx={ctx} id={id} />}
        {current === 'sessions' && <Sessions ctx={ctx} />}
        {current === 'catalog' && <Catalog ctx={ctx} />}
        {current === 'inventory' && <Inventory ctx={ctx} />}
        {!current && <div className="card notice">لا توجد صفحات متاحة لصلاحياتك في لوحة الإدارة.</div>}
      </main>
    </div>
  );
}
