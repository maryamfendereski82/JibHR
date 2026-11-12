# طرح نهایی بک‌اند: Workflow، چرخهٔ بررسی، نسخه‌ها و یکپارچگی تخصیص

| | |
|---|---|
| وضعیت | **Draft نسخهٔ هشتم، برای بازبینی نهایی SQL و Security.** مجوز اجرای Migration هنوز صادر نشده است. بستهٔ بازبینی: [task-workflow-review-package.md](task-workflow-review-package.md). |
| اجرا | هیچ Migration یا Rollbackی اجرا نشده است. هیچ پایگاه داده‌ای تغییر نکرده، هیچ داده‌ای دست نخورده و Commit انجام نشده است. |
| فایل‌ها | [task-workflow-migration-draft.sql](task-workflow-migration-draft.sql) · [task-workflow-rollback-draft.sql](task-workflow-rollback-draft.sql) · [task-workflow-premigration-report.sql](task-workflow-premigration-report.sql) (فقط‌خواندنی) · [task-workflow.md](task-workflow.md) (رفتار نهایی) |
| تولید | [scripts/task-workflow-migration/](../scripts/task-workflow-migration/README.md): Generatorها، Dump توابع و بررسی استاتیک. SQLها را دستی ویرایش نکنید. |

## ۱. تصمیم‌ها

| کد | تصمیم |
|---|---|
| D1 | «در حال انجام» از Workflow فعال خارج می‌شود. |
| D2 | «مسدود» یک Flag است. |
| D3 | Critical خودکار وارد بررسی نمی‌شود. |
| D4 | دایرکتوری محدود اعضا. |
| D5 | عضویت اجباری مسئول، بازبین و همکار. |
| D6 | «در صف انجام». |
| D7 | هیچ وضعیت «انجام‌نشده» یا «شروع‌نشده» وجود ندارد. **نسخهٔ هشتم:** Workflow فعال فقط چهار وضعیت دارد: در صف انجام، در حال بررسی، انجام‌شده، رد نهایی. `todo` و `in_progress` غیرفعال می‌شوند و حذف فیزیکی نمی‌شوند (بخش ۶.۱). |
| G8 | **نسخهٔ هشتم:** گروه «رد شده» = «رد نهایی» + «مسدود»، با دو برچسب جدا و خارج از کارهای باز (بخش ۷.۶). بازگشایی «رد نهایی» فقط به در صف انجام، با Event و Audit (بخش ۷.۷). |
| B1 | درخواست اصلاح دو فیلد الزامی دارد. |
| B2 | ورود به بررسی فقط با Submit. |
| B3 | حذف عضو دارای تسک باز ممنوع است. |
| §9 | تسک شخصی: `created_by` مستقل از مسئول؛ Scope فعلی؛ Audit. |
| `vvvvvvv` | از انتقال مستثنا می‌ماند و Guard وضعیت دقیق آن را کنترل می‌کند (تأییدشده؛ بدون تغییر). |
| `ttt` | **تأییدشده (۹ آبان):** از `changes_requested` به `backlog` منتقل می‌شود. Guard وضعیت فعلی کامل آن و این نگاشت را کنترل می‌کند؛ هر تغییر Migration را متوقف می‌کند. |
| §8.5 | **تأییدشده (۹ آبان):** سخت‌گیری `app.task_visible_directly`؛ همکار حذف‌شده در پروژهٔ restricted دسترسی ندارد؛ تاریخچه حذف نمی‌شود؛ سایر نقش‌ها بدون تغییر. |

## ۲. تغییرات نسخه‌های چهارم تا هشتم

**نسخهٔ هشتم (اصلاح منطق نسخهٔ هفتم):**

| # | قاعده | پیاده‌سازی |
|---|---|---|
| 1 | حذف «انجام‌نشده» (`todo`) و «در حال انجام» (`in_progress`) | از نسخه‌های قبل در SQL بود و بازبینی شد: غیرفعال‌سازی بدون حذف فیزیکی، نگاشت به backlog، `category_retired` برای ساخت و فعال‌سازی، و `app.seed_workflow` چهاروضعیتی. **جدید:** گزارش R8 (وضعیت‌های بازنشسته، تسک‌های فعلی، منتقل‌شده و باقی‌مانده) و بررسی استاتیک «هیچ مقایسهٔ تازه‌ای با `todo` یا `in_progress`». بخش ۶.۱. |
| 2 | `task_is_open` برای مسدود false | `app.task_is_open` = `app.task_is_unresolved` **و** `blocked_at is null`. |
| 3 | حذف عضو با `task_is_open` تنها نه | تابع جدید **`app.task_is_unresolved`** (بایگانی‌نشده، تکمیل‌نشده، غیر rejected؛ مسدود را شامل می‌شود). `app.open_tasks_of_member` و `project_member_open_tasks` از آن استفاده می‌کنند، پس تسک مسدود همچنان مانع حذف است. بررسی استاتیک این را اجبار می‌کند. |
| 4 | Rejected و Blocked جدا، خارج از Remaining | <ul><li>`project_sprint_counts`، `project_milestone_counts` و `set_sprint_status`: «مسدود» = Flag روی کار حل‌نشده؛ `remaining = total - complete - rejected - blocked`.</li><li>`work_analytics`: کلید کلی `blocked` روی کار حل‌نشده (در نسخهٔ هفتم با `task_is_open` محاسبه می‌شد و با قاعدهٔ جدید همیشه صفر می‌شد)؛ ردیف‌های هر اسپرینت و مایلستون اکنون `rejected` و `blocked` دارند و `remaining` بدون آن‌هاست.</li><li>`dashboard_personal`: کلیدهای `rejected_tasks` و `blocked_tasks` برای گروه «رد شده» در Home.</li></ul> |
| 5 | Active و Overdue | همان جایگزینی‌های نسخهٔ هفتم با `app.task_is_open`؛ با تعریف جدید، تسک مسدود هم بیرون است. |
| 6 | بازگشایی «رد نهایی» | `transition_task`: مقصد فقط backlog (`reopen_backlog_only`)؛ Event و Audit `task.reopen` (از، به). بخش ۷.۷. |
| 7 | رفع انسداد | `clear_task_blocked` بدون تغییر رفتار (فقط Flag)؛ توضیح صریح شد که دور، نسخه، وضعیت تأیید و تاریخچه دست نمی‌خورند. |
| 8 | انتقال باقی‌مانده و رسیدن به مایلستون | `app.task_is_unresolved`: تسک مسدود منتقل می‌شود و برای رسیدن به مایلستون دلیل Override می‌خواهد. ردشده نه. **نکتهٔ بازبینی ۱.** |

**دو اشکال نسخهٔ هفتم که در این نسخه رفع شد:**
1. `app.open_tasks_of_member` (تابع `LANGUAGE sql`) پیش از `app.task_is_open` ساخته می‌شد. بدنهٔ تابع SQL هنگام CREATE اعتبارسنجی می‌شود، پس Migration در همان دستور متوقف می‌شد. اکنون `task_is_unresolved` و `task_is_open` پیش از آن ساخته می‌شوند. بررسی استاتیک جدید «ترتیب ساخت» این را برای هر ۱۱ تابع SQL کنترل می‌کند و روی ترتیب نسخهٔ هفتم خطا می‌دهد (آزمون منفی انجام شد).
2. ردیف‌های اسپرینت و مایلستون در `work_analytics` (و بنابراین خروجی گزارش اسپرینت و مایلستون) `remaining = total - complete` را حساب می‌کردند و ردشده را باقی‌مانده می‌شمردند.

**نسخهٔ هفتم (دو تصمیم نهایی ۹ آبان):**

| # | تصمیم | پیاده‌سازی |
|---|---|---|
| 1 | «رد نهایی» برای کار بسته است، اما تکمیل موفق نیست | <ul><li>`app.task_counts_complete` **بدون تغییر** است و برای «رد نهایی» false برمی‌گرداند.</li><li>منطق مستقل جدید `app.task_is_open` = بایگانی‌نشده و تکمیل‌نشده و دستهٔ آن rejected نیست.</li><li>جاهای استفاده و جزئیات در بخش ۷.۶.</li></ul> |
| 2 | افزودن همکار | فقط مسئول اصلی، مدیر عضو همان پروژه، `tasks.manage.project` یا super admin. همکار باید عضو فعال باشد. `projects.view.all` یا سازنده بودن کافی نیست. برای تسک شخصی ممنوع است. افزودن بی‌اثر Event، Audit و اعلان ندارد. تغییر واقعی Event `task.collaborator` و Audit `task.collaborator_add` دارد (بخش ۸.۶). |

**نسخهٔ ششم (پاسخ بازبینی نسخهٔ پنجم):**

