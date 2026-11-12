# طرح بک‌اند نسخهٔ نهم: گردش‌کار پنج‌وضعیتی، چرخهٔ بررسی، نسخه‌ها و یکپارچگی تخصیص

| | |
|---|---|
| وضعیت | **Draft نسخهٔ نهم، برای بازبینی SQL و Security.** مجوز اجرای Migration صادر نشده است. اجرا فقط پس از بازبینی و تأیید نهایی جداگانه. |
| اجرا | هیچ Migration یا Rollbackی اجرا نشده است. Local و Remote بدون تغییرند، هیچ داده‌ای دست نخورده و Commit انجام نشده است. همهٔ پرس‌وجوها فقط‌خواندنی بودند. |
| فایل‌ها | [task-workflow-migration-draft.sql](task-workflow-migration-draft.sql) · [task-workflow-rollback-draft.sql](task-workflow-rollback-draft.sql) · [task-workflow-premigration-report.sql](task-workflow-premigration-report.sql) (فقط‌خواندنی) · [task-workflow.md](task-workflow.md) (رفتار نهایی) · [task-workflow-permission-matrix.md](task-workflow-permission-matrix.md) · [task-workflow-test-matrix.md](task-workflow-test-matrix.md) · [task-workflow-review-package.md](task-workflow-review-package.md) |
| تولید | [scripts/task-workflow-migration/](../scripts/task-workflow-migration/README.md). SQLها را دستی ویرایش نکنید. |
| نسخهٔ قبل | بستهٔ کامل نسخهٔ هشتم (چهار وضعیت) بدون تغییر در [archive/task-workflow-v8/](archive/task-workflow-v8/) نگه داشته شده است. |

## ۱. تصمیم‌ها

| کد | تصمیم |
|---|---|
| **W5** | Workflow فعال دقیقاً پنج وضعیت دارد: `backlog` «در صف انجام»، `in_progress` «در حال انجام»، `in_review` «در حال بررسی»، `approved` «تأیید شده»، `rejected` «رد شده». وضعیت ششمی وجود ندارد. |
| **W5-fix** | **اصلاح اشتباه نسخه‌های قبل:** `in_progress` حذف نمی‌شود و `approved` حفظ می‌شود. `done` بازنشسته می‌شود و تسک‌های معتبرش به `approved` می‌روند. |
| D2 | «مسدود» Flag است: زمان، دلیل، ثبت‌کننده و رویدادها. در ستون «رد شده» با Badge «مسدود» نمایش داده می‌شود. رفع انسداد تسک را به «در صف انجام» برمی‌گرداند. |
| D4، D5 | دایرکتوری محدود اعضا. عضویت فعال مسئول، بازبین و همکار (بدون تغییر از نسخهٔ هشتم). |
| B1 | درخواست اصلاح: «چه چیزی» و «چرا» اجباری. تسک با همان مسئول به «در صف انجام» برمی‌گردد. وضعیت `changes_requested` ساخته نمی‌شود. |
| B2 | ورود به بررسی فقط با `submit_task_for_review`، از «در حال انجام»، **فقط مسئول اصلی**. |
| B3 | حذف عضوی که تسک حل‌نشده دارد ممنوع است (تسک مسدود هم حل‌نشده است). |
| **C1** | «انجام شد» = `complete_task`: انتقال مستقیم و اتمیک `in_progress → approved`، فقط مسئول اصلی، فقط وقتی تأیید لازم نیست. دور یا تصمیم ساختگی ایجاد نمی‌کند. |
| **S1** | شروع کار، ارسال و «انجام شد» فقط با مسئول اصلی. تصمیم فقط با بازبین واجد شرایط و **هرگز با خود مسئول**. بازگشایی رد نهایی فقط با `tasks.manage.project` یا super admin. `tasks.view.all` به‌تنهایی هیچ وضعیتی را تغییر نمی‌دهد. |
| **S2** | نسخهٔ ارسال‌شده تا تصمیم قفل است (`task_in_review`). بازبین از مسیر ثبت‌شده اصلاح می‌کند. |
| **R5** | تسک مسدود و رد نهایی از Remaining خارج‌اند، به اسپرینت بعد منتقل نمی‌شوند و به‌تنهایی مانع مایلستون نیستند. شمارش آن‌ها جداست و جمع گروه «رد شده» هر تسک را یک بار می‌شمارد. |
| `ttt` | تأییدشده در بازبینی 2026-11-09: `changes_requested → backlog`. |
| `vvvvvvv`، `rgdfdgf` | بدون تغییر، با وضعیت دقیق Pinشده. **`rgdfdgf` از نسخهٔ هشتم تغییر کرده است (§۳).** |
| «کار محلی» | `done → approved`. شناسه، وضعیت، وضعیت تأیید، دور و تصمیم در Guard Pin شده‌اند. |
| «لندینگ باگ بانتی» | در `approved` می‌ماند (نسخهٔ هشتم آن را به `done` می‌برد) و وضعیت کاملش Pin شده است. |

