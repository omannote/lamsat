import '../../core/money.dart';

class TaxSettings {
  final bool enabled;
  final int rateBp;
  final bool pricesIncludeTax;
  const TaxSettings({required this.enabled, required this.rateBp, required this.pricesIncludeTax});
  int get effectiveRateBp => enabled ? rateBp : 0;
}

class Product {
  final String id, sku, kind, nameAr, unit;
  final String? tireSize;
  final bool wholeUnitsOnly, trackStock, taxable, exactBarcode;
  final int unitPriceBaisa;
  final num? stockQty;
  const Product({
    required this.id, required this.sku, required this.kind, required this.nameAr, required this.unit, this.tireSize,
    required this.wholeUnitsOnly, required this.trackStock, required this.taxable, required this.exactBarcode,
    required this.unitPriceBaisa, this.stockQty,
  });
  Map<String, dynamic> toJson() => {
        'product_id': id, 'sku': sku, 'kind': kind, 'name_ar': nameAr, 'unit': unit, 'tire_size': tireSize,
        'whole_units_only': wholeUnitsOnly, 'track_stock': trackStock, 'taxable': taxable, 'exact_barcode': false,
        'unit_price_baisa': unitPriceBaisa, 'stock_qty': stockQty,
      };

  factory Product.fromJson(Map<String, dynamic> j) => Product(
        id: j['product_id'] as String, sku: j['sku'] as String, kind: j['kind'] as String, nameAr: j['name_ar'] as String,
        unit: j['unit'] as String, tireSize: j['tire_size'] as String?,
        wholeUnitsOnly: j['whole_units_only'] as bool, trackStock: j['track_stock'] as bool, taxable: j['taxable'] as bool,
        exactBarcode: (j['exact_barcode'] as bool?) ?? false,
        unitPriceBaisa: (j['unit_price_baisa'] as num).toInt(), stockQty: j['stock_qty'] as num?,
      );
}

class CartLine {
  final Product product;
  int unitPriceBaisa;
  int qtyMilli;
  int discountBaisa;
  CartLine(this.product, {this.qtyMilli = 1000, this.discountBaisa = 0}) : unitPriceBaisa = product.unitPriceBaisa;

  int get gross => roundDiv(qtyMilli * unitPriceBaisa, 1000);
  int get base => gross - discountBaisa;

  int tax(TaxSettings t) {
    final rate = t.effectiveRateBp;
    if (!product.taxable || rate == 0) return 0;
    return t.pricesIncludeTax ? roundDiv(base * rate, 10000 + rate) : roundDiv(base * rate, 10000);
  }

  /// إجمالي السطر شاملًا الضريبة — بالقاعدة نفسها التي يطبّقها الخادم.
  int total(TaxSettings t) => (t.pricesIncludeTax || !product.taxable) ? base : base + tax(t);
}

class CustomerRef {
  final String id, name;
  final String? phone, vehicleId, plate;
  const CustomerRef({required this.id, required this.name, this.phone, this.vehicleId, this.plate});
}

class Cart {
  final List<CartLine> lines = [];
  CustomerRef? customer;

  bool get isEmpty => lines.isEmpty;

  /// يضيف الصنف أو يزيد كميته إن كان موجودًا. يعيد فهرس السطر.
  int add(Product p) {
    final i = lines.indexWhere((l) => l.product.id == p.id);
    if (i >= 0) {
      lines[i].qtyMilli += 1000;
      return i;
    }
    lines.add(CartLine(p));
    return lines.length - 1;
  }

  void clear() {
    lines.clear();
    customer = null;
  }

  /// لقطة السلة للمسودة. الأسعار تُراجَع من الخادم عند الاعتماد (تأكيد تغيّر السعر).
  Map<String, dynamic> toDraft() => {
        'lines': [
          for (final l in lines)
            {'product': l.product.toJson(), 'qty_milli': l.qtyMilli, 'unit_price_baisa': l.unitPriceBaisa, 'discount_baisa': l.discountBaisa}
        ],
        if (customer != null)
          'customer': {'id': customer!.id, 'name': customer!.name, 'phone': customer!.phone, 'vehicle_id': customer!.vehicleId, 'plate': customer!.plate},
      };

