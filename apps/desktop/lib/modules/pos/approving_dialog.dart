import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/theme.dart';
import 'pending_operation.dart';

enum ApproveStatus { approved, needsConfirm, error, abandoned }

class ApproveOutcome {
  final ApproveStatus status;
  final Map<String, dynamic>? data; // الفاتورة عند approved، أو رد الخادم عند needsConfirm
  final BusinessError? error;
  const ApproveOutcome(this.status, {this.data, this.error});
}

enum _Phase { sending, verifying, notRecorded }

/// يرسل اعتماد البيع بمعرّف عملية ثابت، وعند غياب الرد يتحقق من النتيجة قبل أي عملية بديلة.
/// [verifyOnly] يُستخدم بعد إعادة تشغيل التطبيق للتحقق من عملية محفوظة دون إرسالها مباشرة.
class ApprovingDialog extends StatefulWidget {
  final String operationId, cashSessionId;
  final Map<String, dynamic> payload;
  final bool verifyOnly;
  const ApprovingDialog({super.key, required this.operationId, required this.cashSessionId, required this.payload, this.verifyOnly = false});
  @override
  State<ApprovingDialog> createState() => _State();
}

class _State extends State<ApprovingDialog> {
  _Phase _phase = _Phase.sending;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(() => widget.verifyOnly ? _verify() : _send());
  }

  Future<void> _done(ApproveOutcome o, {bool clear = true}) async {
    if (clear) await PendingOperation.clear();
    if (mounted) Navigator.pop(context, o);
  }

  Future<void> _handleResponse(Map<String, dynamic> r) async {
    if (r['status'] == 'approved') {
      await _done(ApproveOutcome(ApproveStatus.approved, data: (r['invoice'] as Map).cast<String, dynamic>()));
    } else {
      await _done(ApproveOutcome(ApproveStatus.needsConfirm, data: r)); // price_changed / total_changed: لم يُحفظ شيء
    }
  }

  Future<void> _send() async {
    setState(() { _phase = _Phase.sending; _busy = true; });
    try {
      final r = (await Api.rpc('approve_sale', {'p_operation_id': widget.operationId, 'p_payload': widget.payload}) as Map).cast<String, dynamic>();
      await _handleResponse(r);
    } on BusinessError catch (e) {
      // رفض صريح من الخادم: لم يُحفظ شيء. انتهاء الجلسة يُبقي العملية محفوظة للتحقق بعد الدخول.
      await _done(ApproveOutcome(ApproveStatus.error, error: e), clear: e.code != 'NOT_AUTHENTICATED');
    } on NoResponseError {
      unawaited(_verify());
    }
  }

  Future<void> _verify() async {
    if (mounted) setState(() { _phase = _Phase.verifying; _busy = true; });
    while (mounted) {
      try {
        final r = (await Api.rpc('get_operation', {'p_operation_id': widget.operationId}) as Map).cast<String, dynamic>();
        final result = (r['result'] as Map?)?.cast<String, dynamic>();
        if (r['found'] == true && result?['status'] == 'approved') {
          await _handleResponse(result!);
        } else if (r['found'] == true && result?['status'] == 'cancelled') {
          await _done(const ApproveOutcome(ApproveStatus.abandoned));
        } else if (mounted) {
          setState(() { _phase = _Phase.notRecorded; _busy = false; });
        }
        return;
      } on BusinessError catch (e) {
        await _done(ApproveOutcome(ApproveStatus.error, error: e), clear: false);
        return;
      } on NoResponseError {
        await Future<void>.delayed(const Duration(seconds: 3)); // ننتظر عودة الاتصال
      }
    }
  }

  /// العودة للسلة: يُحجز المعرّف كملغى في الخادم أولًا حتى لا يُعتمد طلب متأخر.
  Future<void> _abandon() async {
    setState(() => _busy = true);
    try {
      final r = (await Api.rpc('cancel_operation', {'p_operation_id': widget.operationId, 'p_cash_session_id': widget.cashSessionId}) as Map).cast<String, dynamic>();
      if (r['status'] == 'approved') {
        await _handleResponse(r);
      } else {
        await _done(const ApproveOutcome(ApproveStatus.abandoned));
      }
    } on BusinessError catch (e) {
      await _done(ApproveOutcome(ApproveStatus.error, error: e), clear: false);
    } on NoResponseError {
      unawaited(_verify());
    }
  }

  @override
  Widget build(BuildContext context) {
    final (title, body) = switch (_phase) {
      _Phase.sending => ('جارٍ اعتماد الفاتورة…', 'لا تغلق التطبيق.'),
      _Phase.verifying => ('جارٍ التحقق من نتيجة الاعتماد', 'انقطع الرد من الخادم. سيتم التحقق تلقائيًا فور عودة الاتصال، ولن تُنشأ فاتورة بديلة قبل معرفة النتيجة.'),
      _Phase.notRecorded => ('لم تُسجَّل الفاتورة في الخادم', 'تم التحقق: العملية غير محفوظة. يمكنك إعادة إرسالها كما هي، أو العودة إلى السلة.'),
    };
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 460,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(body, style: const TextStyle(fontSize: 17)),
            const SizedBox(height: 16),
            if (_busy) const LinearProgressIndicator(),
            const SizedBox(height: 12),
            ValueListenableBuilder<bool?>(valueListenable: Api.online, builder: (_, v, __) => ConnectionBadge(online: v, onDark: false)),
          ]),
        ),
        actions: _phase == _Phase.notRecorded && !_busy
            ? [
                OutlinedButton(onPressed: _abandon, child: const Text('العودة إلى السلة')),
                FilledButton(autofocus: true, onPressed: _send, child: const Text('إعادة الإرسال')),
              ]
            : null,
      ),
    );
  }
}
