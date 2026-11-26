import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/money.dart';
import '../../core/theme.dart';
import '../pos/dialogs.dart';

/// سجل فواتير الفرع: بحث برقم الفاتورة أو الهاتف أو اللوحة، وإعادة طباعة.
class InvoiceHistoryDialog extends StatefulWidget {
  final String branchId;
  final bool canReprint;
  const InvoiceHistoryDialog({super.key, required this.branchId, required this.canReprint});
  @override
  State<InvoiceHistoryDialog> createState() => _State();
}

class _State extends State<InvoiceHistoryDialog> {
  final _q = TextEditingController();
  Timer? _debounce;
  List<Map<String, dynamic>>? _rows;
  String? _error;
  int _selected = 0;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  String _date(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _load() async {
    final muscat = DateTime.now().toUtc().add(const Duration(hours: 4));
    final searching = _q.text.trim().isNotEmpty;
    try {
      final r = await Api.rpc('list_invoices', {
        'p_branch_id': widget.branchId,
        // بلا بحث: آخر يومين (يغطي الوردية العابرة لمنتصف الليل). مع البحث: آخر 90 يومًا.
        'p_from': _date(muscat.subtract(Duration(days: searching ? 90 : 1))),
        'p_to': _date(muscat.add(const Duration(days: 1))),
        'p_search': searching ? _q.text.trim() : null,
        'p_limit': 50,
      });
      if (mounted) setState(() { _rows = (r as List).cast<Map>().map((m) => m.cast<String, dynamic>()).toList(); _selected = 0; _error = null; });
    } on BusinessError catch (e) {
      if (mounted) setState(() => _error = errorMessage(e.code));
    } on NoResponseError {
      if (mounted) setState(() => _error = 'لا يوجد اتصال بالخادم.');
    }
  }

  Future<void> _reprint(Map<String, dynamic> row) async {
    if (!widget.canReprint) return showMessage(context, 'إعادة الطباعة', 'لا تملك صلاحية إعادة الطباعة.');
    try {
      final inv = (await Api.rpc('get_invoice', {'p_invoice_id': row['id']}) as Map).cast<String, dynamic>();
      if (!mounted) return;
      await showDialog<void>(context: context, barrierDismissible: false, builder: (_) => SaleDoneDialog(invoice: inv, reprint: true));
    } on BusinessError catch (e) {
      if (mounted) await showMessage(context, 'تعذّر فتح الفاتورة', errorMessage(e.code));
    } on NoResponseError {
      if (mounted) await showMessage(context, 'لا يوجد اتصال', 'تعذّر تحميل الفاتورة. أعد المحاولة بعد عودة الاتصال.');
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('سجل الفواتير'),
        content: SizedBox(
          width: 760,
          height: 460,
          child: Column(children: [
            TextField(
              controller: _q,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'رقم الفاتورة، الهاتف، أو اللوحة — Enter لإعادة طباعة السطر المحدد'),
              onChanged: (_) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 300), _load);
              },
              onSubmitted: (_) {
                if ((_rows ?? []).isNotEmpty) _reprint(_rows![_selected]);
              },
            ),
            if (_error != null) Padding(padding: const EdgeInsets.all(8), child: Text(_error!, style: const TextStyle(color: Brand.bad))),
            Expanded(
              child: _rows == null
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(children: [
                      for (final (i, r) in _rows!.indexed)
                        ListTile(
                          selected: i == _selected,
                          dense: true,
                          title: Row(children: [
                            SizedBox(width: 170, child: Text(r['invoice_no'] as String, textDirection: TextDirection.ltr, style: const TextStyle(fontWeight: FontWeight.w700))),
                            Expanded(child: Text([r['customer_name'], r['plate'], r['cashier_name']].whereType<String>().join(' · '), overflow: TextOverflow.ellipsis)),
                            Text(formatOmr((r['total_baisa'] as num).toInt()), textDirection: TextDirection.ltr, style: const TextStyle(fontWeight: FontWeight.w700)),
                          ]),
                          trailing: const Icon(Icons.print_outlined),
                          onTap: () {
                            setState(() => _selected = i);
                            _reprint(r);
                          },
                        ),
                      if (_rows!.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('لا توجد فواتير.', style: TextStyle(color: Brand.muted)))),
                    ]),
            ),
          ]),
        ),
        actions: [OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('إغلاق (Esc)'))],
      );
}
