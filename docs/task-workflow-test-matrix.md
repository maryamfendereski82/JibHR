# ماتریس آزمون: Migration نسخهٔ نهم (پنج وضعیت)

| | |
|---|---|
| وضعیت | بخش «الف» اجرا شده است، فقط ایستا و فقط‌خواندنی. بقیهٔ بخش‌ها اجرای Migration را لازم دارند و **فقط پس از تأیید جداگانه**، روی یک کپی محلی یک‌بارمصرف از پایگاه داده اجرا می‌شوند، نه روی Local اصلی و نه Remote. |
| ستون «نتیجهٔ مورد انتظار» | خطا یا حالت دقیقی است که SQL تولیدشده برمی‌گرداند. هر کد خطا در [task-workflow-permission-matrix.md](task-workflow-permission-matrix.md) §۶ آمده است. |

## الف. انجام‌شده (۲۰۲۶-۱۱-۱۰، بدون اجرای Migration)

| # | آزمون | ابزار | نتیجه |
|---|---|---|---|
| S1 | تجزیهٔ هر سه SQL و هر بدنهٔ PL/pgSQL (۱۹۳ دستور Migration، ۴۷ بدنه) | `static_check.py` (pglast) | ✓ |
| S2 | Lint امنیتی: `search_path` خالی برای DEFINERها، Revoke برای هر تابع، بدون Grant به anon یا PUBLIC، بدون دست زدن به `profiles` | همان | ✓ |
| S3 | ۱۲۱ ارجاع `public.*` و `app.*` در کاتالوگ زنده (پرس‌وجوی فقط‌خواندنی) | همان | ✓ |
| S4 | ترتیب ساخت: هر تابع `LANGUAGE sql` فقط تابع موجود یا قبلاً ساخته‌شده را صدا می‌زند | همان | ✓ |
| S5 | MD5 هر ۲۷ بدنهٔ Rollback با بدنهٔ زندهٔ امروز برابر است | همان | ✓ |
| S6 | هر Patch روی Dump دقیقاً یک بار (یا تعداد اعلام‌شده) منطبق است | `gen_migration.py` | ✓ |
| S7 | قواعد پنج‌وضعیتی (جدول پایین) | `static_check.py` | ✓ |
| S8 | گزارش پیش از Migration روی دادهٔ واقعی؛ **R7 خالی** | `psql` فقط‌خواندنی | ✓ |
| S9 | `flutter analyze` | Flutter | ✓ بدون Issue |
| S10 | `flutter test` | Flutter | ✓ ۲۴۳ موفق، ۷ Skip (آزمون‌های زنده) |

بررسی‌های خودکار S7:
- `seed_workflow` دقیقاً پنج وضعیت و هفت انتقال می‌سازد.
- هیچ وضعیت بازنشسته‌ای ساخته یا مقایسه نمی‌شود، جز در Plan و خطوط دست‌نخوردهٔ اصلی.
- `decide_task` تأیید را به `approved` می‌برد.
- شروع، ارسال و «انجام شد» فقط با مسئول‌اند.
- `transition_task` کدهای `use_submit`، `use_complete`، `use_decide` و `reopen_backlog_only` را دارد.
- هیچ تابع تغییر وضعیت `tasks.view.all` را نمی‌پذیرد.
- مسئول تصمیم نمی‌گیرد.
- `complete_task` دور، تصمیم یا تأیید نمی‌سازد.
- رفع انسداد به `backlog` می‌رود.
- انتقال اسپرینت و رسیدن مایلستون با `task_is_open` محاسبه می‌شوند.
- حذف عضو با `task_is_unresolved` محاسبه می‌شود.
- هیچ اثری از مدل چهاروضعیتی نمانده است (`'رد نهایی'` به‌عنوان نام وضعیت، `then 'done'`، `key = 'done'`، `category = 'blocked'`).

## ب. Migration و Guard (پس از تأیید؛ کپی یک‌بارمصرف)

