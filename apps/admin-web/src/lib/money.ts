// المبالغ أعداد صحيحة بالبيسة. 1 ر.ع = 1000 بيسة. لا تُستخدم الكسور العشرية في الحساب.

export function formatOmr(baisa: number | null | undefined): string {
  if (baisa === null || baisa === undefined) return '—';
  const sign = baisa < 0 ? '-' : '';
  const abs = Math.abs(Math.trunc(baisa));
  const rials = Math.floor(abs / 1000).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  return `${sign}${rials}.${(abs % 1000).toString().padStart(3, '0')}`;
}

/** تاريخ اليوم بتوقيت مسقط بصيغة YYYY-MM-DD. */
export function muscatToday(now: Date = new Date()): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Muscat', year: 'numeric', month: '2-digit', day: '2-digit' }).format(now);
}

export function formatDateTime(iso: string): string {
  return new Intl.DateTimeFormat('ar-OM-u-nu-latn', {
    timeZone: 'Asia/Muscat', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit',
  }).format(new Date(iso));
}
