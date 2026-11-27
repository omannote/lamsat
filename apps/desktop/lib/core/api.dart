import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';

/// خطأ عمل معروف أعاده الخادم بكود (مثل INSUFFICIENT_STOCK). لم يُحفظ شيء.
class BusinessError implements Exception {
  final String code;
  final String? detail;
  BusinessError(this.code, [this.detail]);
  @override
  String toString() => 'BusinessError($code)';
}

/// لم يصل رد من الخادم (انقطاع أو مهلة). نتيجة العملية غير معروفة ويجب التحقق منها.
class NoResponseError implements Exception {
  final Object cause;
  NoResponseError(this.cause);
}

class Api {
  static const _timeout = Duration(seconds: 15);
  static late AppConfig config;
  static SupabaseClient get client => Supabase.instance.client;

  /// حالة الاتصال بالخادم؛ تُحدَّث دوريًا. null = لم تُفحص بعد.
  static final ValueNotifier<bool?> online = ValueNotifier<bool?>(null);
  static Timer? _timer;

  static Future<void> init(AppConfig c) async {
    config = c;
    await Supabase.initialize(url: c.supabaseUrl, anonKey: c.publishableKey);
    unawaited(checkConnection());
    _timer ??= Timer.periodic(const Duration(seconds: 5), (_) => checkConnection());
  }

  static Future<bool> checkConnection() async {
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final req = await http.getUrl(Uri.parse('${config.supabaseUrl}/auth/v1/health'));
      req.headers.set('apikey', config.publishableKey);
      final res = await req.close().timeout(const Duration(seconds: 4));
      await res.drain<void>();
      online.value = res.statusCode < 500;
    } catch (_) {
      online.value = false;
    } finally {
      http.close(force: true);
    }
    return online.value ?? false;
  }

  /// يستدعي دالة RPC. يرمي [BusinessError] لأخطاء العمل و[NoResponseError] عند غياب الرد.
  static Future<dynamic> rpc(String fn, [Map<String, dynamic>? params]) async {
    try {
      final r = await client.rpc(fn, params: params).timeout(_timeout);
      online.value = true;
      return r;
    } on PostgrestException catch (e) {
      online.value = true;
      // P0001 = استثناء أطلقته دوالّنا برسالة هي كود الخطأ. غير ذلك خطأ خادم محدد لم يُحفظ معه شيء.
      throw BusinessError(e.code == 'P0001' ? e.message : 'SERVER_ERROR', e.details?.toString());
    } on AuthException {
      throw BusinessError('NOT_AUTHENTICATED');
    } catch (e) {
      online.value = false;
      throw NoResponseError(e);
    }
  }
}

/// رسائل تشغيلية بالعربية لأكواد الأخطاء (انظر contracts/error-codes.md).
String errorMessage(String code) {
  const m = {
    'NOT_AUTHENTICATED': 'انتهت الجلسة. سجّل الدخول من جديد.',
    'FORBIDDEN': 'لا تملك صلاحية تنفيذ هذا الإجراء في هذا الفرع.',
    'DEVICE_NOT_FOUND': 'هذا الجهاز غير مسجّل أو غير مرتبط بفرعك. راجع مدير النظام.',
    'SESSION_ALREADY_OPEN': 'توجد وردية مفتوحة على هذا الجهاز.',
    'SESSION_NOT_FOUND': 'الوردية غير موجودة.',
    'SESSION_CLOSED': 'الوردية مقفلة. افتح وردية جديدة.',
    'SESSION_NOT_YOURS': 'هذه الوردية مفتوحة باسم مستخدم آخر.',
    'BUSINESS_DAY_CLOSED': 'اليوم المحاسبي مقفل. راجع مدير الفرع.',
    'EMPTY_CART': 'السلة فارغة.',
    'PRODUCT_NOT_FOUND': 'صنف في السلة لم يعد متاحًا. احذفه ثم أعد المحاولة.',
    'INVALID_QUANTITY': 'كمية غير صالحة لهذا الصنف.',
    'INVALID_DISCOUNT': 'قيمة الخصم غير صالحة.',
    'DISCOUNT_LIMIT_EXCEEDED': 'الخصم يتجاوز الحد المسموح لك.',
    'INSUFFICIENT_STOCK': 'الكمية المطلوبة غير متوفرة في مخزون الفرع.',
    'PAYMENT_REQUIRED': 'أدخل طريقة الدفع.',
    'PAYMENT_MISMATCH': 'مجموع المدفوعات لا يساوي إجمالي الفاتورة.',
    'INVALID_PAYMENT': 'بيانات الدفع غير صالحة.',
    'CUSTOMER_NOT_FOUND': 'العميل غير موجود.',
    'VEHICLE_NOT_FOUND': 'المركبة غير موجودة.',
    'OPERATION_MISMATCH': 'معرّف العملية مستخدم لطلب مختلف. ابدأ فاتورة جديدة.',
    'INVALID_AMOUNT': 'المبلغ غير صالح.',
    'REASON_REQUIRED': 'اكتب السبب.',
    'INSUFFICIENT_CASH': 'المبلغ أكبر من النقد الموجود في الدرج.',
    'CLOSE_NOTE_REQUIRED': 'يوجد فرق في الصندوق. اكتب سبب الفرق.',
    'ACCOUNT_MAPPING_MISSING': 'حسابات الصندوق غير مهيأة. راجع المحاسب.',
    'OPERATION_CANCELLED': 'أُلغيت هذه المحاولة. أعد الدفع من السلة.',
    'NOT_FOUND': 'السجل غير موجود أو لا تملك صلاحية عرضه.',
    'SERVER_ERROR': 'خطأ في الخادم. لم يُحفظ شيء. أعد المحاولة أو راجع مدير النظام.',
  };
  return m[code] ?? 'تعذّر تنفيذ الإجراء ($code).';
}
