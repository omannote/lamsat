import { useState, type FormEvent } from 'react';
import { supabase } from '../../lib/supabase';
import logo from '/lamsat-logo.png';

export function Login() {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true); setError(null);
    const { error } = await supabase.auth.signInWithPassword({ email: email.trim(), password });
    if (error) setError(error.status === 400 ? 'البريد أو كلمة المرور غير صحيحة.' : 'تعذّر الاتصال بالخادم. تحقق من الإنترنت ثم أعد المحاولة.');
    setBusy(false);
  };

  return (
    <div className="center login-bg">
      <form className="card login" onSubmit={submit}>
        <img src={logo} alt="لمسات" className="login-logo" />
        <h1>لوحة الإدارة</h1>
        <label>البريد الإلكتروني
          <input type="email" dir="ltr" autoFocus required value={email} onChange={(e) => setEmail(e.target.value)} autoComplete="username" />
        </label>
        <label>كلمة المرور
          <input type="password" dir="ltr" required value={password} onChange={(e) => setPassword(e.target.value)} autoComplete="current-password" />
        </label>
        {error && <div className="notice error" role="alert">{error}</div>}
        <button className="btn primary" disabled={busy}>{busy ? 'جارٍ الدخول…' : 'دخول'}</button>
      </form>
    </div>
  );
}
