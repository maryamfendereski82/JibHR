# ماتریس مجوز و RLS: گردش‌کار پنج‌وضعیتی (نسخهٔ نهم)

| | |
|---|---|
| وضعیت | Draft نسخهٔ نهم. اجرا فقط پس از بازبینی و تأیید جداگانه. هیچ Migration یا Rollbackی اجرا نشده و هیچ مجوز، RLS یا تابعی در پایگاه داده تغییر نکرده است. |
| منبع | [task-workflow-migration-draft.sql](task-workflow-migration-draft.sql) (تولیدشده). هر سطر این سند در SQL قابل جست‌وجوست و `static_check.py` بندهای امنیتی آن را خودکار کنترل می‌کند. |

## ۱. اصل‌ها

1. **دیدن، اجازهٔ تغییر وضعیت نیست.**
   - `tasks.view.all` به‌تنهایی هیچ وضعیتی را تغییر نمی‌دهد، تصمیم نمی‌گیرد، Override نمی‌کند و تسک ردشده را بازنمی‌گشاید.
   - امروز `transition_task` آن را برای بازگشایی و Override می‌پذیرد. v9 هر دو را حذف می‌کند.
2. **کار مسئول با خود مسئول است.** شروع، ارسال برای بررسی و «انجام شد» فقط با `primary_assignee_id = auth.uid()` انجام می‌شوند و مدیر، تأییدکنندهٔ تیم یا super admin جای او این کارها را نمی‌کند.
3. **تفکیک وظایف.** مسئول هرگز روی تسک خودش تصمیم نمی‌گیرد (`app.can_decide_task`)، حتی اگر بازبین تعیین‌شده، مدیر پروژه یا super admin باشد.
4. **هر قاعدهٔ UI در PostgreSQL هم اجرا می‌شود.** همهٔ مسیرها RPCهای `SECURITY DEFINER` با `search_path = ''` هستند و قاعده را خودشان بررسی می‌کنند. پنهان کردن دکمه کافی فرض نشده است.

## ۲. عملیات × نقش (پس از Migration)

نقش‌ها مستقل از هم بررسی می‌شوند. اگر شخصی چند نقش دارد، هر نقش که ✓ دارد کافی است، **جز در ستون‌هایی که مسئول را صریحاً رد می‌کنند**.

| عملیات | RPC | مسئول اصلی | همکار یا عضو | بازبین پروژه | مدیر پروژه (عضو) | تأییدکنندهٔ تیم مسئول | `tasks.manage.project` | فقط `tasks.view.all` | super admin | غیرعضو یا عضو حذف‌شده |
|---|---|---|---|---|---|---|---|---|---|---|
| دیدن تسک | RLS / `app.can_view_task` | ✓ | ✓¹ | ✓ | ✓ | ✓ شخصی | — | ✓ شخصی | — | ✗² |
| شروع کار | `transition_task` | **✓** | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |
| ارسال برای بررسی | `submit_task_for_review` | **✓** | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |
| انجام شد (بدون تأیید) | `complete_task` | **✓** | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |
| تأیید، درخواست اصلاح، رد نهایی | `decide_task` | **✗ هرگز** | ✗ | ✓³ | ✓³ | ✓ شخصی³ | ✗⁴ | ✗ | ✓ (نه روی تسک خودش) | ✗ (حتی بازبین اختصاصی سابق) |
| ویرایش بازبین: متن، اولویت، مهلت، برچسب | `review_update_task` / `p_changes` | ✗ | ✗ | ✓³ | ✓³ | ✓³ | ✗⁴ | ✗ | ✓ | ✗ |
| ویرایش بازبین: مسئول، همکاران | همان | ✗ | ✗ | ✗ | ✓ | ✗ | ✓ | ✗ | ✓ | ✗ |
| ویرایش تسک بیرون از بررسی | `update_task` | ✓ | ✗ | ✗ | ✗⁵ | ✓ | ✓ | ✗ | ✗⁵ | ✗ |
| برچسب و چک‌لیست بیرون از بررسی⁹ | `set_task_labels`، `*_checklist_item` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ |
| ویرایش محتوا، برچسب یا چک‌لیست **حین بررسی** | همه‌ی موارد بالا | ✗ `task_in_review` | ✗ | از مسیر بازبین | از مسیر بازبین | از مسیر بازبین | ✗ | ✗ | از مسیر بازبین | ✗ |
| مسدود کردن، بازگرداندن مسدود به چرخه | `set_task_blocked` / `clear_task_blocked` | ✓ | ✗ | ✗ | ✗⁵ | ✓ | ✓ | ✗ | ✗⁵ | ✗ |
| بازگشایی رد نهایی (فقط به در صف انجام) | `transition_task` | ✗⁶ | ✗ | ✗ | ✗⁵ | ✗ | **✓** | **✗** | ✓⁶ | ✗ |
| Override زیرتسک (تأیید یا «انجام شد») | `decide_task` / `complete_task` | ✗⁷ | ✗ | ✗ | ✗⁵ | ✗ | ✓ | ✗ | ✓ | ✗ |
| افزودن همکار | `add_task_collaborator` | ✓ | ✗ | ✗ | ✓ | ✗ | ✓ | ✗ | ✓ | ✗ |
| حذف همکار | `remove_task_collaborator` | ✗ | خودش | ✗ | ✓ | ✗ | ✓ | ✗ | ✓ | ✗ |
| حذف عضو پروژه | `remove_project_member` | — | — | — | ✓ `can_edit_project` | — | — | — | — | ✗ |