| # | تغییر |
|---|---|
| 1 | **قفل Migration (بخش ۱۱.۳):** <ul><li>`tasks`، `task_review_rounds`، `task_reviews`، **`task_collaborators`**، `project_members`، `workflow_statuses`، `workflow_transitions`، `workflows`، `task_labels`، `task_checklist_items` و `task_activity_events` در حالت **EXCLUSIVE** قفل می‌شوند؛ این حالت هر نوشتن و هر قفل ردیفی را متوقف می‌کند و خواندن ساده را آزاد می‌گذارد.</li><li>**`profiles`** و `projects` در حالت SHARE ROW EXCLUSIVE قفل می‌شوند.</li><li>سطح ایزولاسیون باید Read Committed باشد (`migration_isolation`).</li><li>هیچ جلسهٔ کلاینت دیگری نباید تراکنش باز یا تراکنش آماده (prepared) داشته باشد (`concurrent_transactions`).</li><li>پیش‌شرط: توقف API در بازهٔ Migration.</li></ul> |
| 2 | **وضعیت ثابت‌شده:** به ستون‌ها `project_id`، `project_name`، `workflow_id`، `status_id` و `workspace_id` اضافه شد (۱۵ ستون). `rgdfdgf` باید دقیقاً در پروژهٔ `c4fa2aef…` با نام «باگ بانتی» و Workflow `92986332…` باشد. Guard و R5/R7 همین SQL را دارند. |
| 3 | **ترتیب Snapshot:** <ul><li>`add_task_collaborator` و `remove_task_collaborator` و هر شش نویسندهٔ محتوای تسک (`set_task_labels`، `add_checklist_item`، `toggle_checklist_item`، `rename_checklist_item`، `delete_checklist_item`، `move_checklist_item`) اول ردیف Task را `FOR UPDATE` قفل می‌کنند (ترتیب: تسک، سپس آیتم)؛ همان ترتیب `submit`، `review_update` و `decide`.</li><li>`create_task` والد را `FOR SHARE` قفل می‌کند.</li><li>`decide_task` (تأیید) و `transition_task` (رفتن به done) پیش از بررسی زیرتسک‌ها، زیرتسک‌های اجباری را `FOR SHARE` قفل می‌کنند.</li></ul> |
| 4 | **Override:** فقط `tasks.manage.project` یا super admin، در هر دو مسیر `decide_task` و `transition_task` (بخش ۷.۵). |
| 5 | **حذف همکار:** خود همکار، `tasks.manage.project`، مدیر عضو پروژه یا super admin. DELETE بدون اثر، Event و Audit ثبت نمی‌کند. سیاست افزودن در بخش ۸.۶ آمده است. |
| 6 | **توابع کمکی:** بدنهٔ واقعی `app.task_children_block_done` و `app.task_counts_complete` در بستهٔ بازبینی. «رد نهایی» از نظر `task_counts_complete` **تکمیل‌نشده** است (بخش ۷.۶). |
| 7 | **مستند TRUNCATE:** ادعای محافظت مطلق اصلاح شد (بخش ۸.۷). `service_role` روی هر پنج جدول تاریخی فقط SELECT دارد. |


**نسخهٔ پنجم:** دو تصمیم بالا ثبت شد. Guard (c) و R5/R7 اکنون وضعیت کامل **چهار تسک ثابت‌شده** را مقایسه می‌کنند: دو تسک مستثنا و دو تسکی که منتقل می‌شوند (`ttt` و «لندینگ باگ بانتی»)، با ۱۰ ستون: عنوان، شخصی بودن، وضعیت، approval_state، approval_required، مسئول، سازنده، بازبین، بایگانی‌نبودن، شناسه.

**نسخهٔ چهارم (پاسخ بازبینی):**

| بند | تغییر |
|---|---|
| A | در `decide_task`، تأیید همان قاعدهٔ `app.task_children_block_done` را اجرا می‌کند. بدون Override: `subtasks_incomplete`. Override فقط برای `tasks.manage.project` یا `tasks.view.all`، با `p_override_reason` مستقل از `p_reason`. Audit `task.override_subtasks` و رویداد `task.override` همان مسیر `transition_task` را دارند. رویداد `task.subtask_done` برای والد هم ثبت می‌شود. |
| B | `remove_project_member` نقش‌های **مسئول، بازبین اختصاصی و همکار** را در تسک‌های باز بررسی می‌کند. DETAIL شامل `by_role` و نقش هر تسک است. `project_member_open_tasks` فهرست کامل را با نقش‌ها می‌دهد. `app.can_decide_task` عضویت فعال بازبین اختصاصی تسک پروژه‌ای را می‌خواهد. Audit برای تغییر مسئول پروژه (`task.reassign`)، تغییر بازبین (`task.reviewer_change`) و حذف همکار (`task.collaborator_remove`، در `remove_task_collaborator`). **سخت‌گیری روی دسترسی:** `app.task_visible_directly` (بخش ۸.۵). |
| C | `review_update_task` و `decide_task` روی تسک مسدود `task_blocked` می‌دهند. پس از `clear_task_blocked` همان دور و همان نسخه ادامه پیدا می‌کند و Status تغییر نمی‌کند. |
| D | `id` به مقایسهٔ `app.protect_review_round` اضافه شد (`round_immutable`). |
| E | جدول‌های تاریخی جدید برای `authenticated` و `service_role` فقط SELECT دارند. از سه جدول تاریخی موجود، TRUNCATE، TRIGGER و REFERENCES از `service_role` و بقیه گرفته شد. پنج Trigger `BEFORE TRUNCATE` برای همهٔ نقش‌ها، حتی مالک، اضافه شد. خودآزمایی پیش از Commit همهٔ این‌ها را با `has_table_privilege` بررسی می‌کند. |
| F | **Rollback:** تسک مسدود فقط وقتی برمی‌گردد که همان Flag Migration دست‌نخورده باشد (زمان دقیق ثبت‌شده در Log، `blocked_by` تهی، همان دلیل). Event رفع انسداد فقط در همان حالت ثبت می‌شود. انتقال اضافه‌شده فقط وقتی حذف می‌شود که ردیف با همان شناسه و همان مقادیر هنوز وجود داشته باشد. گزارش در سه بخش است: بازگردانده‌شده، حفظ‌شده با دلیل، و حفظ‌شده به حکم سیاست. |
| G | R7 اکنون وضعیت دقیق دو تسک استثنا را با **همان SQL و همان ستون‌های** Guard (c) مقایسه می‌کند. |
| H | قاعدهٔ بازگشایی «رد نهایی» در [task-workflow.md](task-workflow.md) با منطق واقعی `transition_task` یکسان شد. |
| I | ماتریس آزمون به‌روز شد (بخش ۱۳). |

## ۳. Pre-migration Report: انتظار در برابر وضعیت واقعی

اسکریپت دوباره در `begin transaction read only … rollback` روی پایگاه دادهٔ Local اجرا شد.

| بخش | وضعیت واقعی | انتظار Guard | نتیجه |
|---|---|---|---|
| R1 طبقه‌بندی | ۵ Workflow، همه default | همین ۵ شناسه، بدون Workflow سفارشی | برابر |
| R3 Plan | `ttt`: **changes_requested** → backlog · «لندینگ باگ بانتی»: approved → done · `rgdfdgf` و `vvvvvvv`: excluded | همین ۴ ردیف | برابر (پس از به‌روزرسانی، پایین) |
| R4 Integrity | `assignee_not_member`: rgdfdgf · `personal_created_for_other`: vvvvvvv | همین دو ردیف | برابر |
| R5 وضعیت تسک‌های ثابت‌شده | vvvvvvv: شخصی، approved، not_required، approval=false، reviewer = مسئول · rgdfdgf: پروژه‌ای، backlog، pending، approval=true · **ttt: شخصی، changes_requested، not_required، approval=false، مسئول = سازنده** · **لندینگ باگ بانتی: شخصی، approved، approved، approval=true، مسئول = سازنده** · همه بایگانی‌نشده | ستون به ستون | برابر |
| R7 | **خالی**؛ شامل workflow، plan، **pinned_state** (۴ تسک) و integrity | خالی | برابر |
| R8 (نسخهٔ هشتم) | در هر ۵ Workflow، `todo` و `in_progress` **۰ تسک** دارند. در «شخصی»: approved = ۲ (یکی منتقل، `vvvvvvv` مستثنا)، changes_requested = ۱ (`ttt`، منتقل). پس از Migration تنها تسکی که در وضعیت بازنشسته می‌ماند `vvvvvvv` است. | — | گزارشی؛ Guard همان Plan را اجبار می‌کند |

**یک تغییر واقعی در داده، که Guard آن را گرفت:**
- `ttt` (`f4725489…`) در گزارش ۸ آبان در `todo` بود.
- اجرای امروز R7 تفاوت را نشان داد.
- طبق `task_activity_events`، مسئول خود تسک در ۹ آبان آن را از برنامه جابه‌جا کرده است: todo → in_progress → in_review → changes_requested. تسک نیاز به تأیید ندارد و Workflow قدیمی این را اجازه می‌دهد.
- نگاشت آن همچنان قطعی است (changes_requested → backlog). ردیف انتظار در `common.py` به‌روز و علت آن در کد ثبت شد.
- **این ردیف در بازبینی ۹ آبان تأیید شد.**
- اگر پیش از اجرا داده دوباره تغییر کند، Guard اجرا را متوقف می‌کند (همان رفتار مطلوب).

