# لمسات — نظام نقاط البيع والمحاسبة

نظام Online-only لمتجر العازل والإكسسوارات ومتجر الإطارات: كاشير Windows (Flutter) + لوحة إدارة ويب (React) + Supabase.

| المسار | المحتوى |
|---|---|
| `apps/desktop` | تطبيق الكاشير Flutter Desktop |
| `apps/admin-web` | لوحة الإدارة React + TypeScript + Vite (RTL) |
| `supabase/migrations` | مخطط PostgreSQL، RLS، دوال RPC |
| `supabase/seed` | مستخدمون وبيانات تجريبية (فرعان) |
| `contracts` | أكواد الأخطاء وعينات الطلبات والردود |
| `tests/scenarios` | اختبارات السيناريوهات على PostgreSQL حقيقي |
| `docs` | المعمارية، الإعداد، دليل الكاشير، الصلاحيات، حالة المراحل |

ابدأ من [`docs/status.md`](docs/status.md) لمعرفة ما يعمل فعليًا وما ينتظر تحققًا، ثم [`docs/dev-setup.md`](docs/dev-setup.md).
