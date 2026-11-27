import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../../core/api.dart';
import '../../core/money.dart';
import '../../core/theme.dart';
import '../cash/cash_movement_dialog.dart';
import '../cash/close_shift_dialog.dart';
import '../cash/shift_gate.dart';
import '../printing/printer_settings_dialog.dart';

part 'inventory_pages.dart';

/// هيكل صفحة: عنوان، أدوات، ومحتوى داخل بطاقة بيضاء.
class _Page extends StatelessWidget {
  final String title;
  final List<Widget> tools;
  final Widget child;
  const _Page({required this.title, this.tools = const [], required this.child});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)), const SizedBox(width: 16), ...tools]),
          const SizedBox(height: 10),
          Expanded(
            child: Container(
              decoration: BoxDecoration(color: Colors.white, border: Border.all(color: Brand.line), borderRadius: BorderRadius.circular(12)),
              clipBehavior: Clip.antiAlias,
              child: child,
            ),
          ),
        ]),
      );
}

Widget _note(String text, {bool bad = false}) =>
    Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(text, textAlign: TextAlign.center, style: TextStyle(fontSize: 17, color: bad ? Brand.bad : Brand.muted))));

Widget _cell(String t, {int flex = 1, bool num = false, bool bold = false, Color? color}) => Expanded(
      flex: flex,
      child: Text(t,
          overflow: TextOverflow.ellipsis,
          textDirection: num ? TextDirection.ltr : null,
          textAlign: num ? TextAlign.right : null,
          style: TextStyle(fontSize: 16, fontWeight: bold ? FontWeight.w700 : FontWeight.w400, color: color)),
    );

Widget _head(List<(String, int)> cols) => Container(
      color: Brand.ink,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(children: [for (final (t, f) in cols) Expanded(flex: f, child: Text(t, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)))]),
    );

String _fail(Object e) => e is BusinessError ? errorMessage(e.code) : 'لا يوجد اتصال بالخادم.';

// ───────────────────────── العملاء ─────────────────────────
class CustomersPage extends StatefulWidget {
  final ShiftContext ctx;
  const CustomersPage({super.key, required this.ctx});
  @override
  State<CustomersPage> createState() => _CustomersState();
}

class _CustomersState extends State<CustomersPage> {
  List<Map<String, dynamic>> _customers = [];
  List<Map<String, dynamic>>? _invoices;
  Map<String, dynamic>? _selected;
  String? _error;
  int? _balance; // رصيد العميل الآجل

  @override
  void initState() {
    super.initState();
    Future.microtask(() => _search(''));
  }

  Future<void> _search(String raw) async {
    final q = raw.replaceAll(RegExp(r'[^0-9A-Za-z؀-ۿ ]'), '').trim();
    try {
      var query = Api.client.from('customers').select('id, name, phone');
      if (q.isNotEmpty) query = query.or('phone.ilike.%$q%,name.ilike.%$q%');
      final r = await query.order('created_at', ascending: false).limit(50).timeout(const Duration(seconds: 12));
      if (mounted) setState(() { _customers = r.cast<Map<String, dynamic>>(); _error = null; });
    } catch (_) {
      if (mounted) setState(() => _error = 'تعذّر تحميل العملاء. تحقق من الاتصال.');
    }
  }

  Future<void> _select(Map<String, dynamic> c) async {
    setState(() { _selected = c; _invoices = null; _balance = null; });
    try {
      final a = (await Api.rpc('customer_account', {'p_customer_id': c['id']}) as Map).cast<String, dynamic>();
      if (mounted && _selected?['id'] == c['id']) setState(() => _balance = (a['balance_baisa'] as num).toInt());
    } catch (_) {}
    if (c['phone'] == null) {
      setState(() => _invoices = []);
      return;
    }
    try {
      final r = await Api.rpc('list_invoices', {'p_branch_id': null, 'p_from': '2000-01-01', 'p_to': '2100-01-01', 'p_search': c['phone'], 'p_limit': 50});
      if (mounted) setState(() => _invoices = (r as List).cast<Map>().map((m) => m.cast<String, dynamic>()).toList());
    } catch (e) {
      if (mounted) setState(() { _invoices = []; _error = _fail(e); });
    }
  }