## ۴. Review Version و تصمیم

### امضای جدید

`decide_task(p_task, p_decision, p_round, p_reason, p_what, p_changes, p_override_reason)`. `p_round` پیش‌فرض ندارد و NULL پذیرفته نمی‌شود.

### ترتیب اعتبارسنجی، همه زیر قفل

1. `FOR UPDATE` روی تسک.
2. مجوز: `can_view_task` و `can_decide_task`. بازبین اختصاصی تسک پروژه‌ای باید عضو فعال باشد.
3. دور باز `FOR UPDATE`. اگر `p_round` دور باز نباشد: `stale_round`.
4. دسته `in_review`، `approval_state = pending` (وگرنه `invalid_state`)، و **مسدود نبودن** (وگرنه `task_blocked`).
5. **تأیید:** قاعدهٔ زیرتسک اجباری. Override فقط مدیر و با دلیل مستقل.
6. وضعیت مقصد باید در Workflow باشد (وگرنه `workflow_incomplete`).
7. اعمال ویرایش‌های بازبین (`p_changes`).
8. درج تصمیم؛ قید یکتای `round_id` (بازنده: `already_decided`، و کل Transaction برمی‌گردد).
9. درخواست اصلاح، Override، Status، اعلان‌های فعلی، Event و Audit.

### نسخه‌های قدیمی

`snapshot_status = 'unavailable'`، بدون Snapshot و بدون نام امروز. قیدهای CHECK همین را اجبار می‌کنند.

## ۵. Guard

Guard این‌ها را **ردیف به ردیف** مقایسه می‌کند:
- (a) Workflowها
- (b) Plan: شناسه، مبدأ، مقصد، تصمیم
- (c) وضعیت دقیق چهار تسک ثابت‌شده (دو مستثنا و دو منتقل‌شونده)، از همان SQL که R5 و R7 را می‌سازد
- (d) یافته‌های Integrity

موارد مبهم (مسدود بدون Event قابل بازیابی، in_review بدون دور، approved بدون تأیید) و Workflow سفارشی اجرا را متوقف می‌کنند.

## ۶. Workflow سفارشی

بدون تغییر نسبت به نسخهٔ سوم:
- Migration آن را تغییر نمی‌دهد و Guard اجرا را متوقف می‌کند.
- قواعد B2 و عضویت و مسدود برای همهٔ Workflowها برقرار است.
- Workflow ناقص `workflow_incomplete` می‌دهد و هیچ تغییر نیمه‌کاره‌ای نمی‌ماند.

### ۶.۱ وضعیت‌های بازنشسته: «انجام‌نشده» (`todo`) و «در حال انجام» (`in_progress`)

Workflow فعال پس از Migration فقط چهار وضعیت دارد: **در صف انجام** (۱)، **در حال بررسی** (۲)، **انجام‌شده** (۳)، **رد نهایی** (۴). «نیازمند اصلاح» تصمیم است و «مسدود» Flag.

| الزام | پیاده‌سازی در Draft |
|---|---|
| هیچ ستون یا Status فعال «انجام‌نشده» نباشد | بخش ۶ Migration: `is_active = s.key not in ('todo', 'in_progress', 'blocked', 'changes_requested', 'approved')` در هر ۵ Workflow پیش‌فرض؛ قبل و بعد در `workflow_status_changes` ثبت می‌شود. Kanban فقط وضعیت‌های فعال را ستون می‌کند. |
| ساخت یا فعال‌سازی دوباره ممکن نباشد | `save_workflow_status`: `category_retired` برای ساخت، تغییر دسته به آن‌ها، یا روشن کردن وضعیت غیرفعال بازنشسته. `app.seed_workflow` فقط چهار وضعیت می‌سازد. نوشتن مستقیم روی `workflow_statuses` برای کلاینت سیاست RLS ندارد (فقط `statuses_select`). |
| انتقال تسک‌های `todo` به backlog | Plan: `todo`، `in_progress` و `changes_requested` → `backlog` (`move`). داده امروز: هیچ تسکی در `todo` یا `in_progress` نیست (R8). اگر تا زمان اجرا تسکی وارد آن‌ها شود، ردیف `move` تازه با Plan بازبینی‌شده نمی‌خواند و Guard اجرا را متوقف می‌کند تا آن ردیف بازبینی و به `EXPECTED_PLAN` اضافه شود. |
| تاریخچه و Eventها بازنویسی نشوند | هیچ UPDATE یا DELETE روی Eventها نیست (Trigger تغییرناپذیری هم دارند). هر انتقال یک Event `task.migrated` و ردیف Log جدید می‌سازد. |
| رکورد Status حذف فیزیکی نشود | هیچ DELETE روی `workflow_statuses` نیست. قید CHECK دسته‌ها (`20261105120100_tables.sql`) عمداً `todo` و `in_progress` را معتبر نگه می‌دارد تا ردیف‌های قدیمی معتبر بمانند. |
| انتقال به وضعیت بازنشسته | ردیف‌های قدیمی `workflow_transitions` حذف نمی‌شوند (Rollback به آن‌ها نیاز دارد)، اما `transition_task` مقصد غیرفعال را با `status_inactive` رد می‌کند و کارت Kanban فقط مقصد فعال را نشان می‌دهد. |
| «در صف انجام» تنها وضعیت آغازین | `create_task` (بدون تغییر) همیشه وضعیت با کلید `backlog` را می‌گیرد، و `save_workflow_status` اجازه نمی‌دهد دستهٔ آن عوض شود (`status_required`). درخواست اصلاح و بازگشایی هم به backlog برمی‌گردند. |
- `save_workflow_status` شامل `category_retired` و `status_required` است.

## ۷. توابعی که واقعاً تغییر می‌کنند

### ۷.۱ توابع موجود (بدنهٔ Dump به‌علاوهٔ Patch دقیق؛ ACL بدون تغییر) — ۲۶ تابع

**نسخهٔ هشتم:** تابع موجود تازه‌ای اضافه نشد؛ Patchهای این توابع تغییر کرد:
- `transition_task`: `reopen_backlog_only`، Event و Audit `task.reopen`.
- `transfer_sprint_remainder` و `set_milestone_status`: `app.task_is_unresolved`.
- `project_sprint_counts`، `project_milestone_counts` و `set_sprint_status`: «مسدود» روی کار حل‌نشده؛ `remaining` بدون rejected و blocked.
- `work_analytics`: `blocked` روی کار حل‌نشده؛ `rejected` و `blocked` برای هر اسپرینت و مایلستون.
- `dashboard_personal`: `rejected_tasks` و `blocked_tasks`.

**نسخهٔ هفتم:**
- هفت تابع اضافه شد: `transfer_sprint_remainder`، `set_milestone_status`، `app.dashboard_summary_v1`، `dashboard_projects`، `dashboard_team`، `dashboard_people` و `dashboard_personal`. در آن‌ها فقط عبارت `not app.task_counts_complete(t.id)` با `app.task_is_open(t.id)` جایگزین شد (تعداد هر جایگزینی Assert شده است).
- `project_sprint_counts` و `project_milestone_counts` یک ستون `rejected` گرفتند؛ نوع خروجی تغییر کرد.
- `add_task_collaborator` قاعدهٔ مجوز و خروج بی‌اثر گرفت.

**نسخهٔ ششم:** شش تابع `set_task_labels`، `add_checklist_item`، `toggle_checklist_item`، `rename_checklist_item`، `delete_checklist_item` و `move_checklist_item` فقط قفل ردیف Task گرفتند؛ رفتار دیگرشان تغییر نکرده است. `create_task` (قفل والد)، `transition_task` (قفل زیرتسک‌ها و Override)، `add_task_collaborator` (قفل) و `remove_task_collaborator` (مجوز، قفل، و بدون Event هنگام بی‌اثر بودن) هم به‌روز شدند.

