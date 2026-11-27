import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api.dart';
import '../../core/money.dart';
import '../../core/theme.dart';
import 'cart.dart';

enum PayMethod {
  cash('نقدي', 'F8'), card('بطاقة', 'F9'), transfer('تحويل بنكي', 'F6'), credit('آجل', 'F7');

  final String label, key;
  const PayMethod(this.label, this.key);
}

/// نافذة الدفع حسب التصميم: نقدي F8 · بطاقة F9 · تحويل بنكي F6 · آجل F7 · مبالغ سريعة Ctrl+1..4
/// F10 تأكيد وطباعة · Enter تأكيد بدون طباعة. مفتاح الطريقة يجعل الفاتورة كلها بتلك الطريقة،
/// وللدفع المختلط تُعدَّل المبالغ في الحقول. البطاقة والتحويل يُسجَّلان فقط؛ التحصيل الفعلي خارج النظام.
class PaymentDialog extends StatefulWidget {
  final int totalBaisa;
  final PayMethod initial;
  final String? customerName; // الآجل يتطلب عميلًا مربوطًا بالفاتورة
  const PaymentDialog({super.key, required this.totalBaisa, this.initial = PayMethod.cash, this.customerName});
  @override
  State<PaymentDialog> createState() => _State();
}

class PaymentResult {
  final PaymentSplit split;
  final String? reference;
  final bool print;
  const PaymentResult(this.split, this.reference, {required this.print});
}

class _State extends State<PaymentDialog> {
  final _tendered = TextEditingController();
  final _card = TextEditingController(text: '0');
  final _transfer = TextEditingController(text: '0');
  final _credit = TextEditingController(text: '0');
  final _ref = TextEditingController();
  final _focus = {for (final m in PayMethod.values) m: FocusNode()};
  late PayMethod _active = widget.initial;
  String? _error;

  TextEditingController _ctl(PayMethod m) => switch (m) {
        PayMethod.cash => _tendered,
        PayMethod.card => _card,
        PayMethod.transfer => _transfer,
        PayMethod.credit => _credit,
      };