  @override
  Widget build(BuildContext context) => _Page(
        title: 'العملاء',
        tools: [SizedBox(width: 320, child: TextField(autofocus: true, decoration: const InputDecoration(hintText: 'بحث بالاسم أو الهاتف', isDense: true), onChanged: _search))],
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(
            width: 380,
            child: _error != null && _customers.isEmpty
                ? _note(_error!, bad: true)
                : ListView(children: [
                    for (final c in _customers)
                      ListTile(
                        selected: _selected?['id'] == c['id'],
                        title: Text('${c['name']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: c['phone'] == null ? null : Text('${c['phone']}', textDirection: TextDirection.ltr),
                        onTap: () => _select(c),
                      ),
                    if (_customers.isEmpty) _note('لا يوجد عملاء مطابقون. أضف العميل من شاشة البيع (F3).'),
                  ]),
          ),
          const VerticalDivider(width: 1, color: Brand.line),
          Expanded(
            child: _selected == null
                ? _note('اختر عميلًا لعرض فواتيره.')
                : _invoices == null
                    ? const Center(child: CircularProgressIndicator())
                    : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Padding(
                          padding: const EdgeInsets.all(14),
                          child: Row(children: [
                            Expanded(child: Text('${_selected!['name']} · ${_selected!['phone'] ?? 'بلا هاتف'}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
                            if (_balance != null)
                              Text('الرصيد الآجل: ${formatOmr(_balance!)} ر.ع',
                                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: _balance! > 0 ? Brand.bad : Brand.ok)),
                            if ((_balance ?? 0) > 0 && widget.ctx.sessionId != null) ...[
                              const SizedBox(width: 12),
                              FilledButton(
                                onPressed: () async {
                                  final c = _selected!;
                                  final done = await showDialog<bool>(
                                      context: context,
                                      barrierDismissible: false,
                                      builder: (_) => CollectDialog(sessionId: widget.ctx.sessionId!, customerId: c['id'] as String, customerName: '${c['name']}', balanceBaisa: _balance!));
                                  if (done == true && mounted) await _select(c);
                                },
                                child: const Text('تحصيل'),
                              ),
                            ],
                          ]),
                        ),
                        if ((_balance ?? 0) > 0 && widget.ctx.sessionId == null)
                          const Padding(padding: EdgeInsets.only(right: 14, left: 14, bottom: 8), child: Text('التحصيل يتطلب وردية مفتوحة لحسابك.', style: TextStyle(color: Brand.muted))),
                        _head([('التاريخ', 2), ('الفاتورة', 3), ('اللوحة', 2), ('المبلغ', 2)]),
                        Expanded(
                          child: _invoices!.isEmpty
                              ? _note('لا توجد فواتير لهذا العميل ضمن الفروع المتاحة لك.')
                              : ListView(children: [
                                  for (final r in _invoices!)
                                    Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                      child: Row(children: [
                                        _cell('${r['business_date']}', flex: 2, num: true),
                                        _cell('${r['invoice_no']}${r['status'] == 'voided' ? ' (ملغاة)' : ''}', flex: 3, num: true, bold: true),
                                        _cell('${r['plate'] ?? '—'}', flex: 2),
                                        _cell(formatOmr((r['total_baisa'] as num).toInt()), flex: 2, num: true),
                                      ]),
                                    ),
                                ]),
                        ),
                      ]),
          ),
        ]),
      );
}

/// تحصيل من رصيد العميل الآجل: نقدي (يدخل درج الوردية) أو بطاقة أو تحويل بنكي.
class CollectDialog extends StatefulWidget {
  final String sessionId, customerId, customerName;
  final int balanceBaisa;
  const CollectDialog({super.key, required this.sessionId, required this.customerId, required this.customerName, required this.balanceBaisa});
  @override
  State<CollectDialog> createState() => _CollectState();
}