| تابع | ویرایش |
|---|---|
| `public.create_task` | عضویت فعال مسئول و بازبین (پروژه)؛ فعال بودن مسئول و بازبین (شخصی)؛ Event `on_behalf`؛ Audit `task.create_for` |
| `public.update_task` | `invalid_state` برای تغییر سیاست تأیید با دور باز. **مسئول:** عضویت و Audit `task.reassign` (پروژه)؛ Scope و Audit `task.reassign_for` (شخصی). **بازبین:** عضویت یا فعال بودن، و Audit `task.reviewer_change` |
| `public.transition_task` | `use_decide`، `use_submit`، `task_blocked`. دور و اعلان‌های بررسی عیناً به `submit_task_for_review` منتقل شدند. بازگشایی: فقط به backlog (`reopen_backlog_only`)، `pending`، Event و Audit `task.reopen` |
| `public.add_task_collaborator` | عضویت فعال همکار (قفل share روی ردیف عضویت) |
| `public.remove_task_collaborator` | **جدید در این نسخه:** Audit `task.collaborator_remove` (Event از قبل وجود داشت) |
| `public.remove_project_member` | `FOR UPDATE` روی ردیف عضویت؛ `member_has_open_tasks` برای هر سه نقش، با DETAIL `{total, hidden, by_role, tasks[≤50] با roles}` |
| `app.task_visible_directly` | **سخت‌گیرانه، تأییدشده (بخش ۸.۵):** مسیر همکار در پروژهٔ restricted فقط با عضویت فعال؛ ردیف‌های `task_collaborators` حذف نمی‌شوند |
| `public.save_workflow_status` | `category_retired` و `status_required` |
| `app.seed_workflow` | چهار وضعیت و شش انتقال |
| `public.project_sprint_counts`، `public.project_milestone_counts`، `public.set_sprint_status`، `public.work_analytics` | «مسدود» = (`category = 'blocked'` یا `blocked_at is not null`) و `app.task_is_unresolved`؛ ستون یا کلید `rejected`؛ `remaining` بدون rejected و blocked |
| `public.transfer_sprint_remainder`، `public.set_milestone_status` | `app.task_is_unresolved` |
| `app.dashboard_summary_v1`، `dashboard_projects`، `dashboard_team`، `dashboard_people`، `dashboard_personal` | Active و Overdue با `app.task_is_open`؛ `dashboard_personal` به‌علاوهٔ `rejected_tasks` و `blocked_tasks` |

**بررسی‌شده و بدون تغییر:**
- `app.task_counts_complete`، `app.task_children_block_done`، `create_task` (وضعیت آغازین با کلید backlog)، `report_export` (کلیدهای complete؛ ردیف‌های اسپرینت و مایلستون از `work_analytics` می‌آیند).
- «نیازمند اصلاح» (`needs_revision`، `revision`) از `approval_state` خوانده می‌شود و تغییر نکرد. تسکی که هم «نیازمند اصلاح» و هم مسدود باشد در هر دو شمرده می‌شود (**نکتهٔ بازبینی ۳**).

### ۷.۲ جایگزین‌شده

`public.decide_task(uuid, text, text)` حذف می‌شود و `public.decide_task(uuid, text, uuid, text, text, jsonb, text)` جای آن را می‌گیرد. اعلان‌های فعلی عیناً حفظ شده‌اند.

### ۷.۳ RPCهای جدید (DEFINER؛ `search_path = ''`)

`project_member_directory`، `project_member_open_tasks` (اکنون با `roles`)، `submit_task_for_review`، `review_update_task`، `decide_task`، `set_task_blocked`، `clear_task_blocked`.

### ۷.۴ توابع داخلی (INVOKER؛ فقط مالک)

۱۴ تابع کمکی (`app.can_decide_task` با شرط عضویت؛ `app.open_tasks_of_member` با نقش‌ها؛ `app.task_is_unresolved` و `app.task_is_open`) و ۴ تابع Trigger (`app.protect_review_round` با `id`): ۱۸ تابع داخلی.

فهرست تولیدشده: `scripts/task-workflow-migration/changed-functions.txt`.

## ۸. ماتریس مجوز توابع و RLS

### ۸.۱ Default Privileges واقعی

بدون تغییر نسبت به نسخهٔ سوم:
- در `public`، اشیای جدید EXECUTE یا ALL برای `anon` و `authenticated` می‌گیرند.
- در `app`، EXECUTE برای PUBLIC.
- PostgREST فقط `public` را منتشر می‌کند.
- `postgres` Superuser نیست.

**قبل از Migration، `service_role` روی `task_reviews`، `task_review_rounds` و `task_activity_events` مجوزهای TRUNCATE و TRIGGER دارد** (بررسی‌شده با `has_table_privilege`).

### ۸.۲ توابع

| تابع | PUBLIC | anon | authenticated | service_role |
|---|---|---|---|---|
| ۷ RPC جدید | ✗ | ✗ | ✓ | ✓ |
| ۱۱ تابع public تغییرکرده | ✗ | ✗ | ✓ (مثل امروز) | ✓ |
| `app.seed_workflow`، `app.task_visible_directly` | ✗ | ✗ | ✗ | ✓ (مثل امروز) |
| ۱۸ تابع داخلی و Trigger جدید | ✗ | ✗ | ✗ | ✗ |

### ۸.۳ جدول‌ها

| جدول | anon | authenticated | service_role | RLS خواندن | حذف و تغییر |
|---|---|---|---|---|---|
| `task_revision_requests`، `task_block_events` | ✗ | SELECT | **SELECT** | `can_view_task` | فقط RPCها (مالک)؛ UPDATE، DELETE و TRUNCATE با Trigger رد می‌شوند |
| `task_review_rounds`، `task_reviews`، `task_activity_events` | ✗ | مثل امروز | مثل امروز **منهای TRUNCATE، TRIGGER و REFERENCES** | سیاست‌های فعلی | Triggerهای ردیفی و Statement |
| ۵ جدول دفتری | ✗ | ✗ | ✗ | RLS بدون سیاست | فقط Migration و Rollback |
| `profiles` | بدون تغییر | بدون تغییر | بدون تغییر | `profiles_select` بدون تغییر | — |

**ادعای تغییرناپذیری با دسترسی واقعی می‌خواند:**
- هیچ نقش غیرمالک TRUNCATE یا TRIGGER یا REFERENCES روی جدول‌های تاریخی ندارد.
- `service_role` روی جدول‌های تاریخی جدید فقط SELECT دارد.
- Triggerهای `BEFORE TRUNCATE` حتی مالک (postgres، که Superuser نیست) را متوقف می‌کنند.
- فقط حالت replica مخصوص Superuser آن‌ها را دور می‌زند، که منحصر به اسکریپت‌های پاک‌سازی QA محلی است.
- خودآزمایی بخش ۱۲ Migration همهٔ این‌ها را پیش از Commit بررسی می‌کند (`acl_check_failed`).

### ۸.۴ نقش‌ها در RPCها

| Action | مسئول | عضو | بازبین پروژه | مدیر پروژه | تأییدکنندهٔ تیم | `tasks.manage.project` | غیرعضو یا عضو حذف‌شده |
|---|---|---|---|---|---|---|---|
| ارسال برای بررسی | ✓ | ✗ | ✗ | ✓ | ✓ | ✓ | ✗ |
| تصمیم | ✗* | ✗ | ✓ | ✓ | ✓ (شخصی) | ✗* | ✗ (حتی اگر بازبین اختصاصی بوده) |
| Override زیرتسک هنگام تأیید | ✗ | ✗ | ✗ | ✓** | ✗** | ✓ | ✗ |
| ویرایش بازبین (متن، اولویت، مهلت، برچسب) | ✗ | ✗ | ✓ | ✓ | ✓ | — | ✗ |
| ویرایش بازبین (مسئول، همکار) | ✗ | ✗ | ✗ | ✓ | ✗ | ✓ | ✗ |
| مسدود و رفع | ✓ | ✗ | ✗ | ✓ | ✓ | ✓ | ✗ |
| حذف عضو | — | — | — | ✓ (`can_edit_project`) | — | — | ✗ |

\* مگر بازبین واجد شرایط هم باشد.
\*\* Override به `tasks.manage.project` یا `tasks.view.all` نیاز دارد. نقش فعلی مدیر پروژه `tasks.manage.project` دارد.

### ۷.۵ مجوز Override زیرتسک (نسخهٔ ششم)

- **سیاست:** فقط `tasks.manage.project` یا super admin (`app.is_super_admin`). `tasks.view.all` به‌تنهایی کافی نیست.
- **دامنه:** هم `decide_task` (تأیید والد) و هم `transition_task` (رفتن والد به done).
- **تفاوت دسترسی نسبت به امروز:** امروز `transition_task` به دارندهٔ `tasks.view.all` هم اجازهٔ Override می‌دهد.
- **اثر عملی روی نقش‌های فعلی:** هیچ. طبق `role_permissions`، تنها نقش‌های دارای `tasks.view.all` (general_admin و super_admin) `tasks.manage.project` را هم دارند. فقط نقش سفارشی آینده‌ای که `tasks.view.all` را بدون `tasks.manage.project` داشته باشد این امکان را نخواهد داشت.
- اگر سیاست دیگری می‌خواهید، تصمیم صریح لازم است.

### ۷.۶ گروه «رد شده» (رد نهایی + مسدود) و کارهای باز (نسخهٔ هشتم)

سه مفهوم جدا، هر کدام یک تابع:

| تابع | تعریف | تسک ردشده | تسک مسدود |
|---|---|---|---|
| `app.task_counts_complete` (**بدون تغییر**؛ بدنهٔ واقعی در بستهٔ بازبینی) | تکمیل موفق | false | false |
| `app.task_is_unresolved` (جدید) | بایگانی‌نشده، تکمیل‌نشده، دستهٔ آن rejected نیست | false | **true** |
| `app.task_is_open` (بازتعریف) | `task_is_unresolved` و `blocked_at is null` | false | false |

گروه «رد شده» در UI = دستهٔ rejected (برچسب «رد نهایی») + `blocked_at is not null` (برچسب «مسدود»). دو گروه از هم جدا هستند: تسک مسدود فقط در backlog است (`set_task_blocked` در in_review، done، approved و rejected رد می‌شود) و تصمیم «رد» روی تسک مسدود ممکن نیست (`task_blocked`).