## ۲. تعیین تکلیف وضعیت‌های قدیمی

| وضعیت قدیمی | تصمیم v9 | تسک‌ها در دادهٔ فعلی |
|---|---|---|
| `backlog` | حفظ؛ نام «در صف انجام»؛ ترتیب ۱ | ۱ («تت») |
| `todo` | غیرفعال؛ تسک‌ها به `backlog` | ۰ |
| `in_progress` | **حفظ و فعال**؛ نام «در حال انجام»؛ ترتیب ۲ | ۰ |
| `in_review` | حفظ؛ ترتیب ۳ | ۱ (`rgdfdgf`، مستثنا) |
| `approved` | **حفظ و فعال**؛ نام «تأیید شده»؛ ترتیب ۴ | ۳ («تست 2»، «لندینگ باگ بانتی»، `vvvvvvv`) |
| `rejected` | حفظ؛ نام «رد شده»؛ ترتیب ۵ | ۰ |
| `changes_requested` | غیرفعال؛ تسک‌ها به `backlog` | ۱ (`ttt`) |
| `blocked` | غیرفعال؛ Flag مستقل روی وضعیت قبلی، نگاشته به پنج وضعیت؛ قابل بازیابی در Rollback | ۰ |
| `done` | غیرفعال؛ انتقال قطعی تسک‌های معتبر به `approved` | ۱ («کار محلی») |

- هیچ وضعیتی حذف فیزیکی نمی‌شود. وضعیت‌های بازنشسته ترتیب +۱۰۰ و `is_active = false` می‌گیرند.
- انتقال‌های قدیمی که به وضعیت بازنشسته وصل‌اند حذف نمی‌شوند؛ مقصد غیرفعال است و `status_inactive` می‌دهد.
- **قاعدهٔ `done → approved`** (همان SQL در گزارش و Migration، `approval_ok`):
  - مجاز فقط وقتی دور بازی وجود ندارد و یکی از دو شرط برقرار است:
    - تأیید لازم نیست و هرگز ارسال نشده (`not_required`)؛
    - `approval_state = 'approved'` و تصمیم جدیدترین دور `approved` است.
  - هر حالت دیگر `ambiguous_done_approval` است و Migration متوقف می‌شود.
  - همین آزمون برای همهٔ تسک‌های `approved` هم اجرا می‌شود (`ambiguous_approved_approval`).
- **مسدود:**
  - وضعیت قبل از ورود به `blocked` (از رویداد انتقال) نگاشته می‌شود: `backlog`، `todo` و `changes_requested` به `backlog`، و `in_progress` به `in_progress`. Flag با دلیل «انتقال خودکار از وضعیت مسدود» و رویداد ثبت می‌شود.
  - تسک مسدودی که از `in_review` آمده یا وضعیت قبلی نامعلوم دارد ابهام است و Migration را متوقف می‌کند. امروز هیچ تسک مسدودی وجود ندارد.

## ۳. گزارش پیش از Migration (2026-11-10، فقط‌خواندنی)

**R7 خالی است:** دادهٔ زنده با انتظارات Guard ردیف‌به‌ردیف برابر است.

