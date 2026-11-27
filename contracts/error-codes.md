# أكواد الأخطاء والحالات (مشتركة بين Flutter والويب والخادم)

دوال RPC ترمي استثناء PostgreSQL بـ `SQLSTATE P0001`، و`message` هو الكود، و`details` نص JSON اختياري.
كل استثناء يعني أن المعاملة أُلغيت كاملة ولم يُحفظ شيء.

| الكود | المعنى | details |
|---|---|---|
| `NOT_AUTHENTICATED` | لا توجد جلسة مستخدم | |
| `FORBIDDEN` | لا صلاحية في هذا الفرع | |
| `NOT_FOUND` | السجل غير موجود أو خارج نطاق الصلاحية (لا نفرّق بينهما عمدًا) | |
| `INVALID_REQUEST` | طلب ناقص أو بصيغة خاطئة | |
| `DEVICE_NOT_FOUND` | الجهاز غير مسجل أو خارج فروع المستخدم | |
| `SESSION_ALREADY_OPEN` | وردية مفتوحة على الجهاز | `session_id`, `mine` |
| `SESSION_NOT_FOUND` / `SESSION_CLOSED` / `SESSION_NOT_YOURS` | حالة الوردية لا تسمح | |
| `BUSINESS_DAY_CLOSED` | اليوم المحاسبي مقفل | |
| `EMPTY_CART` | لا بنود (أو أكثر من 200) | |
| `PRODUCT_NOT_FOUND` | صنف غير موجود أو معطل | `line_no` |
| `INVALID_QUANTITY` | كمية ≤ 0 أو كسرية لصنف يباع بالحبة | `line_no`, `sku` |
| `INVALID_DISCOUNT` | خصم سالب أو أكبر من السطر | `line_no` |
| `DISCOUNT_LIMIT_EXCEEDED` | الخصم يتجاوز حد المستخدم | `line_no`, `max_discount_bp` |
| `INSUFFICIENT_STOCK` | الرصيد لا يكفي عند الاعتماد | `line_no`, `sku`, `name_ar`, `requested`, `available` |
| `PAYMENT_REQUIRED` / `INVALID_PAYMENT` | مدفوعات ناقصة أو غير صالحة | |
| `PAYMENT_MISMATCH` | مجموع المدفوعات ≠ الإجمالي | `total_baisa`, `paid_baisa` |
| `CUSTOMER_NOT_FOUND` / `VEHICLE_NOT_FOUND` | خارج المنشأة أو غير موجود | |
| `OPERATION_MISMATCH` | معرّف العملية مستخدم لطلب مختلف أو مستخدم آخر | |
| `OPERATION_CANCELLED` | المعرّف حُجز كملغى عبر `cancel_operation` | |
| `SHIFT_NOT_ENABLED_FOR_ROLE` | دور المستخدم غير مفعّل لفتح الورديات في إعدادات الفرع | |
| `REASON_REQUIRED` | سبب مكتوب مطلوب (تسوية، قبض/صرف، مرتجع، إلغاء) | |
| `SKU_EXISTS` / `BARCODE_EXISTS` | رمز أو باركود مستخدم لصنف آخر | |
| `INSUFFICIENT_CASH` | صرف يتجاوز نقد الدرج | `drawer_baisa` |
| `REFUND_EXCEEDS_REMAINING` | كمية المرتجع تتجاوز المتبقي | `line_no`, `remaining_qty` |
| `INVOICE_NOT_REFUNDABLE` / `INVOICE_HAS_REFUNDS` | الفاتورة ملغاة / لها مرتجعات فلا تُلغى كاملة | |
| `CLOSE_NOTE_REQUIRED` | إقفال بفرق صندوق بلا سبب مكتوب | `difference_baisa` |
| `ACCOUNT_MAPPING_MISSING` | حساب نظامي غير مهيأ في دليل الحسابات | |
| `JOURNAL_UNBALANCED` | قيد غير متوازن (يُفحص عند نهاية المعاملة) | |
| `IMMUTABLE_RECORD` | محاولة تعديل أو حذف سجل مالي | اسم الجدول |

## ردود `approve_sale` غير الاستثنائية

| `status` | المعنى | ما يفعله العميل |
|---|---|---|
| `approved` | حُفظت الفاتورة. `replayed=true` إذا كان الطلب معادًا | يطبع ويبدأ فاتورة جديدة |
| `price_changed` | سعر بند تغيّر منذ إضافته للسلة. لم يُحفظ شيء | يعرض `changes` ويطلب تأكيد الكاشير ثم يعيد الدفع |
| `total_changed` | إعدادات الضريبة تغيّرت. لم يُحفظ شيء | يحدّث الإعدادات ويعرض الإجمالي الجديد |

## منع التكرار

- العميل يولّد `operation_id` (UUID) قبل الإرسال ويحفظه مع الحمولة، ويعيد إرسالهما حرفيًا عند المحاولة.
- الخادم يخزن `md5(payload)` والنتيجة في `operation_requests` ضمن معاملة الاعتماد نفسها.
- `get_operation(id)` للاستعلام، و`recent_operations(session)` لاسترجاع عمليات الوردية بعد إعادة التشغيل.
- `cancel_operation(id, session)` قبل التخلي عن عملية غير مؤكدة: يحجز المعرّف، أو يعيد الفاتورة إن كانت اعتُمدت.

عينات حقيقية (مولّدة من قاعدة الاختبار بـ `tests/tools/gen_samples.mjs`) في `contracts/samples/`.