| کاربرد | قاعده | تابع |
|---|---|---|
| تکمیل والد (زیرتسک اجباری) | **بدون تغییر:** زیرتسک ردشده یا مسدود ناتمام است؛ Override فقط مدیریتی با دلیل مستقل و Audit (بخش ۷.۵) | `app.task_children_block_done`، `transition_task`، `decide_task` |
| آمار اسپرینت و مایلستون | ستون‌های جدای **`rejected`** و **`blocked`**؛ `remaining = total - complete - rejected - blocked` در خلاصهٔ بستن | `project_sprint_counts`، `project_milestone_counts` (نوع خروجی تغییر کرد: Drop و Create دوباره با همان Grantها)، `set_sprint_status` |
| انتقال باقی‌ماندهٔ اسپرینت | کار حل‌نشده، **مسدود هم**؛ ردشده منتقل نمی‌شود | `transfer_sprint_remainder` |
| رسیدن به مایلستون | کار حل‌نشده، **مسدود هم**، دلیل Override می‌خواهد؛ ردشده مانع نیست | `set_milestone_status` |
| Overdue، Active و Remaining (خانه و گزارش‌ها) | فقط باز برای کار؛ ردشده و مسدود بیرون | `app.dashboard_summary_v1` (۵ مورد)، `dashboard_projects`، `dashboard_team` (۲)، `dashboard_people`، `dashboard_personal` (۲)، `work_analytics` (`remaining` و `overdue`) |
| شمارش جدای دو گروه | `rejected` و `blocked` | `work_analytics` (کلی و برای هر اسپرینت و مایلستون)، `dashboard_personal` (`rejected_tasks`، `blocked_tasks`) |
| حذف عضو (B3) | کار حل‌نشده؛ **`task_is_open` به‌تنهایی استفاده نمی‌شود**؛ تسک مسدود مانع است، ردشده نه | `app.open_tasks_of_member`، `project_member_open_tasks` |
| «تکمیل‌شده» در گزارش و خروجی | بدون تغییر | `report_export`، کلیدهای `complete` |

- هیچ تاریخچه، مسئول یا اطلاعات قبلی تسکی حذف یا بازنویسی نمی‌شود.
- `snapshot.subtasks.required_open` همچنان معنای تکمیل را دارد.
- کار UI هم‌زمان با Migration: بخش ۱۷.

### ۷.۷ بازگشایی «رد نهایی» و رفع انسداد (نسخهٔ هشتم)

| عمل | قاعده |
|---|---|
| بازگشایی | فقط با `transition_task` از rejected به یک وضعیت **backlog**؛ مقصد دیگر: `reopen_backlog_only`. مجوز مثل امروز (`rejected_closed`: `tasks.manage.project` یا `tasks.view.all`، به‌علاوهٔ اجازهٔ جابه‌جایی). `approval_state` برای تسک نیازمند تأیید `pending` می‌شود. **Event `task.reopen` و Audit `task.reopen`** با `from` و `to`، به‌علاوهٔ Event و Audit معمول `task.transition`. دورها، تصمیم‌ها و نسخه‌های قبلی دست نمی‌خورند؛ ارسال بعدی vN+1 است. |
| رفع انسداد | `clear_task_blocked` فقط `blocked_at`، `blocked_reason` و `blocked_by` را پاک می‌کند و رویداد `unblocked` در `task_block_events` ثبت می‌کند. Status تغییر نمی‌کند، پس تسک در همان ستون قبلی است. دور باز، `round_number`، `approval_state` و تاریخچه دست نمی‌خورند (A48). |

**نکتهٔ بازبینی ۲:** مجوز بازگشایی همان مجوز امروز است و `tasks.view.all` را می‌پذیرد. در بخش ۷.۵، Override از `tasks.view.all` گرفته شد. اگر بازگشایی هم باید فقط `tasks.manage.project` یا super admin باشد، تصمیم صریح لازم است؛ Draft آن را تغییر نمی‌دهد.

### ۸.۵ سخت‌گیری در `app.task_visible_directly` — **تأییدشده در بازبینی ۹ آبان**

- این تابع بخشی از مسیر RLS است.
- تغییر: در پروژهٔ restricted، مسیر **همکار** فقط تا زمانی دسترسی می‌دهد که همکار عضو فعال پروژه باشد. **دسترسی گسترش نمی‌یابد، فقط محدود می‌شود.**
- **دلیل:** بند B. حذف عضو تنها با تسک‌های باز مسدود می‌شود. بدون این تغییر، عضو حذف‌شده از راه ردیف‌های همکار روی تسک‌های **بسته** همچنان دسترسی restricted دارد.
- **جایگزین بدون تغییر RLS:** حذف خودکار ردیف‌های همکار تسک‌های بسته هنگام حذف عضو، با Event و Audit. این داده را تغییر می‌دهد و پیشنهاد نمی‌شود.
- مسیر **مسئول** در restricted بدون تغییر می‌ماند: مسئول سابق تسک‌های بستهٔ خودش را می‌بیند. اگر این هم باید محدود شود، تصمیم جداگانه لازم است.

### ۸.۶ مجوز افزودن و حذف همکار (نسخهٔ ششم)

| عمل | چه کسی (سمت سرور) | تغییر نسبت به امروز |
|---|---|---|
| حذف همکار (`remove_task_collaborator`) | خود همکار (کناره‌گیری)، `tasks.manage.project`، مدیر عضو پروژهٔ تسک، یا super admin | **محدودتر:** امروز هر کسی که تسک را می‌بیند می‌تواند هر همکاری را حذف کند |
| افزودن همکار (`add_task_collaborator`) | **تصمیم نهایی:** مسئول اصلی تسک، مدیر عضو همان پروژه، `tasks.manage.project` یا super admin. همکار باید عضو فعال باشد (D5). `projects.view.all` یا سازنده بودن به‌تنهایی کافی نیست. تسک شخصی: `personal_task`. | **محدودتر:** امروز هر کسی که تسک را می‌بیند می‌تواند اضافه کند |
| تغییر همکاران از مسیر ویرایش بازبین (`p_changes`) | `tasks.manage.project`، مدیر پروژه یا super admin، با Audit `task.collaborator_set` در صورت تغییر واقعی | — |

- حذفی که ردیفی پیدا نکند، بدون Event و Audit برمی‌گردد.
- افزودن بی‌اثر (همکار از قبل وجود دارد): بدون اعلان، Event و Audit. افزودن واقعی: Event `task.collaborator` و Audit `task.collaborator_add`.

### ۸.۷ محافظت تاریخچه: مرز اعتماد واقعی

**در برابر نقش‌های API** (`anon`، `authenticated`، `service_role`) محافظت واقعی است:
- این نقش‌ها روی پنج جدول تاریخی فقط SELECT دارند (یا هیچ). INSERT، UPDATE، DELETE، TRUNCATE، TRIGGER و REFERENCES ندارند.
- مالک جدول هم نیستند، پس نمی‌توانند Trigger را غیرفعال کنند یا جدول را تغییر دهند.
- خودآزمایی پیش از Commit این را با `has_table_privilege` بررسی می‌کند.

**در برابر مالک جدول (`postgres`) محافظت مطلق نیست**، با اینکه `postgres` در این پایگاه داده Superuser نیست:
- مالک می‌تواند با `ALTER TABLE … DISABLE TRIGGER USER` (یا `DISABLE TRIGGER <name>`) Triggerهای کاربری را خاموش کند و سپس UPDATE، DELETE یا TRUNCATE اجرا کند. برای Triggerهای کاربری، مالک بودن کافی است.
- `postgres` در این محیط اجازهٔ `session_replication_role = replica` را هم دارد؛ اسکریپت‌های پاک‌سازی QA محلی از همین استفاده می‌کنند. در این حالت Triggerهای معمولی اجرا نمی‌شوند.

پس Triggerها جلوی **اشتباه** و دور زدن تصادفی را می‌گیرند، نه جلوی مالک عمدی. مرز اعتماد، هویت مالک یا DBA یا Migration است. کنترل آن عملیاتی است: محدود نگه داشتن رمز `postgres`، پشتیبان‌گیری، و Audit logهای پایگاه داده. اسکریپت‌های پاک‌سازی QA فقط در محیط محلی چنین دسترسی‌ای دارند.

## ۹. تسک شخصی

بدون تغییر نسبت به نسخهٔ سوم:
- Scope فعلی `create_task`.
- `created_by` مستقل از مسئول.
- Audit `task.create_for` و `task.reassign_for`.
- `assignee_out_of_scope`.
- RLS دیدن بدون تغییر.

## ۱۰. Rollback