| تسک | وضعیت | تأیید | دورها | تصمیم | Plan |
|---|---|---|---|---|---|
| `ttt` (شخصی) | `changes_requested` | لازم نیست / `not_required` | ۰ | — | **move → backlog** |
| «کار محلی» (محصول محلی) | `done` | لازم / `approved` | ۱ | `approved` | **move → approved** |
| `rgdfdgf` (باگ بانتی) | `in_review` | لازم / `pending` | ۱ (باز) | — | excluded (بدون تغییر) |
| `vvvvvvv` (شخصی) | `approved` | لازم نیست / `not_required` | ۰ | — | excluded (بدون تغییر) |
| «لندینگ باگ بانتی» (شخصی) | `approved` | لازم / `approved` | ۱ | `approved` | keep (Pinشده) |
| «تست 2» (شخصی) | `approved` | لازم / `approved` | ۱ | `approved` | keep |
| «تت» (شخصی) | `backlog` | — | ۰ | — | keep |

Integrity: `assignee_not_member` و `open_round` برای `rgdfdgf`، و `personal_created_for_other` برای `vvvvvvv`.

R10، وضعیت پس از Migration: `backlog` ۲، `in_review` ۱، `approved` ۴. هیچ تسکی در وضعیت بازنشسته باقی نمی‌ماند.

**یافته‌هایی که بازبین باید ببیند (هیچ‌کدام حدس زده یا تغییر داده نشده است):**
1. **`rgdfdgf` تغییر کرده است.**
   - در نسخهٔ هشتم با وضعیت `backlog` Pin شده بود. در 2026-11-09 ساعت 17:24 UTC (پس از گزارش نسخهٔ هشتم) **super admin** آن را `todo → in_progress → in_review` برد. دور ۱ باز و بدون تصمیم است و مسئولش عضو «باگ بانتی» نیست.
   - v9 طبق دستور «بدون تغییر» وضعیت **فعلی** را Pin می‌کند و دست نمی‌زند. Guard نسخهٔ هشتم روی این داده متوقف می‌شد.
   - **تأیید لازم:** همین وضعیت Pin شود (پیش‌فرض Draft)، یا پیش از اجرا تصمیم دیگری گرفته شود.
2. **«تست 2» پس از نسخهٔ هشتم تأیید شده است** (2026-11-09، 17:48–17:51 UTC): ارسال و تأیید هر دو توسط super admin که خودش مسئول است. در `approved` می‌ماند و Plan آن را `keep` می‌داند.
3. **هر سه تسک تأییدشده («کار محلی»، «لندینگ باگ بانتی»، «تست 2») را خود مسئول تأیید کرده است** (R9، `decided_by_assignee`). v9 این کار را از این پس ممنوع می‌کند. تاریخچه تغییر نمی‌کند.

## ۴. مسیرهای سرور

جدول کامل انتقال‌ها و نقش‌ها در [task-workflow.md](task-workflow.md) و [ماتریس مجوز](task-workflow-permission-matrix.md) است. خلاصه:

| انتقال | RPC | قاعدهٔ کلیدی |
|---|---|---|
| `backlog → in_progress` | `transition_task` | `assignee_only` |
| `in_progress → in_review` | `submit_task_for_review` | فقط مسئول؛ تأیید لازم؛ نسخهٔ vN با Snapshot |
| `in_review → approved / backlog / rejected` | `decide_task(p_task, p_decision, p_round, p_reason, p_what, p_changes, p_override_reason)` | بازبین واجد شرایط، نه مسئول؛ اولین تصمیم برنده |
| `in_progress → approved` | **`complete_task(p_task, p_override_reason)`** (جدید) | فقط مسئول؛ تأیید لازم نیست؛ بدون دور یا تصمیم |
| `rejected → backlog` | `transition_task` | `tasks.manage.project` یا super admin؛ `task.reopen` |
| Flag مسدود | `set_task_blocked` / `clear_task_blocked` | از `backlog` یا `in_progress`؛ رفع به `backlog` |