class _CollectState extends State<CollectDialog> {
  late final _amount = TextEditingController(text: formatOmr(widget.balanceBaisa));
  final _ref = TextEditingController();
  String _method = 'cash';
  String _opId = const Uuid().v4(); // يُعاد استخدامه عند إعادة المحاولة حتى لا يُحصَّل مرتين
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _amount.selection = TextSelection(baseOffset: 0, extentOffset: _amount.text.length);
  }

  @override
  void dispose() {
    _amount.dispose();
    _ref.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final amount = parseOmr(_amount.text);
    if (amount == null || amount <= 0) {
      setState(() => _error = 'أدخل مبلغًا صحيحًا.');
      return;
    }
    if (amount > widget.balanceBaisa) {
      setState(() => _error = 'المبلغ أكبر من الرصيد (${formatOmr(widget.balanceBaisa)}).');
      return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      await Api.rpc('collect_customer_payment', {
        'p_operation_id': _opId, 'p_cash_session_id': widget.sessionId, 'p_customer_id': widget.customerId,
        'p_method': _method, 'p_amount_baisa': amount, 'p_reference': _ref.text.trim().isEmpty ? null : _ref.text.trim(),
      });
      if (mounted) Navigator.pop(context, true);
      return;
    } on BusinessError catch (e) {
      _opId = const Uuid().v4();
      _error = errorMessage(e.code);
    } on NoResponseError {
      _error = 'انقطع الاتصال. اضغط «تحصيل» مجددًا للتحقق؛ لن يُسجَّل المبلغ مرتين.';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('تحصيل من ${widget.customerName}'),
        content: SizedBox(
          width: 440,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('الرصيد الآجل: ${formatOmr(widget.balanceBaisa)} ر.ع', style: const TextStyle(color: Brand.muted)),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: const [ButtonSegment(value: 'cash', label: Text('نقدي')), ButtonSegment(value: 'card', label: Text('بطاقة')), ButtonSegment(value: 'transfer', label: Text('تحويل بنكي'))],
              selected: {_method},
              onSelectionChanged: (s) => setState(() => _method = s.first),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _amount,
              autofocus: true,
              textDirection: TextDirection.ltr,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
              decoration: const InputDecoration(labelText: 'المبلغ المحصَّل (ر.ع)'),
              onSubmitted: (_) => _save(),
            ),
            if (_method != 'cash')
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: TextField(controller: _ref, textDirection: TextDirection.ltr, decoration: const InputDecoration(labelText: 'المرجع (اختياري)'), onSubmitted: (_) => _save()),
              ),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: Brand.bad))),
          ]),
        ),
        actions: [
          OutlinedButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('رجوع (Esc)')),
          FilledButton(onPressed: _busy ? null : _save, child: Text(_busy ? 'جارٍ التسجيل…' : 'تحصيل (Enter)')),
        ],
      );
}

// ───────────────────────── اليومية ─────────────────────────
class DayPage extends StatefulWidget {
  final ShiftContext ctx;
  final VoidCallback onChanged;
  final Future<void> Function() onOpenShift;
  const DayPage({super.key, required this.ctx, required this.onChanged, required this.onOpenShift});
  @override
  State<DayPage> createState() => _DayState();
}

class _DayState extends State<DayPage> {
  Map<String, dynamic>? _s;
  String? _error;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load() async {
    final sid = widget.ctx.sessionId;
    if (sid == null) return;
    try {
      final r = (await Api.rpc('cash_session_summary', {'p_cash_session_id': sid}) as Map).cast<String, dynamic>();
      if (mounted) setState(() { _s = r; _error = null; });
    } catch (e) {
      if (mounted) setState(() => _error = _fail(e));
    }
  }

