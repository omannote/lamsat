import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// عملية بيع أُرسلت ولم تُعرف نتيجتها بعد. تُحفظ على الجهاز (المعرّف والحمولة فقط) حتى
/// يمكن التحقق منها بعد عودة الاتصال أو إعادة تشغيل التطبيق. المعاملة نفسها تبقى في السحابة.
class PendingOperation {
  static const _k = 'pending_sale';
  final String operationId;
  final Map<String, dynamic> payload;
  final DateTime createdAt;
  PendingOperation(this.operationId, this.payload, this.createdAt);

  static Future<void> save(String operationId, Map<String, dynamic> payload) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_k, jsonEncode({'operation_id': operationId, 'payload': payload, 'created_at': DateTime.now().toIso8601String()}));
  }

  static Future<PendingOperation?> load() async {
    final p = await SharedPreferences.getInstance();
    final s = p.getString(_k);
    if (s == null) return null;
    final j = jsonDecode(s) as Map<String, dynamic>;
    return PendingOperation(j['operation_id'] as String, (j['payload'] as Map).cast<String, dynamic>(), DateTime.parse(j['created_at'] as String));
  }

  static Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_k);
  }
}