`transition_task` در v9 فقط شروع و بازگشایی را انجام می‌دهد (به‌علاوهٔ انتقال‌های ساده‌ای که Workflow سفارشی بین وضعیت‌های باز تعریف کند). برای ورود به بررسی، رسیدن به تأیید یا رد، و خروج از بررسی به‌ترتیب `use_submit`، `use_complete` و `use_decide` می‌دهد. Override زیرتسک و رویداد «زیرتسک انجام شد» از آن به `complete_task` و `decide_task` منتقل شده‌اند. پارامتر `p_override_reason` برای سازگاری امضا باقی است.

## ۵. Guard

به ترتیب و در یک تراکنش:
1. **محیط:** `read committed`؛ قفل `EXCLUSIVE` روی جدول‌های تسک و Workflow و `SHARE ROW EXCLUSIVE` روی `profiles` و `projects`؛ بدون Session یا تراکنش آماده‌شدهٔ دیگر.
2. **(a)** دقیقاً پنج Workflow شناخته‌شده، همه پیش‌فرض نه‌وضعیتی. Workflow سفارشی Migration را متوقف می‌کند.
3. **(b)** Plan ردیف‌به‌ردیف برابر انتظار است و هیچ ردیف `ambiguous_*` وجود ندارد.
4. **(c)** پنج تسک Pinشده دقیقاً در وضعیت بازبینی‌شده‌اند. ستون‌ها:
   - شناسه، عنوان، شخصی بودن و وضعیت؛
   - وضعیت و الزام تأیید؛
   - مسئول، سازنده و بازبین؛
   - پروژه و نام آن، Workflow، شناسهٔ وضعیت و Workspace؛
   - **تعداد دورها، دورهای باز و تصمیم جدیدترین دور**؛
   - بایگانی نبودن.
5. **(d)** یافته‌های Integrity دقیقاً سه ردیف بالا هستند.
6. **پس از انتقال‌ها (`$retired$`):** هیچ تسکی در وضعیت بازنشسته باقی نمانده است.
7. **پس از وضعیت‌ها و انتقال‌ها (`$final$`):** هر Workflow پیش‌فرض دقیقاً پنج وضعیت فعال و هر هفت انتقال نهایی را دارد.
8. **پیش از Commit (`$acl$`):** مجوزها همان §۸ هستند.

گزارش و Migration یک منطق مشترک دارند: `WF_SELECT`، `PLAN_SELECT`، `PINNED_STATE_SELECT` و `INTEGRITY_SELECT` در `common.py` یک متن واحدند. R7 همان مقایسه‌های Guard را اجرا می‌کند.

## ۶. توابع

**۲۶ تابع موجود** (بدنهٔ Dump زنده به‌علاوهٔ Patch دقیق؛ ACL بدون تغییر). تغییرات v9 نسبت به نسخهٔ هشتم پررنگ است:

| تابع | تغییر |
|---|---|
| `transition_task` | ورود به بررسی فقط از Submit؛ خروج از بررسی `use_decide`؛ **`use_complete`، `use_decide` برای `rejected`، `assignee_only` برای شروع، `task_blocked` برای هر انتقال تسک مسدود؛ بازگشایی بدون `tasks.view.all`؛ حذف Override و رویداد زیرتسک**؛ رویداد و Audit `task.reopen` |
| `update_task` | عضویت و Audit مسئول و بازبین (نسخهٔ هشتم)؛ **قفل محتوا و سیاست تأیید حین بررسی (`task_in_review`)** |
| `set_task_labels`، `add/toggle/rename/delete/move_checklist_item` | قفل ردیف تسک (نسخهٔ هشتم)؛ **`task_in_review`** |
| `save_workflow_status` | **بازنشسته = `todo`، `changes_requested`، `blocked`، `done`؛ پنج دستهٔ لازم شامل `in_progress` و `approved`** |
| `app.seed_workflow` | **پنج وضعیت و هفت انتقال** |
| `project_sprint_counts`، `project_milestone_counts` | **ستون‌های `rejected`، `rejected_group`، `remaining`**؛ مسدود فقط Flag |
| `set_sprint_status` | **`remaining` = کار باز**، `rejected` و `blocked` جدا |
| `transfer_sprint_remainder`، `set_milestone_status` | **`app.task_is_open`** (نسخهٔ هشتم: `task_is_unresolved`) |
| `work_analytics` | **`rejected_group`**؛ `remaining` برای هر اسپرینت و مایلستون = کار باز؛ مسدود فقط Flag |
| `dashboard_*`، `app.dashboard_summary_v1` | کار باز = `app.task_is_open`؛ Home: `rejected_tasks` و `blocked_tasks` |
| `create_task`، `add/remove_task_collaborator`، `remove_project_member`، `app.task_visible_directly` | بدون تغییر نسبت به نسخهٔ هشتم |