| مورد | سیاست |
|---|---|
| Status تسک | فقط اگر هنوز همان مقصد Migration باشد. برای تسکی که از Status «مسدود» آمده، باید **همان Flag Migration** دست‌نخورده باشد: زمان برابر `blocked_at_set`، بدون `blocked_by`، همان دلیل. اگر کاربر رفع انسداد کرده یا دوباره مسدود کرده، با دلیل `unblocked_by_person` یا `flag_changed_by_person` حفظ می‌شود. |
| Event رفع انسداد | فقط وقتی Rollback واقعاً Flag Migration را برمی‌دارد. |
| وضعیت‌ها | فقط اگر ردیف هنوز برابر `after` ثبت‌شده باشد. |
| انتقال‌های اضافه‌شده | فقط اگر ردیف با همان شناسه، همان Workflow، همان مبدأ و همان مقصد هنوز وجود داشته باشد. حذف یا تغییر بعدی مدیر حفظ می‌شود (`removed_after_migration` یا `changed_after_migration`). |
| توابع | **۲۷ بدنهٔ اصلی** (۲۶ تابع تغییرکرده و `decide_task` قدیمی) با بایت‌های اصلی، Grantهای قبلی، و خودآزمایی MD5. `app.task_is_unresolved` و `app.task_is_open` حذف می‌شوند. |
| تاریخچه و محافظت | دورها، Snapshotها، تصمیم‌ها، درخواست‌ها و Eventها **حذف نمی‌شوند**. Triggerهای تغییرناپذیری، Triggerهای TRUNCATE و Revokeهای TRUNCATE، TRIGGER و REFERENCES **می‌مانند**. فقط Constraint Trigger B1 حذف می‌شود. |
| گزارش | سه بخش: Restored، Kept (با دلیل)، Kept by policy. ثبت در `workflow_rollback_runs`. |

### ۱۰.۱ اسکریپت‌های پاک‌سازی QA و تاریخچه

اسکریپت‌های `.local/qa*-clean.sql` با حالت replica حذف می‌کنند و TRUNCATE ندارند (بررسی‌شده). پس با Triggerهای جدید سازگارند، اما همان مسیر مالک را استفاده می‌کنند که در بخش ۸.۷ توضیح داده شد.

## ۱۱. بررسی استاتیک SQL (بدون اجرا)

| بررسی | نتیجه |
|---|---|
| تجزیهٔ دستورها | Migration: ۱۸۸ · Rollback: ۱۲۲ · Report: ۱۲ — **همه تجزیه شدند** |
| بدنه‌های PL/pgSQL | Migration: ۴۴ · Rollback: ۲۸ — **همه تجزیه شدند** |
| ترتیب ساخت (جدید) | هر تابعی که یک تابع `LANGUAGE sql` صدا می‌زند یا زنده است یا پیش‌تر در Migration ساخته شده (۱۱ بدنه). آزمون منفی: ترتیب نسخهٔ هفتم خطا می‌گیرد. |
| وضعیت‌های بازنشسته (جدید) | `app.seed_workflow` هیچ‌یک از پنج دستهٔ بازنشسته را نمی‌سازد. `category_retired` همهٔ پنج دسته را رد می‌کند. بیرون از Plan و طبقه‌بندی Workflow قدیمی، `'todo'` یا `'in_progress'` فقط در خود غیرفعال‌سازی، رد D7، فهرست دسته‌های معتبر `save_workflow_status` و وضعیت مایلستون (`in_progress` مایلستون، نه تسک) می‌آیند. |
| حذف عضو (جدید) | `app.open_tasks_of_member` و `project_member_open_tasks` از `task_is_unresolved` استفاده می‌کنند و `task_is_open` ندارند. |
| `search_path` و Revoke | همهٔ DEFINERها `search_path = ''` دارند. هر تابع جدید Revoke دارد. هیچ Grant عمومی، Grant روی تابع داخلی یا تغییر روی `profiles` وجود ندارد. |
| ارجاع‌ها | ۱۲۰ ارجاع یکتا با Catalog زنده تطبیق داده شد. |
| Placeholder | هیچ |
| Rollback | MD5 هر **۲۷** بدنه با پایگاه دادهٔ زنده برابر است، و تعداد بدنه‌های بازگردانده‌شده با تعداد MD5های بررسی‌شده برابر است. همهٔ توابع جدید حذف می‌شوند، به‌جز توابع Trigger حفظ‌شده. دو تابع شمارش پیش از بازگردانی Drop می‌شوند. |
| Report و Guard | R7 خالی (فقط‌خواندنی)؛ شامل ۱۵ ستون چهار تسک ثابت‌شده. R8: `todo` و `in_progress` در هر ۵ Workflow ۰ تسک دارند. |
| Generator | همهٔ Patchها دقیقاً یک بار منطبق شدند. Python با `-W error::SyntaxWarning` بدون هشدار اجرا شد. |

**محدودیت:** خطای زمان اجرا و رفتار هم‌زمانی فقط با بخش ۱۳ تأیید می‌شود.

## ۱۲. آزمون‌های ایزوله (انجام‌شده، بدون Migration)

| # | آزمون | نتیجه |
|---|---|---|
| I1 | تجزیه | ✓ |
| I2 | Lint امنیتی | ✓ |
| I3 | ارجاع‌ها | ✓ |
| I4 | R7 خالی؛ شامل excluded_state و یک تغییر واقعی دادهٔ کشف‌شده | ✓ |
| I5 | MD5 Rollback | ✓ |
| I6 | Patchهای دقیق | ✓ |
| I7 | آزمون‌های Flutter (۲۲۰) | ✓ |
| I8 | حضور هر بند بازبینی در SQL تولیدشده (جست‌وجوی دقیق متن: Override، `task_blocked` در هر دو مسیر بازبینی، `new.id`، Triggerهای TRUNCATE، Revokeها، نقش همکار، شرط عضویت بازبین، `blocked_at_set`، شرط مقادیر انتقال) | ✓ |

## ۱۳. آزمون‌هایی که اجرای Migration لازم دارند (پس از مجوز)

### Migration و Guard

| # | آزمون |
|---|---|
| M1 | اجرا: Log دو ردیفه، Report چهار ردیفه، خودآزمایی ACL و TRUNCATE قبول |
| M2 | تغییر عمدی یک ستون از وضعیت هر یک از چهار تسک ثابت‌شده (مثلاً Status یا approval_state تسک `ttt`) → `premigration_mismatch`؛ بدون هیچ تغییر |
| M3 | Workflow سفارشی یا مسدود بدون Event → توقف |
| M4 | **مقایسهٔ کامل R7 با Guard:** برای هر ستون Guard (c)، تغییر همان ستون باید هم R7 را غیرخالی کند و هم Guard را متوقف کند (ده ستون × چهار تسک) |
| M5 | **(v8)** دادهٔ آزمون: یک تسک در `todo` → R8 آن را «منتقل‌شده» نشان می‌دهد، R7 یک ردیف `move` اضافه دارد و Guard با `premigration_mismatch` متوقف می‌شود؛ پس از افزودن ردیف به `EXPECTED_PLAN`، Migration آن را به backlog می‌برد و Event `task.migrated` ثبت می‌کند |
| M6 | **(v8)** Migration روی پایگاه دادهٔ تازه (`check_function_bodies = on`) بدون خطای «function does not exist» اجرا می‌شود (ترتیب ساخت) |

### دسترسی

