# بستهٔ بازبینی: Migration نسخهٔ نهم گردش‌کار تسک JibHR (پنج وضعیت)

| | |
|---|---|
| برای | بازبینی SQL، Security و داده، پیش از تصمیم دربارهٔ اجرا |
| وضعیت | Draft. **هیچ Migration یا Rollbackی اجرا نشده است.** Local و Remote بدون تغییرند، هیچ داده‌ای دست نخورده و Commit انجام نشده است. اجرا فقط پس از تأیید نهایی جداگانه. |
| تاریخ دادهٔ بازبینی‌شده | 2026-11-10 (گزارش فقط‌خواندنی؛ R7 خالی) |

## ۱. چه چیزی بازبینی می‌شود

| فایل | محتوا |
|---|---|
| [task-workflow-migration-draft.sql](task-workflow-migration-draft.sql) | Migration Draft: ۱۹۳ دستور، یک تراکنش، Guard، خودآزمایی‌ها |
| [task-workflow-rollback-draft.sql](task-workflow-rollback-draft.sql) | Rollback Draft: ۲۷ بدنهٔ اصلی بایت‌به‌بایت با اثبات MD5 |
| [task-workflow-premigration-report.sql](task-workflow-premigration-report.sql) | گزارش فقط‌خواندنی R1 تا R10؛ همان SQL Guard |
| [task-workflow-proposal.md](task-workflow-proposal.md) | Proposal نسخهٔ نهم: تصمیم‌ها، نگاشت، داده، توابع، Rollback، موارد باز |
| [task-workflow.md](task-workflow.md) | مستند گردش‌کار پنج‌وضعیتی (رفتار نهایی) |
| [task-workflow-permission-matrix.md](task-workflow-permission-matrix.md) | ماتریس کامل مجوز و RLS |
| [task-workflow-test-matrix.md](task-workflow-test-matrix.md) | ماتریس آزمون: انجام‌شده، Guard، مسیرهای جدید، Regression |
| [scripts/task-workflow-migration/](../scripts/task-workflow-migration/README.md) | Generatorها و Static Checker. SQLها از Dump زندهٔ توابع بازتولید می‌شوند. |

## ۲. مدل در یک نگاه

```
در صف انجام ──شروع (فقط مسئول)──▶ در حال انجام ──ارسال (فقط مسئول، با تأیید)──▶ در حال بررسی
     ▲  ▲                              │                                         │  │  │
     │  │                              └──انجام شد (فقط مسئول، بدون تأیید)──▶ تأیید شده ◀──تأیید (بازبین، نه مسئول)
     │  └─────────────────────────────── درخواست اصلاح (بازبین؛ چه + چرا) ◀───────┘  │
     │                                                                               ▼
     └──────────── بازگشایی (tasks.manage.project یا super admin) ◀────────────── رد شده
مسدود = Flag روی «در صف انجام» یا «در حال انجام»؛ در ستون «رد شده» با Badge «مسدود»؛ بازگرداندن ← در صف انجام
```

## ۳. اصلاح اصلی نسبت به نسخهٔ هشتم

نسخه‌های قبل `in_progress` را حذف و `done` را حفظ می‌کردند. نسخهٔ نهم:
- `in_progress` و `approved` را فعال نگه می‌دارد.
- `todo`، `changes_requested`، `blocked` و `done` را غیرفعال می‌کند، بدون حذف فیزیکی.
- «کار محلی» را با Guard سازگاری تأیید از `done` به `approved` می‌برد.

فهرست کامل تغییرات در Proposal §۱۴ است. با `static_check.py` کنترل شده که هیچ بخشی از Draft فرض چهار وضعیت را ندارد:
- `seed_workflow` پنج وضعیت و هفت انتقال می‌سازد.
- تأیید به `approved` می‌رود.
- هیچ مقایسهٔ تازه‌ای با وضعیت بازنشسته وجود ندارد.
- `'رد نهایی'` به‌عنوان نام وضعیت، `then 'done'` و `category = 'blocked'` در کد جدید وجود ندارند.

## ۴. داده (فقط‌خواندنی، 2026-11-10)

