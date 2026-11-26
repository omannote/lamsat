/// المبالغ أعداد صحيحة بالبيسة (1 ر.ع = 1000 بيسة). لا يُستخدم double في الحساب.
String formatOmr(int baisa) {
  final sign = baisa < 0 ? '-' : '';
  final abs = baisa.abs();
  return '$sign${abs ~/ 1000}.${(abs % 1000).toString().padLeft(3, '0')}';
}

/// يحوّل نصًا مثل "12" أو "12.5" أو "12.500" إلى بيسة. يعيد null إذا كان النص غير صالح.
int? parseOmr(String input) {
  final s = _latinDigits(input.trim());
  final m = RegExp(r'^(\d{1,9})(?:[.,](\d{1,3}))?$').firstMatch(s);
  if (m == null) return null;
  return int.parse(m.group(1)!) * 1000 + int.parse((m.group(2) ?? '').padRight(3, '0'));
}

/// يحوّل كمية مثل "4" أو "1.5" إلى جزء من الألف. يعيد null إذا كان النص غير صالح أو صفرًا.
int? parseQtyMilli(String input) {
  final v = parseOmr(input);
  return (v == null || v <= 0) ? null : v;
}

String formatQty(int milli) =>
    milli % 1000 == 0 ? '${milli ~/ 1000}' : (milli / 1000).toStringAsFixed(3).replaceFirst(RegExp(r'0+$'), '');

/// قسمة بتقريب النصف إلى أعلى للأعداد غير السالبة — مطابقة لقاعدة الخادم (round في PostgreSQL).
int roundDiv(int numerator, int denominator) => (numerator * 2 + denominator) ~/ (denominator * 2);

String _latinDigits(String s) {
  const ar = '٠١٢٣٤٥٦٧٨٩';
  final b = StringBuffer();
  for (final r in s.runes) {
    final ch = String.fromCharCode(r);
    final i = ar.indexOf(ch);
    b.write(i >= 0 ? '$i' : (ch == '٫' ? '.' : ch));
  }
  return b.toString();
}