| # | آزمون |
|---|---|
| A1–A38 | مثل نسخهٔ سوم (عضویت، تسک شخصی، دایرکتوری، `use_submit`/`use_decide`، بازبین، مسدود، ACL، `category_retired`، `workflow_incomplete`) |
| A39 | تأیید والد با زیرتسک اجباری ناتمام → `subtasks_incomplete` |
| A40 | Override توسط بازبینی که مدیر نیست (بدون `tasks.manage.project` و `tasks.view.all`) → `forbidden` |
| A41 | Override مدیر با دلیل → تأیید؛ Audit `task.override_subtasks`؛ رویداد `task.override`؛ `p_reason` و `p_override_reason` جدا ثبت می‌شوند |
| A42 | Override بدون دلیل → `subtasks_incomplete` |
| A43 | حذف عضوی که فقط **بازبین اختصاصی** یک تسک باز است → `member_has_open_tasks` با `by_role.reviewer = 1` |
| A44 | حذف عضوی که فقط **همکار** یک تسک باز است → رد با `by_role.collaborator = 1` |
| A45 | جایگزینی بازبین، حذف همکار و تخصیص دوباره → Audit `task.reviewer_change`، `task.collaborator_remove` و `task.reassign`؛ سپس حذف عضو ✓ |
| A46 | بازبین اختصاصی پس از پایان عضویت → تصمیم و ویرایش بازبین `forbidden`. چون `remove_project_member` خودش مانع حذف است، `removed_at` در دادهٔ آزمون با SQL مستقیم گذاشته می‌شود. |
| A47 | عضو حذف‌شده که همکار تسک **بستهٔ** restricted بوده → تسک دیگر قابل دیدن نیست (۰ ردیف) |
| A49 | Override توسط کاربری با `tasks.view.all` بدون `tasks.manage.project` (نقش آزمونی) → `forbidden` در هر دو مسیر |
| A50 | حذف همکار توسط عضو عادی یا مسئول → `forbidden`؛ توسط خود همکار → ✓؛ توسط مدیر پروژه → ✓ |
| A51 | حذف همکاری که وجود ندارد → بدون Event و بدون Audit |
| A52 | `service_role`: INSERT، UPDATE، DELETE یا TRUNCATE روی هر پنج جدول تاریخی → خطای مجوز؛ SELECT → ✓ |
| A54 | تسک ردشدهٔ گذشته از مهلت → در هیچ شمارش Overdue (خانه، تیم، پروژه‌ها، گزارش) نیست؛ در `rejected` اسپرینت و مایلستون هست؛ در `remaining` نیست؛ `task_counts_complete` = false |
| A55 | والد با زیرتسک اجباری ردشده → تکمیل یا تأیید `subtasks_incomplete` (بدون تغییر) |
| A56 | عضوی که فقط در تسک‌های ردشده نقش دارد → حذف ✓؛ تسک، مسئول و تاریخچه بدون تغییر |
| A57 | `transfer_sprint_remainder` → تسک ردشده منتقل نمی‌شود، تسک مسدود منتقل می‌شود؛ `set_milestone_status reached` → تسک ردشده مانع نیست، تسک مسدود دلیل Override می‌خواهد (`tasks_incomplete`) |
| A61 | **(v8)** تسک مسدود گذشته از مهلت → `task_is_open` = false؛ در Overdue و Active هیچ داشبوردی نیست؛ در `blocked` اسپرینت، مایلستون و `work_analytics` هست؛ در `remaining` نیست؛ `task_counts_complete` = false |
| A62 | **(v8)** عضوی که فقط در یک تسک **مسدود** نقش دارد (مسئول، بازبین یا همکار، هر سه جدا) → `member_has_open_tasks` با همان نقش؛ پس از `clear_task_blocked` و جایگزینی → حذف ✓ |
| A63 | **(v8)** `clear_task_blocked` روی تسک مسدود backlog → همان `status_id`؛ `task_is_open` = true؛ `round_number` بیشینه، `approval_state` و تعداد ردیف‌های `task_review_rounds`، `task_reviews` و `task_activity_events` بدون تغییر (فقط یک رویداد `unblocked` اضافه) |
| A64 | **(v8)** والد با زیرتسک اجباری **مسدود** → تکمیل یا تأیید `subtasks_incomplete`؛ Override مدیر با دلیل → ✓ با Audit؛ Override بدون مجوز → `forbidden` |
| A65 | **(v8)** بازگشایی «رد نهایی» به backlog توسط `tasks.manage.project` → ✓؛ یک Event و یک Audit `task.reopen` با `from` و `to`؛ دورها و تصمیم‌های قبلی بدون تغییر؛ ارسال بعدی vN+1 |
| A66 | **(v8)** بازگشایی «رد نهایی» به هر مقصد غیر backlog (با انتقال دستی اضافه‌شده در Workflow سفارشی) → `reopen_backlog_only`؛ توسط مسئول بدون مجوز → `rejected_closed` |
| A67 | **(v8)** `save_workflow_status`: ساخت وضعیت با دستهٔ `todo` یا `in_progress` → `category_retired`؛ روشن کردن وضعیت غیرفعال `todo` → `category_retired`؛ تغییر نام وضعیت غیرفعال بدون روشن کردن → ✓ |
| A68 | **(v8)** پس از Migration: در هر Workflow پیش‌فرض، وضعیت‌های فعال دقیقاً backlog (۱)، in_review (۲)، done (۳)، rejected (۴) هستند؛ ردیف‌های `todo` و `in_progress` هنوز وجود دارند با `is_active = false` و همان نام؛ هیچ ردیف `workflow_statuses` حذف نشده (شمارش قبل و بعد برابر) |
| A69 | **(v8)** `transition_task` به وضعیت غیرفعال `todo` (با ردیف انتقال قدیمی) → `status_inactive` |
| A70 | **(v8)** `dashboard_personal`: `personal_tasks` و `project_tasks` بدون ردشده و مسدود؛ `rejected_tasks` و `blocked_tasks` برابر شمارش مستقیم |
| A71 | **(v8)** `work_analytics`: برای هر اسپرینت و مایلستون `total = complete + rejected + blocked + remaining` |
| A58 | افزودن همکار: مسئول ✓، مدیر پروژه ✓، `tasks.manage.project` ✓، super admin ✓؛ دارندهٔ `projects.view.all` بدون این‌ها ✗؛ سازندهٔ غیرمسئول ✗؛ عضو عادی ✗؛ تسک شخصی → `personal_task`؛ همکار غیرعضو → `collaborator_not_member` |
| A59 | افزودن همکاری که از قبل وجود دارد → بدون اعلان، Event و Audit |
| A60 | `project_sprint_counts` و `project_milestone_counts` پس از Migration همان Grantها را دارند (`authenticated`، `service_role`) و ستون `rejected` برمی‌گردانند؛ پس از Rollback امضا و خروجی اصلی برمی‌گردد |
| A53 | تغییر هر یک از ستون‌های `project_id`، `workflow_id`، `status_id` یا `workspace_id` یکی از چهار تسک ثابت‌شده (یا تغییر نام پروژهٔ «باگ بانتی») → R7 غیرخالی و `premigration_mismatch` |
| A48 | تسک مسدود در in_review: `decide_task` و `review_update_task` → `task_blocked`؛ `clear_task_blocked` → همان دور تصمیم می‌گیرد؛ `round_number` و Status ثابت‌اند |

### هم‌زمانی

| # | سناریو |
|---|---|
| C1–C7 | مثل نسخهٔ سوم |
| C8 | دو تأیید هم‌زمان روی والد با زیرتسک ناتمام، یکی با Override مدیر و یکی بدون → دقیقاً یکی موفق؛ دیگری `subtasks_incomplete` یا `already_decided`؛ Audit Override فقط برای برنده |
| C9 | حذف عضو هم‌زمان با **تخصیص مسئول** به همان عضو → یکی شکست می‌خورد |
| C12 | **تأیید یا تکمیل والد هم‌زمان با بازگشایی زیرتسک اجباری** (زیرتسک رد نهایی → در صف انجام، توسط مدیر): یا والد پیش از بازگشایی تکمیل می‌شود و بازگشایی پس از آن انجام می‌شود، یا بازگشایی اول است و تکمیل والد `subtasks_incomplete` می‌گیرد. هرگز «والد تکمیل‌شده بر اساس وضعیت کهنهٔ زیرتسک» رخ نمی‌دهد. |
| C13 | ساخت زیرتسک اجباری جدید هم‌زمان با تکمیل والد → ترتیبی (قفل share روی والد) |
| C14 | `add_checklist_item`، `set_task_labels` یا `remove_task_collaborator` هم‌زمان با `submit_task_for_review` → Snapshot یا شامل تغییر است یا نیست؛ هرگز نیمه‌کاره نیست. ترتیب قفل یکسان است، پس بن‌بستی رخ نمی‌دهد. |
| C15 | `move_checklist_item` هم‌زمان با `decide_task` → بدون بن‌بست (هر دو اول ردیف Task را قفل می‌کنند) |
| C16 | Migration در حالی که یک جلسهٔ دیگر تراکنش باز دارد → `concurrent_transactions`؛ در حالی که جلسه‌ای ردیفی از `tasks` را قفل کرده → انتظار و سپس `lock_timeout`؛ بدون هیچ تغییر |
| C10 | حذف عضو هم‌زمان با **تغییر بازبین** به همان عضو → یکی شکست می‌خورد |
| C11 | حذف عضو هم‌زمان با **افزودن همکار** همان عضو → یکی شکست می‌خورد؛ هیچ ردیفی برای عضو حذف‌شده نمی‌ماند |

### نسخه‌ها و تغییرناپذیری

| # | آزمون |
|---|---|
| V1–V10 | مثل نسخهٔ سوم |
| V11 | `update task_review_rounds set id = gen_random_uuid()` (حتی با postgres) → `round_immutable` |
| V12 | `truncate` روی هر پنج جدول تاریخی با `service_role` → خطای مجوز؛ با postgres → `immutable_row` (Trigger). سند صریحاً می‌گوید postgres می‌تواند Trigger را غیرفعال کند (بخش ۸.۷)؛ این مورد آزمون «عدم امکان» نیست. |

### Rollback

| # | آزمون |
|---|---|
| R1–R6 | مثل نسخهٔ سوم |
| R7 | دادهٔ آزمون: تسکی در Status «مسدود» با Event قابل بازیابی → Migration (Flag) → کاربر `clear_task_blocked` → Rollback: تسک **برنمی‌گردد** (`unblocked_by_person`)، رویداد «بازگردانی» ثبت نمی‌شود |
| R8 | همان، بدون دخالت کاربر → برمی‌گردد و یک رویداد `unblocked` ثبت می‌شود |
| R9 | انتقال اضافه‌شده‌ای که مدیر پس از Migration حذف کرده یا تغییر داده → حفظ و گزارش با دلیل |
| R10 | گزارش Rollback: بخش‌های Restored و Kept جدا و شمارش‌ها در `workflow_rollback_runs` |

