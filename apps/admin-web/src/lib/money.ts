// المبالغ أعداد صحيحة بالبيسة. 1 ر.ع = 1000 بيسة. لا تُستخدم الكسور العشرية في الحساب.

export function formatOmr(baisa: number | null | undefined): string {
  if (baisa === null || baisa === undefined) return '—';
  const sign = baisa < 0 ? '-' : '';
  const abs = Math.abs(Math.trunc(baisa));
  const rials = Math.floor(abs / 1000).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  return `${sign}${rials}.${(abs % 1000).toString().padStart(3, '0')}`;
}

/** يحوّل "12" أو "12.5" أو "12.500" إلى بيسة؛ null إذا كان النص غير صالح. */
export function parseOmr(input: string): number | null {
  const m = /^(\d{1,9})(?:[.,](\d{1,3}))?$/.exec(input.trim());
  return m ? Number(m[1]) * 1000 + Number((m[2] ?? '').padEnd(3, '0')) : null;
}

/** رسالة عربية لكود خطأ الخادم. */
export function errorText(code: string): string {
  const m: Record<string, string> = {
    FORBIDDEN: 'لا تملك صلاحية هذا الإجراء.', NOT_FOUND: 'السجل غير موجود.', INVALID_REQUEST: 'البيانات ناقصة أو غير صالحة.',
    SKU_EXISTS: 'رمز الصنف مستخدم لصنف آخر.', BARCODE_EXISTS: 'الباركود مستخدم لصنف آخر.', INVALID_QUANTITY: 'كمية غير صالحة.',
    INVALID_AMOUNT: 'مبلغ غير صالح.', REASON_REQUIRED: 'اكتب السبب.', INSUFFICIENT_STOCK: 'الكمية تتجاوز الرصيد المتاح.',
    PRODUCT_NOT_FOUND: 'صنف غير موجود أو لا يُتتبع مخزونه.', EMPTY_CART: 'لم تُحدَّد أي بنود.', SESSION_CLOSED: 'اختر وردية مفتوحة يخرج منها النقد.',
    BUSINESS_DAY_CLOSED: 'لا يوجد يوم محاسبي مفتوح للفرع. افتح وردية أولًا.', REFUND_EXCEEDS_REMAINING: 'الكمية تتجاوز المتبقي القابل للإرجاع.',
    INVOICE_NOT_REFUNDABLE: 'الفاتورة ملغاة.', INVOICE_HAS_REFUNDS: 'للفاتورة مرتجعات سابقة؛ أرجع الباقي بدل الإلغاء.',
  };
  return m[code] ?? `تعذّر تنفيذ الإجراء (${code}).`;
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
