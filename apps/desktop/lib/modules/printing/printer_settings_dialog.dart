import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../../core/api.dart';
import '../../core/theme.dart';
import 'receipt.dart';

/// إعداد الطابعة وحالة الاتصال.
class PrinterSettingsDialog extends StatefulWidget {
  const PrinterSettingsDialog({super.key});
  @override
  State<PrinterSettingsDialog> createState() => _State();
}

class _State extends State<PrinterSettingsDialog> {
  List<Printer>? _printers;
  String? _selected;
  String? _message;
  bool _error = false, _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await ReceiptPrinter.listPrinters();
      final saved = await ReceiptPrinter.savedPrinterName();
      if (!mounted) return;
      setState(() {
        _printers = list;
        _selected = list.any((p) => p.name == saved) ? saved : null;
        if (saved != null && _selected == null) {
          _message = 'الطابعة المحفوظة «$saved» غير موجودة الآن.';
          _error = true;
        }
      });
    } catch (_) {
      if (mounted) setState(() { _printers = []; _message = 'تعذّر قراءة طابعات Windows.'; _error = true; });
    }
  }

  Future<void> _test() async {
    final p = _printers!.firstWhere((x) => x.name == _selected);
    setState(() { _busy = true; _message = null; });
    try {
      await ReceiptPrinter.printTest(p);
      if (mounted) setState(() { _message = 'أُرسلت صفحة الاختبار. تأكد من خروجها ووضوح العربية.'; _error = false; });
    } on PrintFailure catch (e) {
      if (mounted) setState(() { _message = '${e.message} تحقق من الورق والتوصيل.'; _error = true; });
    } catch (_) {
      if (mounted) setState(() { _message = 'فشل اختبار الطباعة.'; _error = true; });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('إعداد الطابعة وحالة الاتصال'),
      content: SizedBox(
        width: 480,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          ValueListenableBuilder<bool?>(valueListenable: Api.online, builder: (_, v, __) => ConnectionBadge(online: v, onDark: false)),
          const SizedBox(height: 16),
          const Text('طابعة الإيصالات'),
          const SizedBox(height: 6),
          if (_printers == null)
            const LinearProgressIndicator()
          else
            DropdownButtonFormField<String>(
              value: _selected,
              autofocus: true,
              isExpanded: true,
              hint: const Text('اختر الطابعة'),
              items: [for (final p in _printers!) DropdownMenuItem(value: p.name, child: Text(p.name, overflow: TextOverflow.ellipsis))],
              onChanged: (v) async {
                setState(() { _selected = v; _message = null; });
                await ReceiptPrinter.savePrinterName(v);
              },
            ),
          if (_message != null) ...[
            const SizedBox(height: 12),
            Text(_message!, style: TextStyle(color: _error ? Brand.bad : Brand.ok)),
          ],
        ]),
      ),
      actions: [
        OutlinedButton(onPressed: (_selected == null || _busy) ? null : _test, child: Text(_busy ? 'جارٍ الطباعة…' : 'اختبار الطباعة')),
        OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('إغلاق (Esc)')),
      ],
    );
  }
}
