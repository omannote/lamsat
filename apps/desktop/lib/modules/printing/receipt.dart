import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api.dart';
import '../../core/money.dart';

class PrintFailure implements Exception {
  final String message;
  PrintFailure(this.message);
}

class ReceiptPrinter {
  static const _prefKey = 'receipt_printer_name';
  static pw.Font? _regular, _bold;
  static pw.MemoryImage? _logo;

  static Future<String?> savedPrinterName() async => (await SharedPreferences.getInstance()).getString(_prefKey);

  static Future<void> savePrinterName(String? name) async {
    final p = await SharedPreferences.getInstance();
    name == null ? await p.remove(_prefKey) : await p.setString(_prefKey, name);
  }

  static Future<List<Printer>> listPrinters() => Printing.listPrinters();

  static Future<void> _loadAssets() async {
    _regular ??= pw.Font.ttf(await rootBundle.load('assets/fonts/DejaVuSans.ttf'));
    _bold ??= pw.Font.ttf(await rootBundle.load('assets/fonts/DejaVuSans-Bold.ttf'));
    _logo ??= pw.MemoryImage((await rootBundle.load('assets/brand/lamsat-logo-mono.png')).buffer.asUint8List());
  }

  /// يبني إيصال 80مم من تمثيل الفاتورة كما أعاده الخادم (approve_sale / get_invoice).
  static Future<Uint8List> buildPdf(Map<String, dynamic> inv, {bool reprint = false}) async {
    await _loadAssets();
    final doc = pw.Document();
    int n(String k) => (inv[k] as num).toInt();
    final branch = (inv['branch'] as Map).cast<String, dynamic>();
    final org = (inv['organization'] as Map).cast<String, dynamic>();
    final lines = (inv['lines'] as List).cast<Map>();
    final payments = ((inv['payments'] as List?) ?? const []).cast<Map>();
    final customer = inv['customer'] as Map?;
    final vehicle = inv['vehicle'] as Map?;
    final approved = DateTime.parse(inv['approved_at'] as String).toUtc().add(const Duration(hours: 4)); // توقيت مسقط
    String two(int v) => v.toString().padLeft(2, '0');
    final when = '${approved.year}-${two(approved.month)}-${two(approved.day)} ${two(approved.hour)}:${two(approved.minute)}';
    final small = pw.TextStyle(fontSize: 8);
    final strong = pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold);