| # | سناریو | نتیجهٔ مورد انتظار |
|---|---|---|
| G1 | داده مثل گزارش 2026-11-10 (R7 خالی) | Commit. همهٔ خودآزمایی‌ها (`$retired$`، `$final$`، `$acl$`) عبور می‌کنند. |
| G2 | پیش از اجرا بازبین برای `rgdfdgf` تصمیم بگیرد (دور بسته شود) | `premigration_mismatch` (pinned + integrity) |
| G3 | «کار محلی» دوباره باز یا وضعیت تأییدش عوض شود | `premigration_mismatch` (pinned + plan) |
| G4 | یک تسک `done` با `approval_required` و بدون تصمیم تأیید | `ambiguous_done_approval`، توقف |
| G5 | یک تسک `approved` با `approval_state = 'pending'` | `ambiguous_approved_approval`، توقف |
| G6 | یک تسک `blocked` که قبلش `in_review` بوده | `ambiguous_blocked_previous_unknown`، توقف |
| G7 | یک تسک تازه در `todo` | `premigration_mismatch` (plan) |
| G8 | ساخت Workflow سفارشی | `premigration_mismatch` (custom workflow) |
| G9 | Session دیگری با تراکنش باز | `concurrent_transactions` |
| G10 | پس از Commit | پنج وضعیت فعال با نام‌های نهایی و ترتیب ۱ تا ۵. چهار وضعیت بازنشسته `is_active = false` و حذف‌نشده. هفت انتقال نهایی در هر Workflow پیش‌فرض. هیچ تسکی در وضعیت بازنشسته. |
| G11 | پس از Commit | `ttt` در `backlog`، بدون تغییر دیگر. «کار محلی» در `approved` با همان دور و تصمیم. `rgdfdgf`، `vvvvvvv`، «لندینگ باگ بانتی» و «تست 2» دقیقاً بدون تغییر. `workflow_status_migration_log` دو ردیف دارد و `task.migrated` با `reason = workflow_v9_five_status` ثبت شده. |
| G12 | Plan گزارش و Migration | خروجی R3 با `migration_plan` ردیف‌به‌ردیف برابر است (متن SQL مشترک). |

## ج. مسیرهای جدید (هر ردیف با کاربر واقعی و JWT نقش)

| # | سناریو | نتیجهٔ مورد انتظار |
|---|---|---|
| N1 | مسئول: شروع از «در صف انجام» | ✓ «در حال انجام»؛ `task.transition` و Audit |
| N2 | مدیر پروژه، تأییدکنندهٔ تیم و `tasks.manage.project` (غیرمسئول): شروع | `assignee_only` |
| N3 | فقط `tasks.view.all`: شروع، ارسال، «انجام شد»، تصمیم، بازگشایی | `forbidden` / `assignee_only` / `rejected_closed`؛ هیچ تغییری |
| N4 | مسئول: ارسال از «در حال انجام» (تسک نیازمند تأیید) | ✓ v1 با Snapshot `captured`؛ اعلان به بازبین |
| N5 | ارسال از «در صف انجام» | `invalid_state` |
| N6 | ارسال تسکی که تأیید نمی‌خواهد | `not_required` |
| N7 | مسئول: «انجام شد» (بدون تأیید) | ✓ «تأیید شده». **هیچ** ردیف در `task_review_rounds` یا `task_reviews`؛ `approval_state` بدون تغییر؛ `task.complete` و Audit. |
| N8 | «انجام شد» روی تسک نیازمند تأیید | `approval_required` |
| N9 | «انجام شد» با زیرتسک اجباری ناتمام | `subtasks_incomplete`. با دلیل و `tasks.manage.project` موفق، با `task.override` و Audit. با دلیل و بدون مجوز: `forbidden`. |
| N10 | بازبین واجد شرایط: تأیید | ✓ «تأیید شده»؛ `approval_state = approved` |
| N11 | مسئولی که بازبین اختصاصی یا super admin هم هست: تصمیم روی تسک خودش | `forbidden` |
| N12 | درخواست اصلاح بدون «چه چیزی» یا بدون «چرا» | `what_required` / `reason_required` |
| N13 | درخواست اصلاح کامل | ✓ «در صف انجام» با همان مسئول؛ `approval_state = changes_requested`؛ یک ردیف `task_revision_requests`. سپس شروع و ارسال، v2. v1 و تصمیمش دست‌نخورده. |
| N14 | رد نهایی بدون دلیل، سپس با دلیل | `reason_required`؛ سپس ✓ «رد شده» |
| N15 | بازگشایی رد نهایی با `tasks.manage.project` | ✓ «در صف انجام»؛ `task.reopen` (رویداد و Audit) |
| N16 | بازگشایی به مقصدی جز «در صف انجام» (اگر انتقالش وجود داشته باشد) | `reopen_backlog_only` |
| N17 | دو تصمیم هم‌زمان روی یک دور | یکی موفق؛ دیگری `already_decided` یا `stale_round` |
| N18 | تصمیم با `p_round` قدیمی | `stale_round` |
| N19 | `transition_task` به `in_review`، `approved` یا `rejected`؛ یا خروج از `in_review` | `use_submit`، `use_complete`، `use_decide`، `use_decide` |
| N20 | حین بررسی: `update_task` (عنوان)، `set_task_labels`، `toggle_checklist_item` | `task_in_review` |
| N21 | حین بررسی: تغییر مسئول یا بازبین با مجوز | ✓ با Audit |
| N22 | بازبین حین بررسی: `review_update_task` | ✓ با `task.review_edit` و شناسهٔ دور |