  void loadDraft(Map<String, dynamic> d) {
    clear();
    for (final raw in ((d['lines'] as List?) ?? const [])) {
      final m = (raw as Map).cast<String, dynamic>();
      final line = CartLine(Product.fromJson((m['product'] as Map).cast<String, dynamic>()),
          qtyMilli: (m['qty_milli'] as num).toInt(), discountBaisa: (m['discount_baisa'] as num?)?.toInt() ?? 0);
      line.unitPriceBaisa = (m['unit_price_baisa'] as num?)?.toInt() ?? line.unitPriceBaisa;
      lines.add(line);
    }
    final c = (d['customer'] as Map?)?.cast<String, dynamic>();
    if (c != null) {
      customer = CustomerRef(id: c['id'] as String, name: c['name'] as String, phone: c['phone'] as String?, vehicleId: c['vehicle_id'] as String?, plate: c['plate'] as String?);
    }
  }

  int subtotal() => lines.fold(0, (s, l) => s + l.gross);
  int discount() => lines.fold(0, (s, l) => s + l.discountBaisa);
  int tax(TaxSettings t) => lines.fold(0, (s, l) => s + l.tax(t));
  int total(TaxSettings t) => lines.fold(0, (s, l) => s + l.total(t));

  /// حمولة approve_sale. تُحفظ كما هي ويُعاد إرسالها حرفيًا عند إعادة المحاولة.
  Map<String, dynamic> toPayload({
    required String cashSessionId, required TaxSettings tax, required int cashBaisa, required int cardBaisa,
    int transferBaisa = 0, int creditBaisa = 0, int? cashTenderedBaisa, String? cardReference,
  }) =>
      {
        'cash_session_id': cashSessionId,
        if (customer != null) 'customer_id': customer!.id,
        if (customer?.vehicleId != null) 'vehicle_id': customer!.vehicleId,
        'lines': [
          for (final l in lines)
            {
              'product_id': l.product.id,
              'qty': l.qtyMilli % 1000 == 0 ? l.qtyMilli ~/ 1000 : l.qtyMilli / 1000,
              'unit_price_baisa': l.unitPriceBaisa,
              'discount_baisa': l.discountBaisa,
            }
        ],
        'payments': [
          if (cashBaisa > 0) {'method': 'cash', 'amount_baisa': cashBaisa},
          if (cardBaisa > 0) {'method': 'card', 'amount_baisa': cardBaisa, if ((cardReference ?? '').isNotEmpty) 'card_reference': cardReference},
          if (transferBaisa > 0) {'method': 'transfer', 'amount_baisa': transferBaisa, if ((cardReference ?? '').isNotEmpty) 'card_reference': cardReference},
          if (creditBaisa > 0) {'method': 'credit', 'amount_baisa': creditBaisa},
        ],
        if (cashBaisa > 0) 'cash_tendered_baisa': cashTenderedBaisa ?? cashBaisa,
        'expected_total_baisa': total(tax),
      };
}

/// توزيع الدفع من مدخلات نافذة الدفع. يعيد رسالة خطأ أو التوزيع.
class PaymentSplit {
  final int cash, card, tendered, change, transfer, credit;
  const PaymentSplit(this.cash, this.card, this.tendered, this.change, {this.transfer = 0, this.credit = 0});

  /// البطاقة والتحويل والآجل مبالغ محددة؛ الباقي نقدي، والزائد من النقد المستلم يُرد للعميل.
  static (PaymentSplit?, String?) compute(
      {required int total, required int cardBaisa, required int? tenderedBaisa, int transferBaisa = 0, int creditBaisa = 0}) {
    if (cardBaisa < 0 || transferBaisa < 0 || creditBaisa < 0) return (null, 'المبالغ لا تكون سالبة.');
    final nonCash = cardBaisa + transferBaisa + creditBaisa;
    if (nonCash > total) return (null, 'مجموع البطاقة والتحويل والآجل يجب ألا يتجاوز الإجمالي.');
    final cashDue = total - nonCash;
    if (cashDue == 0) return (PaymentSplit(0, cardBaisa, 0, 0, transfer: transferBaisa, credit: creditBaisa), null);
    final tendered = tenderedBaisa ?? cashDue;
    if (tendered < cashDue) return (null, 'المبلغ النقدي المستلم أقل من المطلوب (${formatOmr(cashDue)}).');
    return (PaymentSplit(cashDue, cardBaisa, tendered, tendered - cashDue, transfer: transferBaisa, credit: creditBaisa), null);
  }
}
