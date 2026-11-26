import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/theme.dart';
import '../pos/cart.dart';

/// F3: البحث عن عميل بالهاتف أو الاسم، أو عن مركبة باللوحة، وربطه بالفاتورة.
class CustomerLookupDialog extends StatefulWidget {
  const CustomerLookupDialog({super.key});
  @override
  State<CustomerLookupDialog> createState() => _State();
}

class _State extends State<CustomerLookupDialog> {
  final _q = TextEditingController();
  Timer? _debounce;
  List<CustomerRef> _results = [];
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  void _changed(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _search);
  }

  Future<void> _search() async {
    // أحرف البحث تُنقّى لأنها تدخل في مرشّح PostgREST
    final q = _q.text.replaceAll(RegExp(r'[^0-9A-Za-z؀-ۿ ]'), '').trim();
    if (q.length < 2) {
      setState(() => _results = []);
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      final db = Api.client;
      final customers = (await db.from('customers').select('id,name,phone').or('phone.ilike.%$q%,name.ilike.%$q%').limit(8).timeout(const Duration(seconds: 10))).cast<Map<String, dynamic>>();
      final vehicles = (await db.from('vehicles').select('id,plate,customer_id').ilike('plate', '%$q%').limit(8).timeout(const Duration(seconds: 10))).cast<Map<String, dynamic>>();
      final ownerIds = vehicles.map((v) => v['customer_id']).whereType<String>().toSet().toList();
      final owners = ownerIds.isEmpty
          ? <Map<String, dynamic>>[]
          : (await db.from('customers').select('id,name,phone').inFilter('id', ownerIds).timeout(const Duration(seconds: 10))).cast<Map<String, dynamic>>();
      final out = <CustomerRef>[
        for (final v in vehicles)
          for (final o in owners.where((o) => o['id'] == v['customer_id']))
            CustomerRef(id: o['id'] as String, name: o['name'] as String, phone: o['phone'] as String?, vehicleId: v['id'] as String, plate: v['plate'] as String),
        for (final c in customers) CustomerRef(id: c['id'] as String, name: c['name'] as String, phone: c['phone'] as String?),
      ];
      if (mounted) setState(() => _results = out);
    } catch (_) {
      if (mounted) setState(() => _error = 'تعذّر البحث. تحقق من الاتصال.');
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('ربط عميل أو مركبة'),
        content: SizedBox(
          width: 520,
          height: 380,
          child: Column(children: [
            TextField(
              controller: _q,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'الهاتف، الاسم، أو رقم اللوحة'),
              onChanged: _changed,
              onSubmitted: (_) {
                if (_results.isNotEmpty) Navigator.pop(context, _results.first);
              },
            ),
            if (_loading) const LinearProgressIndicator(),
            if (_error != null) Padding(padding: const EdgeInsets.all(8), child: Text(_error!, style: const TextStyle(color: Brand.bad))),
            Expanded(
              child: ListView(children: [
                for (final (i, r) in _results.indexed)
                  ListTile(
                    selected: i == 0,
                    title: Text(r.plate == null ? r.name : '${r.plate} — ${r.name}'),
                    subtitle: r.phone == null ? null : Text(r.phone!, textDirection: TextDirection.ltr),
                    onTap: () => Navigator.pop(context, r),
                  ),
                if (_results.isEmpty && !_loading && _q.text.trim().length >= 2)
                  const Padding(padding: EdgeInsets.all(16), child: Text('لا نتائج. إضافة عميل جديد تتوفر في المرحلة 2.', style: TextStyle(color: Brand.muted))),
              ]),
            ),
          ]),
        ),
        actions: [OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('إغلاق (Esc)'))],
      );
}
