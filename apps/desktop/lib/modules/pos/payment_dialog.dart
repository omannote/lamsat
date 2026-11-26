import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api.dart';
import '../../core/money.dart';
import '../../core/theme.dart';
import 'cart.dart';

/// نافذة الدفع: نقدي أو بطاقة أو مختلط. F9 يعتمد من داخل هذه النافذة فقط.
/// تسجيل البطاقة هنا يسجّل طريقة الدفع فقط؛ الخصم الفعلي يتم على جهاز البطاقة.
class PaymentDialog extends StatefulWidget {
  final int totalBaisa;
  const PaymentDialog({super.key, required this.totalBaisa});
  @override
  State<PaymentDialog> createState() => _State();
}

class PaymentResult {
  final PaymentSplit split;
  final String? cardReference;
  const PaymentResult(this.split, this.cardReference);
}

class _State extends State<PaymentDialog> {
  late final _tendered = TextEditingController(text: formatOmr(widget.totalBaisa));
  final _card = TextEditingController(text: '0');
  final _ref = TextEditingController();
  final _tenderedFocus = FocusNode();
  final _cardFocus = FocusNode();
  String? _error;

  @override
  void initState() {
    super.initState();
    _selectAll(_tendered);
    _tendered.addListener(_refresh);
    _card.addListener(_refresh);
  }

  void _refresh() => setState(() => _error = null);
  void _selectAll(TextEditingController c) => c.selection = TextSelection(baseOffset: 0, extentOffset: c.text.length);

  @override
  void dispose() {
    for (final c in [_tendered, _card, _ref]) {
      c.dispose();
    }
    _tenderedFocus.dispose();
    _cardFocus.dispose();
    super.dispose();
  }

  (PaymentSplit?, String?) _compute() {
    final card = parseOmr(_card.text.isEmpty ? '0' : _card.text);
    if (card == null) return (null, 'مبلغ البطاقة غير صالح.');
    final cashDue = widget.totalBaisa - card;
    final tendered = _tendered.text.trim().isEmpty ? null : parseOmr(_tendered.text);
    if (cashDue > 0 && _tendered.text.trim().isNotEmpty && tendered == null) return (null, 'المبلغ النقدي غير صالح.');
    return PaymentSplit.compute(total: widget.totalBaisa, cardBaisa: card, tenderedBaisa: cashDue > 0 ? tendered : null);
  }

  void _allCash() {
    _card.text = '0';
    _tendered.text = formatOmr(widget.totalBaisa);
    _tenderedFocus.requestFocus();
    _selectAll(_tendered);
  }

  void _allCard() {
    _card.text = formatOmr(widget.totalBaisa);
    _tendered.text = '';
    _cardFocus.requestFocus();
  }

  void _approve() {
    if (Api.online.value == false) {
      setState(() => _error = 'لا يوجد اتصال بالخادم. الاعتماد متوقف حتى يعود الاتصال.');
      return;
    }
    final (split, err) = _compute();
    if (split == null) {
      setState(() => _error = err);
      return;
    }
    Navigator.pop(context, PaymentResult(split, _ref.text.trim().isEmpty ? null : _ref.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final (split, _) = _compute();
    final card = parseOmr(_card.text.isEmpty ? '0' : _card.text) ?? 0;
    final int cashDue = (widget.totalBaisa - card).clamp(0, widget.totalBaisa).toInt();
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.f9): _approve,
        const SingleActivator(LogicalKeyboardKey.f7): _allCash,
        const SingleActivator(LogicalKeyboardKey.f8): _allCard,
      },
      child: AlertDialog(
        title: const Text('الدفع'),
        content: SizedBox(
          width: 520,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _big('الإجمالي المستحق', formatOmr(widget.totalBaisa), Brand.ink),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(child: OutlinedButton(onPressed: _allCash, child: const Text('نقدي كامل (F7)'))),
              const SizedBox(width: 8),
              Expanded(child: OutlinedButton(onPressed: _allCard, child: const Text('بطاقة كاملة (F8)'))),
            ]),
            const SizedBox(height: 16),
            TextField(
              controller: _tendered,
              focusNode: _tenderedFocus,
              autofocus: true,
              enabled: cashDue > 0,
              textDirection: TextDirection.ltr,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
              decoration: InputDecoration(labelText: 'النقد المستلم — المطلوب نقدًا ${formatOmr(cashDue)}'),
              textInputAction: TextInputAction.next,
              onSubmitted: (_) => _cardFocus.requestFocus(),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _card,
                  focusNode: _cardFocus,
                  textDirection: TextDirection.ltr,
                  style: const TextStyle(fontSize: 20),
                  decoration: const InputDecoration(labelText: 'مبلغ البطاقة'),
                  onTap: () => _selectAll(_card),
                  textInputAction: TextInputAction.next,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _ref,
                  textDirection: TextDirection.ltr,
                  decoration: const InputDecoration(labelText: 'مرجع عملية البطاقة (اختياري)'),
                  onSubmitted: (_) => _approve(),
                ),
              ),
            ]),
            const SizedBox(height: 16),
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
          FilledButton(onPressed: split == null ? null : _approve, child: const Text('اعتماد (F9)')),
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
