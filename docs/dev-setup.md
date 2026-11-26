# إعداد التطوير والتشغيل

## 1) قاعدة البيانات (Supabase)
المشروع السحابي: `lamsat` — المرجع `wqfwuwzcalicwxxhkyhk` — المنطقة `ap-south-1` — الخطة المجانية.

**الحالة (2026-11-27):** الترحيلات الست والبيانات التجريبية مطبّقة على هذا المشروع، ضمن منظمة `lamast`.

لإعادة التطبيق على مشروع جديد: الصق `supabase/phase1_all.sql` في محرر SQL (أو `supabase db push`)، ثم في جلسة واحدة:
```sql
set lamsat.demo_password = 'كلمة-مرور-تجريبية-من-10-أحرف-فأكثر';
-- ثم محتوى supabase/seed/00_dev_users.sql ثم supabase/seed/10_demo_data.sql
```
الحسابات التجريبية: `owner@lamsat.test`، `manager.tires@lamsat.test`، `accountant@lamsat.test`، `cashier.tint@lamsat.test`، `cashier.tires@lamsat.test`. كلمة المرور الحالية في `docs/dev-credentials.local.md` (ملف محلي خارج Git). الأجهزة: `POS-TNT-01`، `POS-TYR-01`، `POS-TYR-02`.

## 2) اختبارات السيناريوهات (لا تحتاج Supabase)
تعمل على PostgreSQL حقيقي يُنزَّل كحزمة npm، مع محاكاة `auth.uid()` والأدوار.
```
cd tests && npm install && npm test
```
يتطلب Node 20+ وحسابًا غير root. لتحديث عينات `contracts/samples`: `node tests/tools/gen_samples.mjs`.

## 3) لوحة الإدارة
```
cd apps/admin-web
copy .env.example .env.local     # ثم ضع الرابط والمفتاح العلني
npm install
npm run dev                      # http://localhost:5173
```
`npm test` لاختبارات الوحدات، و`npm run build` لبناء `dist/` للنشر على أي استضافة ملفات ثابتة.

## 4) تطبيق الكاشير (Windows)
المتطلبات: Flutter stable (3.22+) و Visual Studio مع «Desktop development with C++».
```
cd apps/desktop
flutter create --platforms=windows --project-name lamsat_pos --org om.lamsat .   # مرة واحدة: يولّد مجلد windows
flutter pub get
flutter analyze
flutter test
copy lamsat.config.example.json lamsat.config.json    # الرابط، المفتاح العلني، رمز الجهاز
flutter run -d windows
flutter build windows --release
```
ضع `lamsat.config.json` بجوار `lamsat_pos.exe` على جهاز الكاشير. رمز الجهاز يحدد الفرع والصندوق.
بديل بلا تثبيت Flutter: ادفع المستودع إلى GitHub فيعمل سير العمل `desktop` (في `.github/workflows/`) تلقائيًا ليحلّل ويختبر ويُنتج مجلد الإصدار.

## الأسرار
المستودع لا يحتوي أسرارًا. المفتاح العلني (publishable) مخصص للواجهات ومحمي بـ RLS.
مفتاح الخدمة ومفاتيح مزودي الرسائل تُحفظ في Supabase Edge Function Secrets فقط (المرحلة 4).