    pw.Widget row(String label, String value, {pw.TextStyle? style}) => pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [pw.Text(label, style: style ?? small), pw.Text(value, style: style ?? small, textDirection: pw.TextDirection.ltr)],
        );

    doc.addPage(pw.Page(
      pageFormat: const PdfPageFormat(80 * PdfPageFormat.mm, double.infinity, marginAll: 4 * PdfPageFormat.mm),
      textDirection: pw.TextDirection.rtl,
      theme: pw.ThemeData.withFont(base: _regular!, bold: _bold!),
      build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
        pw.Center(child: pw.Image(_logo!, width: 42 * PdfPageFormat.mm)),
        pw.SizedBox(height: 4),
        pw.Center(child: pw.Text((branch['receipt_header_ar'] ?? branch['name_ar']) as String, style: strong)),
        if (branch['phone'] != null) pw.Center(child: pw.Text('هاتف: ${branch['phone']}', style: small)),
        if (org['tax_registration_no'] != null) pw.Center(child: pw.Text('الرقم الضريبي: ${org['tax_registration_no']}', style: small)),
        pw.Divider(thickness: .6),
        row('رقم الفاتورة', inv['invoice_no'] as String, style: strong),
        row('التاريخ', when),
        row('الكاشير', (inv['cashier_name'] ?? '') as String),
        if (customer != null) row('العميل', '${customer['name']}'),
        if (vehicle != null) row('اللوحة', '${vehicle['plate']}'),
        if (reprint) pw.Center(child: pw.Text('— نسخة معادة الطباعة —', style: small)),
        pw.Divider(thickness: .6),
        for (final l in lines) ...[
          pw.Text('${l['description_ar']}', style: pw.TextStyle(fontSize: 9)),
          row('${l['qty']} × ${formatOmr((l['unit_price_baisa'] as num).toInt())}'
              '${(l['discount_baisa'] as num) > 0 ? '  خصم ${formatOmr((l['discount_baisa'] as num).toInt())}' : ''}',
              formatOmr((l['total_baisa'] as num).toInt())),
          pw.SizedBox(height: 2),
        ],
        pw.Divider(thickness: .6),
        if (n('discount_baisa') > 0) row('الخصم', formatOmr(n('discount_baisa'))),
        row('الصافي قبل الضريبة', formatOmr(n('net_baisa'))),
        if (n('tax_baisa') > 0) row('ضريبة القيمة المضافة ${formatQty((inv['tax_rate_bp'] as num).toInt() * 10)}%', formatOmr(n('tax_baisa'))),
        pw.SizedBox(height: 2),
        row('الإجمالي (ر.ع)', formatOmr(n('total_baisa')), style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 2),
        for (final p in payments)
          row(p['method'] == 'cash' ? 'نقدي' : 'بطاقة${p['card_reference'] != null ? ' (${p['card_reference']})' : ''}',
              formatOmr((p['amount_baisa'] as num).toInt())),
        if (n('change_baisa') > 0) row('الباقي', formatOmr(n('change_baisa'))),
        pw.Divider(thickness: .6),
        if (branch['receipt_footer_ar'] != null) pw.Center(child: pw.Text(branch['receipt_footer_ar'] as String, style: small)),
        pw.SizedBox(height: 8),
      ]),
    ));
    return doc.save();
  }

  /// يطبع الإيصال على الطابعة المختارة مباشرةً. يرمي [PrintFailure] برسالة تشغيلية عند الفشل؛
  /// الفاتورة تبقى معتمدة ويمكن إعادة طباعتها.
  static Future<void> printInvoice(Map<String, dynamic> inv, {bool reprint = false}) async {
    final Uint8List bytes;
    try {
      bytes = await buildPdf(inv, reprint: reprint);
    } catch (e) {
      throw PrintFailure('تعذّر تجهيز الإيصال للطباعة.');
    }
    final name = await savedPrinterName();
    if (name == null) throw PrintFailure('لم تُحدَّد طابعة الإيصالات. اخترها من «إعداد الطابعة».');
    final List<Printer> printers;
    try {
      printers = await listPrinters();
    } catch (_) {
      throw PrintFailure('تعذّر قراءة طابعات Windows.');
    }
    final printer = printers.where((p) => p.name == name).firstOrNull;
    if (printer == null) throw PrintFailure('الطابعة «$name» غير موجودة. تأكد من توصيلها وتشغيلها أو اختر طابعة أخرى.');
    bool ok;
    try {
      ok = await Printing.directPrintPdf(printer: printer, onLayout: (_) async => bytes, name: inv['invoice_no'] as String);
    } catch (_) {
      ok = false;
    }
    if (!ok) throw PrintFailure('لم تستجب الطابعة «$name». تحقق من الورق والتوصيل ثم أعد الطباعة.');
    // تسجيل الطباعة لا يوقف العمل إن فشل
    try {
      await Api.rpc('record_invoice_print', {'p_invoice_id': inv['id'], 'p_is_reprint': reprint});
    } catch (_) {}
  }

  /// صفحة اختبار قصيرة للطابعة المختارة.
  static Future<void> printTest(Printer printer) async {
    await _loadAssets();
    final doc = pw.Document()
      ..addPage(pw.Page(
        pageFormat: const PdfPageFormat(80 * PdfPageFormat.mm, double.infinity, marginAll: 4 * PdfPageFormat.mm),
        textDirection: pw.TextDirection.rtl,
        theme: pw.ThemeData.withFont(base: _regular!, bold: _bold!),
        build: (_) => pw.Column(children: [
          pw.Image(_logo!, width: 42 * PdfPageFormat.mm),
          pw.SizedBox(height: 6),
          pw.Text('اختبار طابعة الإيصالات', style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
          pw.Text('0123456789  116.000 ر.ع', style: const pw.TextStyle(fontSize: 9)),
          pw.SizedBox(height: 8),
        ]),
      ));
    final bytes = await doc.save();
    final ok = await Printing.directPrintPdf(printer: printer, onLayout: (_) async => bytes, name: 'lamsat-test');
    if (!ok) throw PrintFailure('لم تستجب الطابعة «${printer.name}».');
  }
}