  Widget _tile(String label, String value, {Color? color}) => Container(
        width: 250,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: Brand.bg, borderRadius: BorderRadius.circular(12)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(color: Brand.muted, fontSize: 14)),
          const SizedBox(height: 6),
          Text(value, textDirection: TextDirection.ltr, style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: color ?? Brand.ink)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final c = widget.ctx;
    final sid = c.sessionId;
    int n(String k) => (_s?[k] as num?)?.toInt() ?? 0;
    return _Page(
      title: 'اليومية — وردية ${c.userName}',
      tools: sid == null
          ? []
          : [
              const Spacer(),
              if (c.permissions.contains('cash.movement'))
                OutlinedButton(
                    onPressed: () async {
                      await showDialog<void>(context: context, barrierDismissible: false, builder: (_) => CashMovementDialog(sessionId: sid));
                      await _load();
                    },
                    child: const Text('مصروف أو قبض نقدي')),
              const SizedBox(width: 8),
              if (c.permissions.contains('cash.close'))
                FilledButton(
                    onPressed: () async {
                      final closed = await showDialog<bool>(context: context, barrierDismissible: false, builder: (_) => CloseShiftDialog(sessionId: sid));
                      if (closed == true) widget.onChanged();
                    },
                    child: const Text('إغلاق الوردية')),
            ],
      child: sid == null
          ? Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(c.canOpenShift ? 'لا توجد وردية مفتوحة لحسابك.' : 'الورديات غير مفعّلة لدور هذا الحساب. يفعّلها المالك من الإعدادات.', style: const TextStyle(fontSize: 18, color: Brand.muted)),
                const SizedBox(height: 14),
                if (c.canOpenShift) FilledButton(onPressed: widget.onOpenShift, child: const Text('فتح وردية')),
              ]),
            )
          : _error != null
              ? _note(_error!, bad: true)
              : _s == null
                  ? const Center(child: CircularProgressIndicator())
                  : SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Wrap(spacing: 12, runSpacing: 12, children: [
                          _tile('مبيعات نقدية', formatOmr(n('cash_sales_baisa'))),
                          _tile('مبيعات بطاقة (خارج الدرج)', formatOmr(n('card_baisa'))),
                          _tile('تحويل بنكي (خارج الدرج)', formatOmr(n('transfer_baisa'))),
                          _tile('آجل (على حساب العملاء)', formatOmr(n('credit_baisa'))),
                          _tile('إجمالي المبيعات', formatOmr(n('total_sales_baisa'))),
                          _tile('عدد الفواتير', '${n('invoice_count')}'),
                        ]),
                        const SizedBox(height: 20),
                        const Text('مطابقة الصندوق', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 10),
                        Wrap(spacing: 12, runSpacing: 12, children: [
                          _tile('الرصيد الافتتاحي', formatOmr(n('opening_cash_baisa'))),
                          _tile('+ مبيعات نقدية', formatOmr(n('cash_sales_baisa'))),
                          _tile('± مصروفات وقبض ومرتجعات', formatOmr(n('cash_other_baisa')), color: n('cash_other_baisa') < 0 ? Brand.bad : null),
                          _tile('المتوقع في الصندوق', formatOmr(n('expected_cash_baisa')), color: Brand.ok),
                        ]),
                        const SizedBox(height: 16),
                        const Text('عند الإغلاق تُدخل المبلغ الفعلي بعد العدّ، ويُسجَّل العجز أو الزيادة بسببه. بعد الإغلاق لا تُقبل فواتير على هذه الوردية.', style: TextStyle(color: Brand.muted)),
                      ]),
                    ),
    );
  }
}

// ───────────────────────── التقارير ─────────────────────────
class ReportsPage extends StatefulWidget {
  final ShiftContext ctx;
  const ReportsPage({super.key, required this.ctx});
  @override
  State<ReportsPage> createState() => _ReportsState();
}

