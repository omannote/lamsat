import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api.dart';
import '../../core/money.dart';
import '../../core/theme.dart';
import '../printing/receipt.dart';
import 'cart.dart';

Future<void> showMessage(BuildContext context, String title, String body) => showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: SizedBox(width: 440, child: Text(body, style: const TextStyle(fontSize: 17))),
        actions: [FilledButton(autofocus: true, onPressed: () => Navigator.pop(c), child: const Text('حسنًا (Enter)'))],
      ),
    );

/// رسالة تشغيلية لخطأ اعتماد، مع تفاصيل المخزون إن وُجدت.
String describeError(BusinessError e) {
  if (e.code == 'INSUFFICIENT_STOCK' && (e.detail ?? '').isNotEmpty) {
    try {
      final d = jsonDecode(e.detail!) as Map<String, dynamic>;
      return 'الكمية غير متوفرة: ${d['name_ar']}\nالمطلوب ${d['requested']} والمتاح ${d['available']}. عدّل الكمية ثم أعد الدفع.';
    } catch (_) {}
  }
  return errorMessage(e.code);
}

/// F1 والسلة فيها بنود: إجراء صريح. يعيد true إذا اختار الموظف تجاهل البنود.
Future<bool> confirmDiscardCart(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('فاتورة جديدة'),
        content: const SizedBox(width: 440, child: Text('السلة تحتوي على بنود. حفظها كمسودة يتوفر في المرحلة 2 (F6).', style: TextStyle(fontSize: 17))),
        actions: [
          OutlinedButton(onPressed: () => Navigator.pop(c, true), child: const Text('تجاهل البنود وبدء فاتورة جديدة')),
          FilledButton(autofocus: true, onPressed: () => Navigator.pop(c, false), child: const Text('متابعة الفاتورة الحالية')),
        ],
      ),
    ) ??
    false;

/// F4: تعديل كمية السطر (والخصم إن كان مسموحًا).
class LineEditDialog extends StatefulWidget {
  final CartLine line;
  final int maxDiscountBp;
  const LineEditDialog({super.key, required this.line, required this.maxDiscountBp});
  @override
  State<LineEditDialog> createState() => _LineEditState();
}

class _LineEditState extends State<LineEditDialog> {
  late final _qty = TextEditingController(text: formatQty(widget.line.qtyMilli));
  late final _disc = TextEditingController(text: formatOmr(widget.line.discountBaisa));
  final _discFocus = FocusNode();
  String? _error;

  @override
  void initState() {
    super.initState();
    _qty.selection = TextSelection(baseOffset: 0, extentOffset: _qty.text.length);
  }

  @override
  void dispose() {
    _qty.dispose();
    _disc.dispose();
    _discFocus.dispose();
    super.dispose();
  }

  void _save() {
    final l = widget.line;
    final q = parseQtyMilli(_qty.text);
    if (q == null || (l.product.wholeUnitsOnly && q % 1000 != 0)) {
      setState(() => _error = l.product.wholeUnitsOnly ? 'هذا الصنف يباع بعدد صحيح.' : 'كمية غير صالحة.');
      return;
    }
    final d = widget.maxDiscountBp > 0 ? parseOmr(_disc.text.isEmpty ? '0' : _disc.text) : 0;
    final gross = roundDiv(q * l.unitPriceBaisa, 1000);
    if (d == null || d > gross) {
      setState(() => _error = 'قيمة الخصم غير صالحة.');
      return;
    }
    if (d * 10000 > gross * widget.maxDiscountBp) {
      setState(() => _error = 'الخصم يتجاوز حدّك (${formatQty(widget.maxDiscountBp * 10)}%).');
      return;
    }
    l.qtyMilli = q;
    l.discountBaisa = d;
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.line.product.nameAr),
        content: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: _qty,
              autofocus: true,
              textDirection: TextDirection.ltr,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
              decoration: InputDecoration(labelText: 'الكمية (${widget.line.product.unit})'),
              onSubmitted: (_) => widget.maxDiscountBp > 0 ? _discFocus.requestFocus() : _save(),
            ),
            if (widget.maxDiscountBp > 0) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _disc,
                focusNode: _discFocus,
                textDirection: TextDirection.ltr,
                decoration: InputDecoration(labelText: 'خصم السطر (ر.ع) — الحد ${formatQty(widget.maxDiscountBp * 10)}%'),
                onTap: () => _disc.selection = TextSelection(baseOffset: 0, extentOffset: _disc.text.length),
                onSubmitted: (_) => _save(),
              ),
            ],
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: Brand.bad))),
          ]),
        ),
        actions: [
          OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء (Esc)')),
          FilledButton(onPressed: _save, child: const Text('حفظ (Enter)')),
        ],
      );
}