## د. مسدود و گروه «رد شده»

| # | سناریو | نتیجهٔ مورد انتظار |
|---|---|---|
| B1 | مسدود کردن از «در صف انجام» و «در حال انجام» با دلیل | ✓ Flag. وضعیت بدون تغییر. `task_block_events`، `task.block` و Audit ثبت می‌شوند. |
| B2 | مسدود کردن بدون دلیل؛ از «در حال بررسی»، «تأیید شده» یا «رد شده» | `reason_required`؛ `invalid_state` |
| B3 | تسک مسدود: شروع، ارسال، «انجام شد» | `task_blocked` |
| B4 | بازگرداندن به چرخه از «در حال انجام» | ✓ Flag پاک و تسک در «در صف انجام». رویداد با `status_id` و `to_status_id`. `task.unblock` و Audit. دورها و وضعیت تأیید دست‌نخورده. |
| B5 | `task_is_open` / `task_is_unresolved` / `task_counts_complete` | رد نهایی: `false / false / false`؛ مسدود: `false / true / false`؛ تأیید شده: `false / false / true` |
| B6 | `project_sprint_counts` با یک تسک مسدود، یک ردشده و یک باز | `blocked = 1`، `rejected = 1`، `rejected_group = 2`، `remaining = 1` |
| B7 | بستن اسپرینت | `summary.remaining` فقط کار باز را دارد؛ `rejected` و `blocked` جدا |
| B8 | `transfer_sprint_remainder` | فقط کار باز منتقل می‌شود. مسدود و ردشده در اسپرینت قبلی می‌مانند. |
| B9 | رسیدن مایلستونی که فقط تسک مسدود یا ردشده باز دارد | بدون دلیل Override موفق است |
| B10 | `work_analytics` | `rejected`، `blocked` و `rejected_group` (هر تسک یک بار)؛ `remaining` و `overdue` بدون این دو |
| B11 | Home (`dashboard_personal`، `dashboard_summary_v1`) | کارهای باز بدون این دو. `rejected_tasks` و `blocked_tasks` جدا. |
| B12 | حذف عضوی که مسئول یک تسک مسدود است | `member_has_open_tasks`. عضوی که فقط نقش در تسک ردشده دارد حذف می‌شود. |

## ه. Workflow