class _ReportsState extends State<ReportsPage> {
  Map<String, dynamic>? _d;
  String? _error;
  int _days = 0; // 0 اليوم، 6 الأسبوع، 29 الشهر

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  String _date(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _load() async {
    final today = DateTime.now().toUtc().add(const Duration(hours: 4)); // مسقط
    try {
      final r = (await Api.rpc('dashboard_summary', {'p_branch_id': widget.ctx.branchId, 'p_from': _date(today.subtract(Duration(days: _days))), 'p_to': _date(today)}) as Map)
          .cast<String, dynamic>();
      if (mounted) setState(() { _d = r; _error = null; });
    } catch (e) {
      if (mounted) setState(() => _error = _fail(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    int n(String k) => (_d?[k] as num?)?.toInt() ?? 0;
    Widget tile(String label, String value) => Container(
          width: 250,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: Brand.bg, borderRadius: BorderRadius.circular(12)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: const TextStyle(color: Brand.muted, fontSize: 14)),
            const SizedBox(height: 6),
            Text(value, textDirection: TextDirection.ltr, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
          ]),
        );
    return _Page(
      title: 'التقارير — ${widget.ctx.branchName}',
      tools: [
        SegmentedButton<int>(
          segments: const [ButtonSegment(value: 0, label: Text('اليوم')), ButtonSegment(value: 6, label: Text('الأسبوع')), ButtonSegment(value: 29, label: Text('الشهر'))],
          selected: {_days},
          onSelectionChanged: (s) {
            setState(() { _days = s.first; _d = null; });
            _load();
          },
        ),
      ],
      child: !widget.ctx.permissions.contains('reports.view')
          ? _note('التقارير متاحة لمدير الفرع والمحاسب والمالك.')
          : _error != null
              ? _note(_error!, bad: true)
              : _d == null
                  ? const Center(child: CircularProgressIndicator())
                  : SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: Wrap(spacing: 12, runSpacing: 12, children: [
                        tile('المبيعات شاملة الضريبة', formatOmr(n('total_baisa'))),
                        tile('صافي المبيعات بعد المرتجعات', formatOmr(n('net_sales_baisa'))),
                        tile('عدد الفواتير', '${n('invoice_count')}'),
                        tile('نقدي', formatOmr(n('cash_baisa'))),
                        tile('بطاقة', formatOmr(n('card_baisa'))),
                        tile('تحويل بنكي', formatOmr(n('transfer_baisa'))),
                        tile('آجل', formatOmr(n('credit_baisa'))),
                        tile('ضريبة القيمة المضافة', formatOmr(n('tax_baisa'))),
                        tile('المرتجعات', formatOmr(n('refunds_baisa'))),
                        tile('الخصومات', formatOmr(n('discount_baisa'))),
                        tile('مجمل الربح', _d!['gross_profit_baisa'] == null ? '—' : formatOmr(n('gross_profit_baisa'))),
                      ]),
                    ),
    );
  }
}

// ───────────────────────── الإعدادات ─────────────────────────
class SettingsPage extends StatelessWidget {
  final ShiftContext ctx;
  const SettingsPage({super.key, required this.ctx});
  @override
  Widget build(BuildContext context) {
    Widget row(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(children: [SizedBox(width: 220, child: Text(k, style: const TextStyle(color: Brand.muted, fontSize: 16))), Expanded(child: Text(v, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)))]),
        );
    return _Page(
      title: 'الإعدادات',
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          row('الفرع', ctx.branchName),
          row('الصندوق', '${ctx.deviceName} (${Api.config.deviceCode})'),
          row('المستخدم', ctx.userName),
          row('الضريبة', ctx.tax.enabled ? '${formatQty(ctx.tax.rateBp * 10)}%${ctx.tax.pricesIncludeTax ? ' ضمن السعر' : ' تُضاف على السعر'}' : 'غير مفعّلة'),
          row('الورديات لهذا الحساب', ctx.canOpenShift ? 'مفعّلة' : 'غير مفعّلة — للاطلاع فقط'),
          const SizedBox(height: 14),
          FilledButton(onPressed: () => showDialog<void>(context: context, builder: (_) => const PrinterSettingsDialog()), child: const Text('الطابعة ونوعها (حرارية أو A4)')),
          const SizedBox(height: 18),
          const Text('إعدادات الفرع (من يفتح الورديات، الضريبة، نص الفاتورة) والأصناف والأسعار يضبطها المالك من لوحة الإدارة حاليًا.', style: TextStyle(color: Brand.muted)),
        ]),
      ),
    );
  }
}
