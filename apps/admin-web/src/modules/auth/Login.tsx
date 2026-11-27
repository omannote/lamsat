import { useState, type FormEvent } from 'react';
import { supabase } from '../../lib/supabase';
import logo from '/lamsat-logo.png';

const LOGIN_DOMAIN = (import.meta.env.VITE_LOGIN_DOMAIN as string | undefined) || 'lamsat.test';
/** اسم المستخدم ← معرّف الدخول. يُقبل البريد الكامل أيضًا. */
export const loginId = (username: string) => {
  const u = username.trim().toLowerCase();
  return u.includes('@') ? u : `${u}@${LOGIN_DOMAIN}`;
};

export function Login() {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    if (password.length < 8) { setError('الرقم السري ثماني خانات على الأقل.'); return; }
    setBusy(true); setError(null);
    const { error } = await supabase.auth.signInWithPassword({ email: loginId(email), password });
    if (error) setError(error.status === 400 ? 'اسم المستخدم أو الرقم السري غير صحيح.' : 'تعذّر الاتصال بالخادم. تحقق من الإنترنت ثم أعد المحاولة.');
    setBusy(false);
  };

  return (
    <div className="center login-bg">
      <form className="card login" onSubmit={submit}>
        <img src={logo} alt="لمسات" className="login-logo" />
        <h1>لوحة الإدارة</h1>
        <label>اسم المستخدم
          <input type="text" dir="ltr" autoFocus required value={email} onChange={(e) => setEmail(e.target.value)} autoComplete="username" />
        </label>
        <label>الرقم السري (8 خانات على الأقل)
          <input type="password" dir="ltr" required minLength={8} value={password} onChange={(e) => setPassword(e.target.value)} autoComplete="current-password" />
        </label>
        {error && <div className="notice error" role="alert">{error}</div>}
        <button className="btn primary" disabled={busy}>{busy ? 'جارٍ الدخول…' : 'دخول'}</button>
      </form>
    </div>
  );
}