| # | سناریو | نتیجهٔ مورد انتظار |
|---|---|---|
| W1 | ساخت پروژهٔ جدید | پنج وضعیت (۱ تا ۵) و هفت انتقال؛ هیچ وضعیت بازنشسته‌ای |
| W2 | `save_workflow_status` با دستهٔ `todo`، `changes_requested`، `blocked` یا `done` (جدید یا فعال‌سازی) | `category_retired` |
| W3 | غیرفعال کردن آخرین وضعیت فعال هر یک از پنج دسته | `status_required` |
| W4 | Workflow بدون وضعیت `approved`: «انجام شد» و تأیید | `workflow_incomplete`، بدون تغییر |

## و. امنیت و تغییرناپذیری

| # | سناریو | نتیجهٔ مورد انتظار |
|---|---|---|
| X1 | `anon` روی هر RPC جدید یا تغییرکرده | `permission denied` |
| X2 | `authenticated` یا `service_role` روی هر تابع `app.*` جدید | `permission denied` |
| X3 | `service_role`: INSERT، UPDATE، DELETE یا TRUNCATE روی جدول‌های تاریخی | `permission denied` |
| X4 | مالک: UPDATE یا DELETE روی `task_reviews`، `task_block_events` یا `task_activity_events` | `immutable_row` |
| X5 | خواندن `task_block_events` یا `task_revision_requests` توسط کسی که تسک را نمی‌بیند | صفر ردیف |

## ز. Rollback (کپی یک‌بارمصرف، پس از G1)

| # | سناریو | نتیجهٔ مورد انتظار |
|---|---|---|
| R1 | Rollback بلافاصله پس از Migration | `ttt` به `changes_requested` و «کار محلی» به `done` برمی‌گردند. نام، ترتیب و فعال بودن وضعیت‌ها برمی‌گردد. انتقال‌های افزوده حذف می‌شوند. MD5 هر ۲۷ بدنه برابر است. |
| R2 | پیش از Rollback، «کار محلی» دستی جابه‌جا شود | در فهرست «Kept» با `moved_after_migration`؛ بازگردانده نمی‌شود |
| R3 | پیش از Rollback یک تسک مسدود شود، یک درخواست اصلاح و یک «انجام شد» ثبت شود | Flag، `task_block_events`، `task_revision_requests`، دورها و Snapshotها حذف نمی‌شوند. وضعیت فعلی این تسک‌ها حفظ می‌شود. |
| R4 | پس از Rollback | `scripts/test-db.ps1` نسخهٔ پیش از Migration بدون تغییر عبور می‌کند |
| R5 | Flutter نسخهٔ Migration پس از Rollback | به مسیر قبلی (زنجیرهٔ `transition_task`) برمی‌گردد. هیچ صفحه‌ای خطای `PGRST202` نشان نمی‌دهد (Proposal §10). |

## ح. Regression

| # | حوزه | آزمون |
|---|---|---|
| Q1 | Flutter امروز (پیش از Migration) | `flutter test` کامل؛ پنج ستون؛ رنگ‌های متمایز؛ Badgeهای «مسدود» و «رد نهایی»؛ نقش‌ها (`workflow_presentation_test.dart`، `task_board_test.dart`) |
| Q2 | Flutter پس از Migration | همان آزمون‌ها با مسیرهای جدید، به‌علاوهٔ پیام هر خطای جدید §۶ ماتریس مجوز |
| Q3 | Home، Kanban، List، Calendar، کارهای من، تسک‌های شخصی، اسپرینت، مایلستون، گزارش‌ها، خروجی Excel و PDF | فقط پنج وضعیت؛ هیچ نام بازنشسته‌ای؛ شمارش‌های B6 تا B11 |
| Q4 | Attendance، Leave، Notifications | بدون تغییر. هیچ تابعی از این حوزه‌ها در Migration نیست. اسکریپت آزمون پایگاه داده عبور می‌کند. |
| Q5 | Screenshot پیش و پس | چهار عرض (۳۹۰، ۷۶۸، ۱۰۸۰، ۱۴۴۰) در روشن و تیره، بدون خطای Console یا HTTP |