  @override
  void initState() {
    super.initState();
    _setAll(widget.initial == PayMethod.credit && widget.customerName == null ? PayMethod.cash : widget.initial, focus: false);
    for (final m in PayMethod.values) {
      _ctl(m).addListener(_refresh);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus[_active]!.requestFocus();
    });
  }

  void _refresh() => setState(() => _error = null);
  void _selectAll(TextEditingController c) => c.selection = TextSelection(baseOffset: 0, extentOffset: c.text.length);

  @override
  void dispose() {
    for (final m in PayMethod.values) {
      _ctl(m).dispose();
      _focus[m]!.dispose();
    }
    _ref.dispose();
    super.dispose();
  }

  /// الفاتورة كلها بطريقة واحدة.
  void _setAll(PayMethod m, {bool focus = true}) {
    if (m == PayMethod.credit && widget.customerName == null) {
      setState(() => _error = 'البيع الآجل يتطلب عميلًا. ارجع (Esc) واربط العميل بالفاتورة (F3) ثم ادفع.');
      return;
    }
    _active = m;
    for (final x in [PayMethod.card, PayMethod.transfer, PayMethod.credit]) {
      _ctl(x).text = x == m ? formatOmr(widget.totalBaisa) : '0';
    }
    _tendered.text = m == PayMethod.cash ? formatOmr(widget.totalBaisa) : '';
    _selectAll(_ctl(m));
    if (focus) _focus[m]!.requestFocus();
  }

  int? _amount(TextEditingController c) => parseOmr(c.text.trim().isEmpty ? '0' : c.text);

  (PaymentSplit?, String?) _compute() {
    final card = _amount(_card), transfer = _amount(_transfer), credit = _amount(_credit);
    if (card == null || transfer == null || credit == null) return (null, 'أحد المبالغ غير صالح.');
    if (credit > 0 && widget.customerName == null) return (null, 'البيع الآجل يتطلب عميلًا مربوطًا بالفاتورة (F3).');
    final cashDue = widget.totalBaisa - card - transfer - credit;
    final tendered = _tendered.text.trim().isEmpty ? null : parseOmr(_tendered.text);
    if (cashDue > 0 && _tendered.text.trim().isNotEmpty && tendered == null) return (null, 'المبلغ النقدي غير صالح.');
    return PaymentSplit.compute(
        total: widget.totalBaisa, cardBaisa: card, transferBaisa: transfer, creditBaisa: credit, tenderedBaisa: cashDue > 0 ? tendered : null);
  }

  int _cashDue() {
    final others = (_amount(_card) ?? 0) + (_amount(_transfer) ?? 0) + (_amount(_credit) ?? 0);
    return (widget.totalBaisa - others).clamp(0, widget.totalBaisa).toInt();
  }

  /// مبالغ نقدية سريعة: المبلغ بالضبط ثم أقرب ريال و5 و10 و20 للأعلى، بلا تكرار.
  List<int> _quick() {
    final due = _cashDue();
    if (due <= 0) return const [];
    final out = <int>[due];
    for (final step in [1000, 5000, 10000, 20000]) {
      final v = ((due + step - 1) ~/ step) * step;
      if (!out.contains(v)) out.add(v);
      if (out.length == 4) break;
    }
    return out;
  }

  void _quickPick(int i) {
    final q = _quick();
    if (i >= q.length) return;
    _tendered.text = formatOmr(q[i]);
    _selectAll(_tendered);
    _focus[PayMethod.cash]!.requestFocus();
  }

  void _approve({required bool print}) {
    if (Api.online.value == false) {
      setState(() => _error = 'لا يوجد اتصال بالخادم. الاعتماد متوقف حتى يعود الاتصال.');
      return;
    }
    final (split, err) = _compute();
    if (split == null) {
      setState(() => _error = err);
      return;
    }
    Navigator.pop(context, PaymentResult(split, _ref.text.trim().isEmpty ? null : _ref.text.trim(), print: print));
  }

  Widget _field(PayMethod m, String label, {bool enabled = true}) => TextField(
        controller: _ctl(m),
        focusNode: _focus[m],
        enabled: enabled,
        textDirection: TextDirection.ltr,
        style: TextStyle(fontSize: m == PayMethod.cash ? 24 : 19, fontWeight: FontWeight.w700),
        decoration: InputDecoration(labelText: label),
        onTap: () => _selectAll(_ctl(m)),
        onSubmitted: (_) => _approve(print: false),
      );

  @override
  Widget build(BuildContext context) {
    final (split, _) = _compute();
    final cashDue = _cashDue();
    final quick = _quick();
    final needsRef = (_amount(_card) ?? 0) > 0 || (_amount(_transfer) ?? 0) > 0;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.f8): () => _setAll(PayMethod.cash),
        const SingleActivator(LogicalKeyboardKey.f9): () => _setAll(PayMethod.card),
        const SingleActivator(LogicalKeyboardKey.f6): () => _setAll(PayMethod.transfer),
        const SingleActivator(LogicalKeyboardKey.f7): () => _setAll(PayMethod.credit),
        const SingleActivator(LogicalKeyboardKey.f10): () => _approve(print: true),
        for (var i = 0; i < 4; i++) SingleActivator(LogicalKeyboardKey(LogicalKeyboardKey.digit1.keyId + i), control: true): () => _quickPick(i),
      },
      child: AlertDialog(
        title: const Text('الدفع'),
        content: SizedBox(
          width: 620,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _big('الإجمالي المستحق', formatOmr(widget.totalBaisa), Brand.ink),
            const SizedBox(height: 12),
            Row(children: [
              for (final m in PayMethod.values)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: m == _active
                        ? FilledButton(focusNode: FocusNode(skipTraversal: true), onPressed: () => _setAll(m), child: Text('${m.label} ${m.key}'))
                        : OutlinedButton(focusNode: FocusNode(skipTraversal: true), onPressed: () => _setAll(m), child: Text('${m.label} ${m.key}')),
                  ),
                ),
            ]),
            const SizedBox(height: 14),
            _field(PayMethod.cash, 'النقد المستلم — المطلوب نقدًا ${formatOmr(cashDue)}', enabled: cashDue > 0),
            if (quick.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(children: [
                  for (var i = 0; i < quick.length; i++)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: OutlinedButton(
                          focusNode: FocusNode(skipTraversal: true),
                          onPressed: () => _quickPick(i),
                          child: Text('${formatOmr(quick[i])}  (Ctrl+${i + 1})', textDirection: TextDirection.ltr),
                        ),
                      ),
                    ),
                ]),
              ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _field(PayMethod.card, 'بطاقة')),
              const SizedBox(width: 8),
              Expanded(child: _field(PayMethod.transfer, 'تحويل بنكي')),
              const SizedBox(width: 8),
              Expanded(child: _field(PayMethod.credit, 'آجل', enabled: widget.customerName != null)),
            ]),
            if (needsRef)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: TextField(
                  controller: _ref,
                  textDirection: TextDirection.ltr,
                  decoration: const InputDecoration(labelText: 'مرجع عملية البطاقة أو التحويل (اختياري)'),
                  onSubmitted: (_) => _approve(print: false),
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                  widget.customerName == null ? 'الآجل غير متاح: الفاتورة بلا عميل.' : 'الآجل يُسجَّل على حساب العميل: ${widget.customerName}',
                  style: const TextStyle(color: Brand.muted)),
            ),
            const SizedBox(height: 12),
            _big('الباقي للعميل', formatOmr(split?.change ?? 0), (split?.change ?? 0) > 0 ? Brand.ok : Brand.muted),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: Brand.bad, fontSize: 16))),
            ValueListenableBuilder<bool?>(
              valueListenable: Api.online,
              builder: (_, v, __) => v == false
                  ? const Padding(padding: EdgeInsets.only(top: 12), child: Text('غير متصل — الاعتماد متوقف.', style: TextStyle(color: Brand.bad, fontWeight: FontWeight.w700)))
                  : const SizedBox.shrink(),
            ),
          ]),
        ),
        actions: [
          OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('رجوع (Esc)')),
          OutlinedButton(onPressed: split == null ? null : () => _approve(print: false), child: const Text('تأكيد بدون طباعة (Enter)')),
          FilledButton(onPressed: split == null ? null : () => _approve(print: true), child: const Text('تأكيد وطباعة (F10)')),
        ],
      ),
    );
  }

  Widget _big(String label, String value, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(color: Brand.bg, borderRadius: BorderRadius.circular(10)),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(label, style: const TextStyle(fontSize: 18, color: Brand.muted)),
          Text(value, textDirection: TextDirection.ltr, style: TextStyle(fontSize: 34, fontWeight: FontWeight.w800, color: color)),
        ]),
      );
}
