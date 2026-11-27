import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/theme.dart';
import '../pos/cart.dart';

/// F3: البحث عن عميل بالهاتف أو الاسم، أو عن مركبة باللوحة، وربطه بالفاتورة.
class CustomerLookupDialog extends StatefulWidget {
  final String branchId;
  const CustomerLookupDialog({super.key, required this.branchId});
  @override
  State<CustomerLookupDialog> createState() => _State();
}

class _State extends State<CustomerLookupDialog> {
  final _q = TextEditingController();
  Timer? _debounce;
  List<CustomerRef> _results = [];
  bool _loading = false;
  String? _error;
  // نموذج عميل جديد
  bool _adding = false, _saving = false;
  final _name = TextEditingController(), _phone = TextEditingController(), _plate = TextEditingController();

  Future<void> _saveNew() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'اكتب اسم العميل.');
      return;
    }
    setState(() { _saving = true; _error = null; });
    try {
      final r = (await Api.rpc('save_customer', {
        'p': {'branch_id': widget.branchId, 'name': _name.text.trim(), 'phone': _phone.text.trim(), 'plate': _plate.text.trim()}
      }) as Map).cast<String, dynamic>();
      final c = (r['customer'] as Map).cast<String, dynamic>();
      final v = (r['vehicle'] as Map?)?.cast<String, dynamic>();
      if (mounted) {
        Navigator.pop(context, CustomerRef(id: c['id'] as String, name: c['name'] as String, phone: c['phone'] as String?, vehicleId: v?['id'] as String?, plate: v?['plate'] as String?));
      }
      return;
    } on BusinessError catch (e) {
      _error = errorMessage(e.code);
    } on NoResponseError {
      _error = 'لا يوجد اتصال. لم يُحفظ العميل.';
    }
    if (mounted) setState(() => _saving = false);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    _name.dispose();
    _phone.dispose();
    _plate.dispose();
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
          child: _adding
              ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  TextField(controller: _name, autofocus: true, decoration: const InputDecoration(labelText: 'اسم العميل'), textInputAction: TextInputAction.next),
                  const SizedBox(height: 10),
                  TextField(controller: _phone, textDirection: TextDirection.ltr, decoration: const InputDecoration(labelText: 'الهاتف (مثال 9689XXXXXXX)'), textInputAction: TextInputAction.next),
                  const SizedBox(height: 10),
                  TextField(controller: _plate, decoration: const InputDecoration(labelText: 'رقم اللوحة (اختياري)'), onSubmitted: (_) => _saveNew()),
                  if (_error != null) Padding(padding: const EdgeInsets.all(8), child: Text(_error!, style: const TextStyle(color: Brand.bad))),
                  const SizedBox(height: 14),
                  FilledButton(onPressed: _saving ? null : _saveNew, child: Text(_saving ? 'جارٍ الحفظ…' : 'حفظ وربط بالفاتورة (Enter)')),
                  const SizedBox(height: 6),
                  const Text('إن كان الهاتف مسجلًا من قبل يُربط العميل الموجود وتُضاف له المركبة.', style: TextStyle(color: Brand.muted, fontSize: 13)),
                ])
              : Column(children: [
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
                  const Padding(padding: EdgeInsets.all(16), child: Text('لا نتائج. اضغط «عميل جديد» لإضافته.', style: TextStyle(color: Brand.muted))),
              ]),
            ),
          ]),
        ),
        actions: [
          if (!_adding)
            OutlinedButton(
                onPressed: () => setState(() {
                      _adding = true;
                      _error = null;
                      final q = _q.text.trim();
                      RegExp(r'^[0-9+ ]+$').hasMatch(q) ? _phone.text = q : _name.text = q;
                    }),
                child: const Text('عميل جديد')),
          OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('إغلاق (Esc)')),
        ],
      );
}