¹ در پروژهٔ `project_wide` همهٔ اعضا. در `restricted` فقط همکاری که هنوز عضو فعال است.
² عضو حذف‌شده از مسیر ردیف همکار در پروژهٔ `restricted` دسترسی ندارد (`app.task_visible_directly`، تأییدشده در بازبینی 2026-11-09).
³ فقط وقتی «بازبین واجد شرایط» باشد: بازبین اختصاصی و عضو فعال؛ یا بدون بازبین اختصاصی، مدیر یا بازبین پروژه (تسک پروژه‌ای) یا تأییدکنندهٔ تیم (تسک شخصی). در همهٔ حالت‌ها شرط «نه خود مسئول» برقرار است.
⁴ `tasks.manage.project` حق تصمیم نمی‌دهد، مگر شخص بازبین واجد شرایط هم باشد.
⁵ عضویت مدیر در پروژه به‌تنهایی کافی نیست. نقش سازمانی «مدیر پروژه» `tasks.manage.project` دارد و از آن ستون اجازه می‌گیرد. super admin هم از طریق مجوزهای نقش خود.
⁶ مسئولی که `tasks.manage.project` یا super admin است، می‌تواند بازگشایی کند. بازگشایی تصمیم مدیریتی است، نه کار مسئول.
⁷ مگر مسئول `tasks.manage.project` داشته باشد. در «انجام شد» فقط خود مسئول RPC را صدا می‌زند، پس Override فقط برای مسئولی ممکن است که این مجوز را دارد.
⁹ **بدون تغییر نسبت به امروز:** برچسب و چک‌لیست برای هر کسی که تسک را می‌بیند قابل ویرایش‌اند. v9 فقط قفل حین بررسی و ترتیب قفل را اضافه می‌کند. محدود کردن آن‌ها به ویرایشگران تسک تصمیم جداگانه است و در این Draft نیست (Proposal §11، مورد باز ۵).

## ۳. مقایسه: سرور امروز، سرور v9، Flutter

| قاعده | سرور امروز (نه‌وضعیتی) | سرور v9 | Flutter امروز | Flutter هنگام Migration |
|---|---|---|---|---|
| شروع کار | مسئول، `tasks.manage.project`، تأییدکنندهٔ تیم | **فقط مسئول** | فقط مسئول | فقط مسئول |
| ارسال برای بررسی | همان سه (با کشیدن کارت) | **فقط مسئول**، فقط RPC اختصاصی | فقط مسئول | فقط مسئول، `submit_task_for_review` |
| انجام شد | همان سه، با `approved → done` | **فقط مسئول**، `complete_task` اتمیک | فقط مسئول، زنجیرهٔ موجود | فقط مسئول، `complete_task` |
| تصمیم | بازبین واجد شرایط | همان، **نه خود مسئول** | `canDecideTask` (شامل `tasks.view.all`)⁸ | هم‌تراز با سرور |
| بازگشایی رد نهایی | `tasks.manage.project` **یا `tasks.view.all`** | `tasks.manage.project` یا super admin | **`tasks.manage.project`** (در این نسخه اصلاح شد) | همان |
| Override زیرتسک | `tasks.manage.project` **یا `tasks.view.all`** | `tasks.manage.project` یا super admin | گفت‌وگوی دلیل؛ سرور تصمیم می‌گیرد | همان |
| ویرایش حین بررسی | آزاد | **قفل** (`task_in_review`) | فرم ویرایش باز است⁸ | پنهان یا غیرفعال |
| مسدود / رفع | وضعیت `blocked` | Flag؛ رفع به «در صف انجام» | `canEditTask`⁸ | `set_task_blocked` / `clear_task_blocked` |

⁸ `canEditTask` و `canDecideTask` در Flutter امروز `tasks.view.all` را هم می‌پذیرند و از سرور گشاده‌دست‌ترند. نتیجهٔ عملی فقط دکمه‌ای است که سرور رد می‌کند و Snackbar خطا نشان می‌دهد. نشتی امنیتی نیست. همسان‌سازی آن‌ها بخشی از کار Flutter هنگام Migration است (Proposal §10). بازگشایی که v9 صریحاً ممنوع می‌کند، همین حالا اصلاح شد.

## ۴. مجوز توابع

