# مصفوفة الصلاحيات (المرحلة 1)

المصدر: جدولا `role_permissions` و`memberships`. العضوية بلا فرع = كل فروع المنشأة.

| الصلاحية | المالك | مدير الفرع | المحاسب | الكاشير |
|---|:-:|:-:|:-:|:-:|
| `pos.sell` اعتماد البيع | ✓ | ✓ | | ✓ |
| `pos.discount` خصم ضمن `max_discount_bp` | ✓ | ✓ | | |
| `cash.open` / `cash.close` / `cash.movement` | ✓ | ✓ | | ✓ |
| `cash.close.any` إقفال وردية موظف آخر | ✓ | ✓ | | |
| `invoice.view` / `invoice.reprint` | ✓ | ✓ | عرض فقط | ✓ |
| `invoice.adjust` تصحيح | ✓ | ✓ | ✓ | |
| `invoice.void` / `invoice.refund` / `draft.delete` | ✓ | ✓ | | |
| `catalog.view` / `inventory.view` | ✓ | ✓ | ✓ | ✓ |
| `inventory.cost.view` التكلفة والهوامش | ✓ | ✓ | ✓ | |
| `catalog.manage` | ✓ | | | |
| `inventory.manage` | ✓ | ✓ | | |
| `reports.view` / `reports.export` | ✓ | ✓ | ✓ | |
| `accounting.view` / `accounting.manage` | ✓ | | ✓ | |
| `audit.view` | ✓ | ✓ | ✓ | |
| `users.manage` / `settings.manage` / `notifications.manage` | ✓ | | | |

- النطاق: مدير الفرع والكاشير في فرعهما فقط؛ المحاسب في الفروع المفوّض بها (تجريبيًا كل الفروع).
- الحد المالي المطبّق حاليًا: نسبة الخصم القصوى لكل عضوية. حدود التصحيح والمرتجع تُضاف مع المرحلة 3.
- الواجهات: الكتالوج والمخزون والمشتريات والمرتجع والإلغاء من لوحة الإدارة؛ البيع والمسودات والقبض/الصرف والإقفال من الكاشير.
- صلاحيات لها تعريف ولا واجهة بعد: `invoice.adjust`، `reports.export`، `accounting.manage`، `users.manage`، `settings.manage`، `notifications.manage`.