**۸ RPC جدید:** `project_member_directory`، `project_member_open_tasks`، `submit_task_for_review` (**از `in_progress`، فقط مسئول**)، `review_update_task`، `decide_task` (**تأیید به `approved`**)، **`complete_task`**، `set_task_blocked` (**از `backlog` یا `in_progress`؛ رویداد و Audit**)، `clear_task_blocked` (**به `backlog`؛ `to_status_id`؛ رویداد و Audit**).

**۱۸ تابع داخلی:**
- **`app.can_decide_task`:** مسئول هرگز تصمیم نمی‌گیرد (جدید در v9).
- **`app.task_is_open` و `app.task_is_unresolved`:** همان تعریف نسخهٔ هشتم. مسدود به ترتیب false و true؛ رد نهایی false و false.
- **`app.task_counts_complete`:** بدون تغییر.
- بقیه بدون تغییر.

**طرح‌واره:** ستون‌های Flag روی `tasks`، جدول‌های `task_block_events` (**`to_status_id` جدید**) و `task_revision_requests`، ستون‌های Snapshot روی دورها، نام تاریخی روی تصمیم‌ها، Triggerهای تغییرناپذیری، و پنج جدول دفتری.

## ۷. Sprint، Milestone و گزارش‌ها

- **«رد نهایی» و «مسدود» دو شمارش جدا هستند** و Remaining هیچ‌کدام را ندارد.
- **Remaining** مستقیم با `app.task_is_open` شمرده می‌شود، نه با تفریق، تا تسکی که هم‌زمان چند ویژگی دارد دو بار کم نشود.
- **`rejected_group`** جمع گروه «رد شده» است و هر تسک را یک بار می‌شمارد.
- **بستن اسپرینت:** فقط کار باز به اسپرینت بعد منتقل می‌شود. تسک مسدود و ردشده در اسپرینت قبلی می‌مانند و پس از بازگشت به چرخه دستی برنامه‌ریزی می‌شوند.
- **مایلستون:** تسک مسدود و ردشده به‌تنهایی مانع رسیدن نیستند.
- **حذف عضو:** همچنان `app.task_is_unresolved`، پس تسک مسدود کار حل‌نشدهٔ آن عضو است.
- **Home، Kanban، List، Calendar، کارهای من، تسک‌های شخصی، اسپرینت، مایلستون، گزارش‌ها و Excel و PDF** همه همین توابع یا Adapter Flutter را می‌خوانند. هیچ نام بازنشسته‌ای نمایش داده نمی‌شود.

## ۸. امنیت و مجوز

جزئیات در [ماتریس مجوز](task-workflow-permission-matrix.md) است. نکات اصلی:
- **بسته شدن دو راه `tasks.view.all`:** امروز `transition_task` آن را برای **بازگشایی رد نهایی** و **Override زیرتسک** می‌پذیرد. v9 هر دو را می‌بندد. در Flutter، بازگشایی همین حالا به `tasks.manage.project` محدود شد.
- **مسیرهای بدون دکمه:** هر قاعدهٔ UI (فقط مسئول، فقط بازبین، فقط مدیریت، قفل حین بررسی) در خود RPC بررسی می‌شود، پس صدا زدن مستقیم RPC همان نتیجهٔ UI را دارد. `static_check.py` این‌ها را خودکار کنترل می‌کند.
- **Grantها:** هر Grant صریح است. `anon` به هیچ RPC دسترسی ندارد. توابع داخلی برای هیچ نقش API قابل اجرا نیستند. جدول‌های تاریخی برای نقش‌های API فقط SELECT دارند.

## ۹. Rollback