/// بعد الاعتماد: رقم الفاتورة والباقي وحالة الطباعة. فشل الطباعة لا يمس الفاتورة ويمكن إعادة طباعتها.
class SaleDoneDialog extends StatefulWidget {
  final Map<String, dynamic> invoice;
  final bool reprint;
  const SaleDoneDialog({super.key, required this.invoice, this.reprint = false});
  @override
  State<SaleDoneDialog> createState() => _SaleDoneState();
}

class _SaleDoneState extends State<SaleDoneDialog> {
  bool _printing = true;
  String? _printError;
  String? _savedPath, _saveError;

  @override
  void initState() {
    super.initState();
    Future.microtask(() => _print(widget.reprint));
  }

  Future<void> _print(bool reprint) async {
    setState(() { _printing = true; _printError = null; });
    try {
      await ReceiptPrinter.printInvoice(widget.invoice, reprint: reprint);
    } on PrintFailure catch (e) {
      _printError = e.message;
    } catch (_) {
      _printError = 'فشلت الطباعة لسبب غير متوقع.';
    }
    if (mounted) setState(() => _printing = false);
  }

  /// حفظ الفاتورة PDF بالشكل المناسب لنوع الطابعة المختارة.
  Future<void> _export() async {
    try {
      final path = await ReceiptPrinter.exportPdf(widget.invoice);
      if (mounted) setState(() { _savedPath = path; _saveError = null; });
      await ReceiptPrinter.revealInExplorer(path);
    } catch (_) {
      if (mounted) setState(() => _saveError = 'تعذّر حفظ ملف PDF. تحقق من صلاحية الكتابة في مجلد المستندات.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final inv = widget.invoice;
    final change = (inv['change_baisa'] as num).toInt();
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyP, control: true): () => _print(true),
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _export,
      },
      child: AlertDialog(
        title: Text(widget.reprint ? 'إعادة طباعة الفاتورة' : 'تم اعتماد الفاتورة'),
        content: SizedBox(
          width: 460,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(inv['invoice_no'] as String, textDirection: TextDirection.ltr, textAlign: TextAlign.center, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
            Text('الإجمالي ${formatOmr((inv['total_baisa'] as num).toInt())} ر.ع', textAlign: TextAlign.center, style: const TextStyle(fontSize: 18)),
            if (change > 0 && !widget.reprint) ...[
              const SizedBox(height: 12),
              Text('الباقي للعميل ${formatOmr(change)}', textAlign: TextAlign.center, style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w800, color: Brand.ok)),
            ],
            const SizedBox(height: 16),
            if (_printing)
              const Text('جارٍ الطباعة…', textAlign: TextAlign.center)
            else if (_printError != null)
              Text('الفاتورة معتمدة ومحفوظة، لكن تعذّرت الطباعة:\n$_printError', textAlign: TextAlign.center, style: const TextStyle(color: Brand.bad, fontSize: 16))
            else
              const Text('أُرسلت الفاتورة إلى الطابعة.', textAlign: TextAlign.center, style: TextStyle(color: Brand.ok)),
            if (_savedPath != null)
              Padding(padding: const EdgeInsets.only(top: 10), child: Text('حُفظ الملف:\n$_savedPath', textAlign: TextAlign.center, textDirection: TextDirection.ltr, style: const TextStyle(color: Brand.ok, fontSize: 14))),
            if (_saveError != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_saveError!, textAlign: TextAlign.center, style: const TextStyle(color: Brand.bad))),
          ]),
        ),
        actions: [
          OutlinedButton(onPressed: _export, child: const Text('حفظ PDF (Ctrl+S)')),
          OutlinedButton(onPressed: _printing ? null : () => _print(true), child: const Text('إعادة الطباعة (Ctrl+P)')),
          FilledButton(autofocus: true, onPressed: () => Navigator.pop(context), child: Text(widget.reprint ? 'إغلاق (Enter)' : 'فاتورة جديدة (Enter)')),
        ],
      ),
    );
  }
}
