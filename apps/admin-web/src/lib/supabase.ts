import { createClient } from '@supabase/supabase-js';

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const key = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY as string | undefined;

export const configError = !url || !key ? 'لم تُضبط قيم Supabase. انسخ ‎.env.example‎ إلى ‎.env.local‎ وأدخل الرابط والمفتاح العلني.' : null;

export const supabase = createClient(url ?? 'http://localhost', key ?? 'missing');

/** يستدعي دالة RPC ويرمي كود خطأ النظام كما يعيده الخادم. */
export async function rpc<T>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw new Error(error.message);
  return data as T;
}