| تسک | Plan | دلیل |
|---|---|---|
| `ttt` (`f4725489…`) | `changes_requested → backlog` | تأییدشده در بازبینی 2026-11-09 |
| «کار محلی» (`020b27db…`) | `done → approved` | تأیید لازم و `approved`؛ ۱ دور؛ تصمیم `approved`؛ مسیر todo › in_progress › in_review › done |
| `rgdfdgf` (`47d8d5a3…`) | excluded | **وضعیت فعلی:** `in_review`، دور ۱ باز، مسئول غیرعضو |
| `vvvvvvv` (`cf890d3d…`) | excluded | `approved`، تأیید لازم نیست |
| «لندینگ باگ بانتی» (`30445be8…`) | keep (Pin) | در `approved` می‌ماند |

**پس از گزارش نسخهٔ هشتم دو تغییر رخ داده که v9 فقط ثبت و Pin کرده، نه اصلاح:**
- `rgdfdgf` در 2026-11-09 ساعت 17:24 UTC توسط super admin از `backlog` به `in_review` رفت.
- «تست 2» ارسال و توسط خود مسئول تأیید شد.

R9 نشان می‌دهد هر سه تسک تأییدشده را خود مسئول تأیید کرده است.

## ۵. بررسی‌های انجام‌شده (بدون اجرا)

| بررسی | نتیجه |
|---|---|
| `static_check.py`: تجزیهٔ ۱۹۳ دستور و ۴۷ بدنه، Lint امنیتی، ۱۲۱ ارجاع، ترتیب ساخت، MD5 ۲۷ بدنه، قواعد پنج‌وضعیتی | **NO PROBLEMS** |
| گزارش پیش از Migration روی دادهٔ واقعی | **R7 خالی**. R3: دو انتقال و دو استثنا. R8: هیچ تسکی در وضعیت بازنشسته نمی‌ماند. |
| `flutter analyze` | بدون Issue |
| `flutter test` | ۲۴۳ موفق، ۷ Skip (آزمون‌های زنده) |

## ۶. نقاطی که بازبینی دقیق لازم دارند

1. **`complete_task`:**
   - انتقال مستقیم و اتمیک است و دور، تصمیم یا `approval_state = 'approved'` نمی‌سازد.
   - قاعدهٔ زیرتسک و Override مدیریتی دارد.
2. **`transition_task`:** ترتیب بررسی‌ها: مجوز عمومی، `rejected_closed`، `use_decide`، `task_blocked`، انتقال موجود، `status_inactive`، `use_submit`، `use_complete`، `use_decide`، `reopen_backlog_only`، `assignee_only`.
3. **`app.can_decide_task`:** شرط «نه خود مسئول» که روی همهٔ شاخه‌ها، از جمله super admin، اعمال می‌شود.
4. **قفل حین بررسی:** `update_task`، برچسب و چک‌لیست؛ تغییر مسئول یا بازبین همچنان مجاز است.
5. **`clear_task_blocked`:** بازگشت به `backlog` و `to_status_id`.
6. **شمارش‌ها:**
   - `remaining` مستقیم و `rejected_group` با شمارش یک‌باره؛
   - `transfer_sprint_remainder` و `set_milestone_status` با `task_is_open`؛
   - حذف عضو با `task_is_unresolved`.
7. **Guard:** Pin با دورها و تصمیم؛ `approval_ok` مشترک برای `done` و `approved`؛ خودآزمایی‌های `$retired$` و `$final$`.
8. **موارد باز Proposal §۱۱**، به‌خصوص تأیید وضعیت فعلی `rgdfdgf`.

## ۷. تغییر Flutter در همین نسخه

`canReopenRejected` دیگر `tasks.view.all` را نمی‌پذیرد و فقط `tasks.manage.project` دارد، هم‌تراز با v9. یک آزمون واحد اضافه شد. بقیهٔ همسان‌سازی‌ها (`canEditTask`، `canDecideTask`، RPCهای جدید، بازگشت به مسیر قبلی پس از Rollback) کار هم‌زمان با Migration است: Proposal §۱۰.

## ۸. مراحل پس از تأیید نهایی (فقط با مجوز صریح)

1. اجرای دوبارهٔ گزارش فقط‌خواندنی. اگر R7 خالی نیست: توقف، بازبینی، به‌روزرسانی `common.py`، تولید دوباره.
2. آزمون‌های بخش‌های ب تا ز ماتریس آزمون روی کپی یک‌بارمصرف پایگاه داده محلی.
3. Branch جدا برای کار Flutter (Proposal §۱۰).
4. اجرای Migration روی Local با PostgREST متوقف.
5. Regression و Screenshot.
6. Remote فقط با مجوز جداگانه.