### ۱۱.۳ قفل و تراکنش‌های هم‌زمان در Migration

1. **پیش‌شرط عملیاتی:** API در بازهٔ اجرا متوقف باشد (کانتینر PostgREST محلی). دلیل: فراخوانی تابعی که پیش از Commit شروع شده باشد، با بدنهٔ **قدیمی** ادامه پیدا می‌کند و هیچ قفلی جلوی آن را نمی‌گیرد.
2. `migration_isolation`: فقط Read Committed، تا هر دستور Guard دادهٔ پس از گرفتن قفل‌ها را ببیند.
3. **قفل EXCLUSIVE** روی ۱۱ جدول Task و Workflow:
   - هر تراکنشی که روی این جدول‌ها قفل ردیفی یا نوشتنی دارد، باید پیش از Migration Commit یا Rollback شود؛ وگرنه `lock_timeout` (۵ ثانیه) اجرا را بی‌اثر متوقف می‌کند.
   - پس از گرفتن قفل، هیچ نوشتن یا `SELECT … FOR UPDATE/SHARE` تازه‌ای تا Commit ممکن نیست.
   - **پس Guard تا پایان Migration معتبر می‌ماند.**
4. **قفل SHARE ROW EXCLUSIVE** روی `profiles` و `projects`: تغییر وضعیت یا نام این دو جدول در بازهٔ اجرا ممکن نیست.
5. `concurrent_transactions`: اگر جلسهٔ کلاینت دیگری تراکنش باز داشته باشد (حتی فقط‌خواندنی) یا تراکنش آماده وجود داشته باشد، اجرا متوقف می‌شود.
6. **ترتیب قفل در کد کاربردی** پس از Migration: همیشه ابتدا ردیف Task، سپس آیتم‌ها و ردیف‌های وابسته؛ و برای والد، زیرتسک‌های اجباری با `FOR SHARE`.

## ۱۴. خطاهای جدید

| گروه | خطاها |
|---|---|
| بررسی و Workflow | `use_submit`، `use_decide`، `round_required`، `stale_round`، `invalid_state`، `workflow_incomplete`، `what_required`، `already_submitted`، `not_submitted`، `subtasks_incomplete` (اکنون در تأیید هم)، `reopen_backlog_only` (v8) |
| مسدود | `task_blocked` (اکنون در تصمیم و ویرایش بازبین هم)، `already_blocked`، `not_blocked` |
| اجرای Migration | `migration_isolation`، `concurrent_transactions` |
| تخصیص و عضویت | `assignee_not_member`، `assignee_inactive`، `assignee_out_of_scope`، `reviewer_not_member`، `reviewer_inactive`، `collaborator_not_member`، `member_has_open_tasks` (سه نقش) |
| ویرایش و پیکربندی | `field_forbidden`، `invalid_changes`، `category_retired`، `status_required`، `archived` |
| تغییرناپذیری | `round_immutable`، `immutable_row`، `revision_request_mismatch`، `revision_request_missing` |
| Migration و Rollback | `premigration_mismatch`، `acl_check_failed`، `rollback_body_mismatch` |

## ۱۵. خارج از دامنه

- اعلان جدید.
- گسترش `profiles_select` یا دسترسی دیدن (بخش ۸.۵ فقط محدود می‌کند).
- Permission جدید.
- حذف فیزیکی وضعیت یا تاریخچه.
- تغییر Attendance و Leave.
- تغییر UI، که پس از اجرای Migration هم‌زمان با آن انجام می‌شود.

## ۱۶. تولید

جزئیات در [scripts/task-workflow-migration/README.md](../scripts/task-workflow-migration/README.md):
- `dump_functions.sh`: فقط‌خواندنی.
- `common.py`: انتظارات بازبینی‌شده و SQL مشترک.
- `gen_migration.py`، `gen_report.py` و `gen_rollback.py`.
- `static_check.py`: با `pglast` در یک venv جدا؛ وابستگی پروژه نیست.

## ۱۷. ارجاعات قدیمی `todo` و «انجام‌نشده» و کار UI هم‌زمان با Migration (نسخهٔ هشتم)

همهٔ ارجاعات در `lib/`، `test/`، `supabase/` و `scripts/` جست‌وجو شد. **UI در این Draft تغییر نکرده است.** کلاینت فعلی با پایگاه دادهٔ فعلی (نه‌وضعیتی) کار می‌کند و این تغییرات باید هم‌زمان با اجرای Migration اعمال شوند.

| محل | امروز | پس از Migration |
|---|---|---|
| `lib/features/work/project_pages.dart:46` (`workCategories`) | ۹ دسته، از جمله todo و in_progress | فقط backlog، in_review، done، rejected برای ساخت یا تغییر دسته |
| `lib/features/work/project_pages.dart:926` | دستهٔ پیش‌فرض وضعیت جدید `'todo'` (سرور `category_retired` می‌دهد) | `'backlog'` |
| `lib/features/work/project_pages.dart:1051` (کلید روشن و خاموش وضعیت) | برای وضعیت بازنشسته هم فعال است | برای دسته‌های بازنشسته غیرفعال، با توضیح «بازنشسته» |
| `lib/features/work/work_repository.dart:556` | دستهٔ پیش‌فرض `'todo'` هنگام نبود مقدار | `'backlog'` |
| `lib/features/work/work_repository.dart:339` (`assignedOpen`، کارهای باز Home) | فقط done و approved بیرون است | rejected و `blocked_at is not null` هم بیرون |
| Home (`lib/features/dashboard/`) | گروه «رد شده» ندارد | بخش «رد شده» با `rejected_tasks` و `blocked_tasks` از `dashboard_personal`، فهرست هر دو گروه (rejected یا مسدود، مسئول = من) با برچسب «رد نهایی» و «مسدود»، و پیوند به جزئیات |
| Kanban (`task_board.dart:184`) | ستون‌ها = وضعیت‌های فعال (پس از Migration خودبه‌خود چهار ستون) | کارت مسدود در گروه «رد شده» با برچسب «مسدود» نشان داده می‌شود، نه در ستون Status خودش. پس از `clear_task_blocked` دوباره در همان ستون است. |
| `lib/features/work/plan_repository.dart:20-35، 266` (`PlanCounts`) | `remaining = total - complete` | خواندن `rejected`؛ `remaining = total - complete - rejected - blocked` |
| `lib/features/work/widgets/plan_ui.dart:123-135` | کاشی‌های کل، تکمیل، باقی‌مانده، مسدود | به‌علاوهٔ کاشی «رد نهایی» |
| `lib/features/reports/report_rules.dart:158-159، 244، 253` و `report_pages.dart:177-180` | ستون‌های اسپرینت و مایلستون بدون rejected و blocked | ستون‌های «رد نهایی» و «مسدود»؛ نمایش `rejected` کلی |
| `lib/features/work/widgets/work_ui.dart:17-54`، `lib/core/localization/fa.dart:136-142` | برچسب، رنگ و آیکون دسته‌های بازنشسته | **می‌مانند**، فقط برای نمایش تاریخچه و وضعیت‌های غیرفعال (مثلاً `vvvvvvv` در approved). ستون یا کارتابل نمی‌سازند. |
| `lib/features/work/milestone_pages.dart`، `task_board.dart:662`، `plan_ui.dart:20`، `work_rules.dart:180` | `'in_progress'` | **وضعیت مایلستون** است، نه دستهٔ تسک؛ بدون تغییر |
| `supabase/migrations/20261105120100_tables.sql:220` | قید CHECK دسته‌ها با todo و in_progress | **عمداً بدون تغییر:** ردیف‌های قدیمی حذف فیزیکی نمی‌شوند و باید معتبر بمانند |
| `supabase/tests/critical.sql` (خطوط ۵۱۲، ۵۸۴، ۷۹۰، ۸۲۹، ۸۵۱، ۸۸۰، ۱۰۴۶، ۱۰۵۹، ۱۲۴۵، ۱۷۷۷) و `supabase/tests/dashboard_split.sql:123، 145` | سناریوها تسک را از todo و in_progress عبور می‌دهند | بازنویسی با backlog، `submit_task_for_review` و `decide_task` (پس از Migration؛ آزمون‌های Rollback نسخهٔ فعلی را می‌خواهند) |
| `test/work/*.dart`، `test/dashboard/dashboard_rules_test.dart`، `test/reports/report_rules_test.dart` | دادهٔ آزمون با دستهٔ todo و in_progress؛ `open_tasks_live_test` روی پایگاه دادهٔ زنده | دادهٔ آزمون با backlog؛ آزمون زندهٔ `assignedOpen` با تسک ردشده و مسدود |

**API و RPC:** هیچ RPC تازه‌ای `todo` یا `in_progress` را ستون یا کارتابل نمی‌شمارد (بررسی استاتیک بخش ۱۱). `report_export` فیلتر وضعیت را با دسته یا کلید می‌پذیرد؛ فیلتر `todo` پس از Migration فقط تسک‌های تاریخی بازنشسته را برمی‌گرداند.