- **Statusها و انتقال‌ها** فقط وقتی بازگردانده می‌شوند که پس از Migration تغییر نکرده باشند، یعنی ردیف هنوز برابر «after» یا مقدار ثبت‌شده است.
- **تسک‌ها** فقط وقتی برمی‌گردند که دقیقاً همان‌جایی باشند که Migration گذاشت. برای تسک مسدود، Flag هم باید همان باشد که Migration گذاشت. تسکی که کسی جابه‌جا کرده در «Kept» گزارش می‌شود.
- **بدنهٔ دقیق ۲۷ تابع** با Grantهایشان بازگردانده می‌شود. برابری بایت‌به‌بایت با MD5 در خود Rollback بررسی می‌شود.
- **RPCهای جدید** (شامل `complete_task`) و توابع داخلی بی‌مصرف Drop می‌شوند.
- **حذف نمی‌شوند:** داده‌های پس از Migration، Snapshotها، تصمیم‌ها، درخواست‌های اصلاح، رویدادهای انسداد، Flagهای ثبت‌شده توسط افراد، Logها و Triggerهای تغییرناپذیری.
- **سازگاری با Flutter و بک‌اند جدید:**
  - ستون‌ها و جدول‌ها می‌مانند، پس Flutter نسخهٔ Migration پس از Rollback هم داده را می‌خواند. Flag هم با `blocked_at` و هم با دستهٔ `blocked` شناخته می‌شود.
  - برای RPCهای حذف‌شده به مسیر قبلی برمی‌گردد (§۱۰).
  - تسکی که پس از Migration با `complete_task` یا تصمیم v9 به `approved` رسیده، در مدل قدیم هم وضعیت معتبر دارد.

## ۱۰. کار Flutter هم‌زمان با Migration (خارج از این SQL)

Flutter امروز با Adapter پنج‌وضعیتی کار می‌کند و تا Migration نباید به RPCهای جدید وابسته شود. هم‌زمان با اجرای Migration:
1. **مسیرهای جدید:**
   - «ارسال برای بررسی» به `submit_task_for_review`؛
   - «انجام شد» به `complete_task`، به‌جای زنجیرهٔ `in_progress → in_review → approved`؛
   - تصمیم با امضای جدید `decide_task` (با `p_round` و فیلدهای جدای «چه چیزی» و «چرا»)؛
   - مسدود و رفع با `set_task_blocked` / `clear_task_blocked`.
2. **`isBlockedTask`:** از `blocked_at` بخواند. امروز تنها نقطهٔ این تصمیم دستهٔ `blocked` در `workflow_presentation.dart` است.
3. **سازگاری با Rollback:** اگر RPC جدید `PGRST202` (تابع پیدا نشد) برگرداند، Adapter فعلی (زنجیرهٔ `transition_task`) استفاده شود. با این کار نسخهٔ Migration پس از Rollback هم کار می‌کند.
4. **همسان‌سازی مجوزهای Flutter با سرور:**
   - `canEditTask` و `canDecideTask` امروز `tasks.view.all` را می‌پذیرند (فقط دکمه‌ای که سرور رد می‌کند؛ نشتی نیست).
   - «انجام شد» و «ارسال» برای مسئولی که بازبین خودش است.
   - قفل فرم ویرایش حین بررسی.
   - پیام خطاهای جدید (`assignee_only`، `task_in_review`، `use_complete`).
5. **محدودیت‌های موقت حذف می‌شوند:**
   - بازگرداندن مسدود به «در حال انجام»؛
   - غیرفعال بودن بازگشایی رد نهایی؛
   - عبور لحظه‌ای «انجام شد» از `in_review`.
6. **آزمون‌ها:** ماتریس آزمون، بخش ح.

## ۱۱. موارد باز برای تصمیم بازبین