| تابع | PUBLIC | anon | authenticated | service_role |
|---|---|---|---|---|
| ۸ RPC جدید: `project_member_directory`، `project_member_open_tasks`، `submit_task_for_review`، `review_update_task`، `decide_task` (امضای جدید)، **`complete_task`**، `set_task_blocked`، `clear_task_blocked` | ✗ | ✗ | ✓ | ✓ |
| ۲۳ تابع `public` تغییرکرده | ✗ | ✗ | ✓ (مثل امروز) | ✓ |
| `app.seed_workflow`، `app.task_visible_directly` | ✗ | ✗ | ✗ | ✓ (مثل امروز) |
| `app.dashboard_summary_v1` | ✗ | ✗ | ✗ | ✗ (مثل امروز؛ فقط مالک) |
| ۱۸ تابع داخلی و Trigger جدید | ✗ | ✗ | ✗ | ✗ |

- **پیش‌فرض‌های واقعی:** در `public` اشیای جدید EXECUTE یا ALL برای `anon` و `authenticated` می‌گیرند و در `app` EXECUTE برای PUBLIC. Migration روی این‌ها تکیه نمی‌کند: هر Grant اول Revoke و سپس صریح داده می‌شود.
- **خودآزمایی پیش از Commit:** Migration پیش از Commit همهٔ این‌ها را با `has_function_privilege` و `has_table_privilege` بررسی می‌کند (`acl_check_failed`).
- `decide_task(uuid, text, text)` قدیمی Drop و با امضای جدید جایگزین می‌شود.

## ۵. جدول‌ها و RLS

| جدول | anon | authenticated | service_role | RLS خواندن | نوشتن |
|---|---|---|---|---|---|
| `task_revision_requests`، `task_block_events` (جدید؛ `to_status_id` در v9) | ✗ | SELECT | SELECT | `app.can_view_task(task_id)` | فقط RPCها (مالک). UPDATE، DELETE و TRUNCATE با Trigger رد می‌شوند. |
| `task_review_rounds`، `task_reviews`، `task_activity_events` | ✗ | مثل امروز | مثل امروز **منهای** INSERT، UPDATE، DELETE، TRUNCATE، TRIGGER، REFERENCES | سیاست‌های فعلی (`can_view_task`) | فقط RPCها. Triggerهای ردیفی و Statement. |
| `tasks` (ستون‌های جدید `blocked_at`، `blocked_reason`، `blocked_by`) | مثل امروز | مثل امروز | مثل امروز | سیاست‌های فعلی | فقط RPCها |
| ۵ جدول دفتری Migration | ✗ | ✗ | ✗ | RLS فعال بدون سیاست | فقط Migration و Rollback |
| `profiles`، `workflow_statuses`، `workflow_transitions` | بدون تغییر | بدون تغییر | بدون تغییر | بدون تغییر | — |

**مرز اعتماد:**
- **نقش‌های API** (`anon`، `authenticated`، `service_role`) روی جدول‌های تاریخی فقط SELECT دارند و مالک جدول نیستند، پس نمی‌توانند Trigger را غیرفعال کنند.
- **مالک جدول (`postgres`)** می‌تواند Triggerهای کاربری را غیرفعال کند. پس Triggerها جلوی اشتباه را می‌گیرند، نه جلوی مالک عمدی.
- کنترل مالک عملیاتی است: محدود نگه داشتن رمز `postgres`، پشتیبان‌گیری و Audit logهای پایگاه داده.

## ۶. خطاهای مجوز و قاعده

| خطا | کجا | معنا |
|---|---|---|
| `forbidden` | همه | تسک دیده نمی‌شود یا نقش لازم وجود ندارد |
| `assignee_only` | `transition_task` (شروع)، `submit_task_for_review`، `complete_task` | فقط مسئول اصلی |
| `rejected_closed` | `transition_task` | بازگشایی بدون `tasks.manage.project` یا super admin |
| `reopen_backlog_only` | `transition_task` | خروج از رد نهایی فقط به «در صف انجام» |
| `use_submit` / `use_complete` / `use_decide` | `transition_task` | این انتقال RPC اختصاصی دارد |
| `task_in_review` | `update_task`، برچسب و چک‌لیست | نسخهٔ ارسال‌شده تا تصمیم قفل است |
| `task_blocked` | شروع، ارسال، «انجام شد»، تصمیم و ویرایش بازبین | ابتدا انسداد رفع شود |
| `approval_required` / `not_required` | `complete_task` / `submit_task_for_review` | مسیر غلط برای سیاست تأیید تسک |
| `subtasks_incomplete` | `decide_task` (تأیید)، `complete_task` | زیرتسک اجباری ناتمام؛ Override فقط مدیریتی |
| `workflow_incomplete` | ارسال، «انجام شد»، تصمیم، رفع انسداد | Workflow سفارشی دستهٔ لازم را ندارد |
| `category_retired` / `status_required` | `save_workflow_status` | ساخت یا فعال‌سازی وضعیت بازنشسته؛ حذف یکی از پنج دستهٔ لازم |
