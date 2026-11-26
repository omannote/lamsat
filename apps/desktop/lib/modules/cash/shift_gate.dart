import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../core/api.dart';
import '../../core/money.dart';
import '../../core/theme.dart';
import '../pos/cart.dart';
import '../pos/pos_screen.dart';

/// بيانات الوردية الجارية التي تحتاجها شاشة البيع.
class ShiftContext {
  final String userName, branchId, branchName, branchCode, deviceName, sessionId;
  final TaxSettings tax;
  final int maxDiscountBp;
  final Set<String> permissions;
  const ShiftContext({
    required this.userName, required this.branchId, required this.branchName, required this.branchCode,
    required this.deviceName, required this.sessionId, required this.tax, required this.maxDiscountBp, required this.permissions,
  });
}

/// بعد الدخول: يحمّل الصلاحيات والجهاز، ثم يفتح وردية أو يستأنف الوردية المفتوحة.
class ShiftGate extends StatefulWidget {
  const ShiftGate({super.key});
  @override
  State<ShiftGate> createState() => _State();
}

class _State extends State<ShiftGate> {
  Map<String, dynamic>? _user, _branch, _device, _openSession;
  ShiftContext? _shift;
  String? _error;
  bool _loading = true, _busy = false;
  final _cash = TextEditingController(text: '0');
  String _openOpId = const Uuid().v4();

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  @override
  void dispose() {
    _cash.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final ctx = (await Api.rpc('my_context') as Map).cast<String, dynamic>();
      final dev = (await Api.rpc('resolve_device', {'p_code': Api.config.deviceCode}) as Map).cast<String, dynamic>();
      final device = (dev['device'] as Map).cast<String, dynamic>();
      final branches = (ctx['branches'] as List).cast<Map>();
      final branch = branches.firstWhere((b) => b['id'] == device['branch_id']).cast<String, dynamic>();
      _user = (ctx['user'] as Map?)?.cast<String, dynamic>();
      _branch = branch;
      _device = device;
      _openSession = (dev['open_session'] as Map?)?.cast<String, dynamic>();
      if (_user == null) throw BusinessError('FORBIDDEN');
      if (_openSession != null && _openSession!['mine'] == true) _enter(_openSession!['id'] as String);
    } on BusinessError catch (e) {
      _error = errorMessage(e.code);
    } on NoResponseError {
      _error = 'لا يوجد اتصال بالخادم. النظام يعمل بالاتصال فقط.';
    } catch (_) {
      _error = 'هذا الجهاز غير مرتبط بفرع ضمن صلاحياتك.';
    }
    if (mounted) setState(() => _loading = false);
  }

  void _enter(String sessionId) {
    final b = _branch!;
    _shift = ShiftContext(
      userName: _user!['full_name'] as String, branchId: b['id'] as String, branchName: b['name_ar'] as String,
      branchCode: b['code'] as String, deviceName: _device!['name'] as String, sessionId: sessionId,
      tax: TaxSettings(enabled: b['tax_enabled'] as bool, rateBp: (b['tax_rate_bp'] as num).toInt(), pricesIncludeTax: b['prices_include_tax'] as bool),
      maxDiscountBp: (b['max_discount_bp'] as num?)?.toInt() ?? 0,
      permissions: (b['permissions'] as List).cast<String>().toSet(),
    );
  }

  Future<void> _open() async {
    final amount = parseOmr(_cash.text);
    if (amount == null) {
      setState(() => _error = 'أدخل النقد الافتتاحي بصيغة صحيحة، مثل 20 أو 20.500');
      return;
    }
    if (Api.online.value == false) {
      setState(() => _error = 'لا يوجد اتصال. لا يمكن فتح الوردية الآن.');
      return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      // المعرّف نفسه يُعاد استخدامه عند إعادة المحاولة حتى لا تُفتح ورديتان
      final r = (await Api.rpc('open_cash_session', {'p_operation_id': _openOpId, 'p_device_id': _device!['id'], 'p_opening_cash_baisa': amount}) as Map).cast<String, dynamic>();
      _enter((r['session'] as Map)['id'] as String);
    } on BusinessError catch (e) {
      _openOpId = const Uuid().v4();
      if (e.code == 'SESSION_ALREADY_OPEN') {
        _busy = false;
        await _load();
        return;
      }
      _error = errorMessage(e.code);
    } on NoResponseError {
      _error = 'انقطع الاتصال أثناء فتح الوردية. اضغط «فتح الوردية» مجددًا للتحقق وإكمال الفتح.';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_shift != null) return PosScreen(shift: _shift!);
    final otherOpen = _openSession != null && _openSession!['mine'] != true;
    return Scaffold(
      backgroundColor: Brand.ink,
      body: Center(
        child: Container(
          width: 460,
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
          child: _loading
              ? const SizedBox(height: 120, child: Center(child: CircularProgressIndicator()))
              : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const Text('فتح الوردية', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 12),
                  if (_branch != null) ...[
                    _kv('الفرع', _branch!['name_ar'] as String),
                    _kv('الصندوق', '${_device!['name']} (${_device!['code']})'),
                    _kv('الموظف', _user?['full_name'] as String? ?? ''),
                  ],
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: ValueListenableBuilder<bool?>(valueListenable: Api.online, builder: (_, v, __) => ConnectionBadge(online: v, onDark: false)),
                  ),
                  if (otherOpen)
                    Text('توجد وردية مفتوحة على هذا الصندوق باسم ${_openSession!['opened_by_name']}. يجب إقفالها أولًا.',
                        style: const TextStyle(color: Brand.bad, fontSize: 17))
                  else if (_branch != null) ...[
                    const SizedBox(height: 8),
                    TextField(
                      controller: _cash,
                      autofocus: true,
                      textDirection: TextDirection.ltr,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
                      decoration: const InputDecoration(labelText: 'النقد الافتتاحي (ر.ع)'),
                      onTap: () => _cash.selection = TextSelection(baseOffset: 0, extentOffset: _cash.text.length),
                      onSubmitted: (_) => _open(),
                    ),
                  ],
                  if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: Brand.bad))),
                  const SizedBox(height: 20),
                  if (_branch != null && !otherOpen) FilledButton(onPressed: _busy ? null : _open, child: Text(_busy ? 'جارٍ الفتح…' : 'فتح الوردية (Enter)')),
                  if (_branch == null || otherOpen) OutlinedButton(onPressed: _load, child: const Text('إعادة المحاولة')),
                  const SizedBox(height: 8),
                  TextButton(onPressed: () => Api.client.auth.signOut(), child: const Text('تسجيل الخروج')),
                ]),
        ),
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [SizedBox(width: 90, child: Text(k, style: const TextStyle(color: Brand.muted))), Expanded(child: Text(v, style: const TextStyle(fontWeight: FontWeight.w600)))]),
      );
}