| # | موضوع | پیش‌فرض Draft |
|---|---|---|
| 1 | وضعیت فعلی `rgdfdgf` (در بررسی، دور باز، مسئول غیرعضو) | همین وضعیت Pin شده و Migration به آن دست نمی‌زند |
| 2 | تأییدهای گذشته‌ای که خود مسئول ثبت کرده | تاریخچه حفظ می‌شود. ممنوعیت فقط از این پس |
| 3 | مسدود کردن از «در صف انجام» | سرور اجازه می‌دهد (کار باز). UI امروز فقط از «در حال انجام» پیشنهاد می‌دهد |
| 4 | تفکیک وظایف ممکن است تسکی را بی‌بازبین بگذارد (مثلاً مدیر تیمی که خودش مسئول است و تأییدکنندهٔ دیگری ندارد) | super admin یا تعیین بازبین دیگر |
| 5 | برچسب و چک‌لیست برای هر کسی که تسک را می‌بیند قابل ویرایش‌اند (رفتار امروز) | بدون تغییر، به‌جز قفل حین بررسی |
| 6 | تغییر مسئول یا بازبین حین بررسی | مجاز با مجوز و Audit. محتوا قفل است |
| 7 | بازگشایی رد نهایی: وضعیت تأیید تسک نیازمند تأیید | `pending` (مثل نسخهٔ هشتم). نسخهٔ بعدی vN+1 |

## ۱۲. آزمون‌ها

[ماتریس آزمون](task-workflow-test-matrix.md):
- **انجام‌شده (بدون Migration):**
  - تجزیه و Lint SQL، ارجاع‌ها، ترتیب ساخت، MD5 Rollback و قواعد پنج‌وضعیتی با `static_check.py`: **NO PROBLEMS**؛
  - گزارش فقط‌خواندنی: **R7 خالی**؛
  - `flutter analyze`: بدون Issue؛
  - `flutter test`: ۲۴۳ موفق، ۷ Skip زنده.
- **پس از تأیید:** Guard، مسیرهای جدید برای هر نقش، مسدود، شمارش‌ها، Workflow، امنیت، Rollback و Regression، روی کپی یک‌بارمصرف.

## ۱۳. تولید

```bash
cd scripts/task-workflow-migration
python gen_migration.py && python gen_report.py && python gen_rollback.py
<venv-with-pglast>/python static_check.py          # NO PROBLEMS
docker exec -i supabase_db_jibhr psql -U postgres -d postgres -P pager=off -v ON_ERROR_STOP=1 \
  < ../../docs/task-workflow-premigration-report.sql  # فقط‌خواندنی؛ R7 باید خالی باشد
```

هر تغییر داده پیش از اجرا گزارش را عوض می‌کند و Guard را متوقف می‌کند. انتظارات فقط در `common.py` به‌روز می‌شوند، پس از بازبینی دوباره.

## ۱۴. فهرست تغییرات نسبت به نسخهٔ هشتم

1. `in_progress` و `approved` فعال ماندند. `done` بازنشسته شد. بازنشسته‌ها: `todo`، `changes_requested`، `blocked`، `done`.
2. نگاشت `done → approved` با Guard سازگاری تأیید. نگاشت `approved → done` حذف شد.
3. «کار محلی» به Plan اضافه شد. «لندینگ باگ بانتی» از Plan بیرون آمد و Pin ماند. `rgdfdgf` با وضعیت فعلی Pin شد. Integrity سه ردیف دارد.
4. Pin با تعداد دورها، دورهای باز و تصمیم آخر.
5. `complete_task` جدید. `transition_task` فقط شروع و بازگشایی را انجام می‌دهد.
6. فقط مسئول برای شروع، ارسال و «انجام شد». مسئول هرگز تصمیم نمی‌گیرد. `tasks.view.all` از بازگشایی و Override حذف شد.
7. ارسال از `in_progress` (نه `backlog`).
8. رفع انسداد به `backlog`، با `to_status_id`، رویداد و Audit. مسدود کردن هم رویداد و Audit دارد.
9. قفل محتوا حین بررسی.
10. انتقال اسپرینت و مایلستون با `task_is_open`. Remaining مستقیم. `rejected_group`.
11. `seed_workflow` و `save_workflow_status` پنج‌وضعیتی.
12. خودآزمایی‌های `$retired$` و `$final$`. گزارش‌های R9 (سازگاری تأیید) و R10 (توزیع پس از Migration).
13. بررسی ایستای جدید برای قواعد پنج‌وضعیتی و نبود باقی‌ماندهٔ مدل چهاروضعیتی.
