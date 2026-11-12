# بستهٔ بازبینی: Migration گردش کار تسک JibHR (نسخهٔ هشتم، برای بازبینی نهایی)

این بسته برای بازبینی مستقل **SQL و Security** آماده شده است. هیچ‌چیز اجرا نشده است:
- هیچ Migration یا Rollbackی اجرا نشده است.
- هیچ پایگاه داده‌ای (Local یا Remote) تغییر نکرده و هیچ داده‌ای دست نخورده است. گزارش و بررسی استاتیک فقط در `begin transaction read only … rollback` اجرا شدند.
- Commit انجام نشده است.
- **مجوز اجرا هنوز صادر نشده است.**

## ۱. چه چیزی بازبینی می‌شود

| فایل | نقش | خط | SHA-256 |
|---|---|---|---|
| `docs/task-workflow-migration-draft.sql` | Migration (یک Transaction) | 3086 | `d76cd097cd3ea2ceee8599bf15d18b5477273b118f3f476d5ab81306143fc488` |
| `docs/task-workflow-rollback-draft.sql` | Rollback (یک Transaction) | 2059 | `a8e68c492d6bbdcb3bf5df4638712319d5306dff00f84db8b4a558afbdfda703` |
| `docs/task-workflow-premigration-report.sql` | گزارش فقط‌خواندنی (بخش جدید R8) | 689 | `82f94f2f191740a969cdfb82cb395140f8098f688066fc04747bf57bd2baf90b` |
| `docs/task-workflow-proposal.md` | طرح کامل (تغییرات نسخهٔ هشتم در بخش ۲؛ وضعیت‌های بازنشسته ۶.۱؛ گروه «رد شده» ۷.۶؛ بازگشایی ۷.۷؛ UI در بخش ۱۷) | — | `fcc10d64644624598a407721a9500b0a0923c99339932cca59402eff20208cd4` |
| `docs/task-workflow.md` | رفتار نهایی | — | `69561ff072c9cd8702b518c5f6867de5fb90f56e3b5f047a7051a790d97d5b3d` |

**Generatorها (`scripts/task-workflow-migration/`):**

| فایل | SHA-256 |
|---|---|
| `common.py` | `ff00da19f9d03ce0b625a46223280aa31f016feac2e50d2bfd39f29eaa27bf5e` (بدون تغییر: Guard، `ttt`، `vvvvvvv`، `rgdfdgf`) |
| `gen_migration.py` | `80e86bfe407b04e7b090b5262dfb7145ebae8e712cfbbff566d078630e129f89` |
| `gen_report.py` | `75f794aa73b6772d275d2c7ca45836e5c02216f8c4d9d63272eb3c8e55776a79` |
| `gen_rollback.py` | `72f4e5f0808491bccb0b8106e016403179566fedd0a6bd1cf791385324d40372` |
| `static_check.py` | `a50cc288d5963abc452ad33136cfddb3c71d932dc08af07caefba3ecc490353f` |
| `dump_functions.sh` | `55f0dc1d466f97b254ad56244839428799c4a04389049d4be7c9ee4dfc9f13a6` (بدون تغییر) |
| `fndefs/` | ۳۰ Dump فقط‌خواندنی (`pg_get_functiondef`)، بدون تغییر |

سه فایل SQL تولیدشده هستند: Dump پایگاه دادهٔ Local به‌علاوهٔ Patchهای دقیق، که تعداد تطابق هر کدام Assert شده است. بازبینی بهتر است روی `gen_migration.py` و `common.py` انجام شود.

## ۲. تغییرات نسخهٔ هشتم

### ۲.۱ Workflow فعال: فقط چهار وضعیت

در صف انجام (۱)، در حال بررسی (۲)، انجام‌شده (۳)، رد نهایی (۴). «نیازمند اصلاح» تصمیم است، «مسدود» Flag، و «انجام‌نشده» (`todo`) و «در حال انجام» (`in_progress`) Status نیستند.

این بخش از نسخه‌های قبل در SQL بود و در این نسخه دوباره بازبینی شد:

| الزام | محل در Draft |
|---|---|
| `todo` و `in_progress` غیرفعال، بدون حذف فیزیکی | بخش ۶ Migration: `is_active = s.key not in (RETIRED)`، با قبل و بعد در `workflow_status_changes`. هیچ DELETE روی `workflow_statuses` نیست. |
| ساخت و فعال‌سازی دوباره ممکن نباشد | `save_workflow_status`: `category_retired`. `app.seed_workflow`: فقط چهار وضعیت. کلاینت روی `workflow_statuses` فقط سیاست SELECT دارد. |
| تسک‌های `todo` → backlog | Plan: `todo`، `in_progress` و `changes_requested` → `backlog`. **R8:** امروز در هر ۵ Workflow صفر تسک در `todo` و `in_progress` است. تسک تازه در آن‌ها Guard را متوقف می‌کند تا ردیفش بازبینی شود. |
| تاریخچه بازنویسی نشود | فقط INSERT در Log و Event `task.migrated`؛ Eventها Trigger تغییرناپذیری دارند. |

### ۲.۲ گروه «رد شده» = «رد نهایی» + «مسدود»

| تابع | تعریف | ردشده | مسدود |
|---|---|---|---|
| `app.task_counts_complete` | **بدون تغییر** (بدنه در بخش ۵) | false | false |
| `app.task_is_unresolved` (**جدید**) | بایگانی‌نشده، تکمیل‌نشده، دستهٔ آن rejected نیست | false | **true** |
| `app.task_is_open` (**بازتعریف**) | `task_is_unresolved(p) and blocked_at is null` | false | false |

هر دو `LANGUAGE sql`، `SECURITY INVOKER`، `search_path = ''` هستند، EXECUTE از همهٔ نقش‌های کلاینت گرفته شده، و در خودآزمایی ACL هستند.

| رفتار خواسته‌شده | پیاده‌سازی |
|---|---|
| خارج از کارهای باز، Active و Overdue | ۱۳ فراخوانی `app.task_is_open(t.id)`: `app.dashboard_summary_v1` (۵)، `dashboard_projects` (۱)، `dashboard_team` (۲)، `dashboard_people` (۱)، `dashboard_personal` (۲)، `work_analytics` (۲: `remaining`، `overdue`). |
| خارج از Remaining اسپرینت و مایلستون | `project_sprint_counts` و `project_milestone_counts`: ستون‌های `blocked` و `rejected`. `set_sprint_status`: `remaining = total - complete - rejected - blocked`. ردیف‌های اسپرینت و مایلستون `work_analytics`: `rejected`، `blocked` و `remaining` بدون آن‌ها. |
| شمارش جدای Final Rejected و Blocked | `work_analytics`: کلیدهای کلی `rejected` و `blocked` و همین دو برای هر اسپرینت و مایلستون. `dashboard_personal`: `rejected_tasks` و `blocked_tasks` برای گروه «رد شده» در Home. |
| «مسدود» درست شمرده شود | `(category = 'blocked' or blocked_at is not null) and app.task_is_unresolved(t.id)`. |
| حذف عضو: نه با `task_is_open` تنها | `app.open_tasks_of_member` و `project_member_open_tasks` → `app.task_is_unresolved`. تسک مسدود همچنان مانع حذف است؛ ردشده نه (تصمیم نسخهٔ هفتم). بررسی استاتیک این را اجبار می‌کند. |
| زیرتسک اجباری مسدود یا ردشده مانع والد | بدون تغییر: `task_children_block_done` بر پایهٔ تکمیل است. Override فقط `tasks.manage.project` یا super admin، با `p_override_reason` مستقل و Audit `task.override_subtasks`. |
| انتقال باقی‌ماندهٔ اسپرینت و رسیدن به مایلستون | `app.task_is_unresolved`: مسدود منتقل می‌شود و مایلستون را بدون دلیل Override نمی‌بندد. ردشده نه. **نکتهٔ ۱ در بخش ۷.** |

### ۲.۳ رفع انسداد و بازگشایی

- `clear_task_blocked`: رفتار بدون تغییر. فقط سه ستون Flag پاک می‌شوند و یک رویداد `unblocked` ثبت می‌شود. Status، دور باز، `round_number`، `approval_state` و تاریخچه دست نمی‌خورند. تسک در همان ستون قبلی است.
- `transition_task` از rejected:
  - مقصد غیر backlog → `reopen_backlog_only`.
  - Event `task.reopen` و Audit `task.reopen` با `from` و `to` (به‌علاوهٔ `task.transition` معمول).
  - `approval_state` برای تسک نیازمند تأیید → `pending`.
  - مجوز مثل امروز (`rejected_closed`).

### ۲.۴ دو اشکال نسخهٔ هفتم که رفع شد

1. **ترتیب ساخت:** `app.open_tasks_of_member` (`LANGUAGE sql`) پیش از `app.task_is_open` ساخته می‌شد. بدنهٔ تابع SQL هنگام CREATE اعتبارسنجی می‌شود (`check_function_bodies`)، پس Migration نسخهٔ هفتم در همان دستور متوقف می‌شد. اکنون `task_is_unresolved` و `task_is_open` پیش از آن ساخته می‌شوند. بررسی جدید «ترتیب ساخت» روی ترتیب نسخهٔ هفتم خطا می‌دهد (آزمون منفی در Scratchpad).
2. **ردیف‌های اسپرینت و مایلستون در `work_analytics`** (منبع خروجی گزارش اسپرینت و مایلستون) ردشده را باقی‌مانده می‌شمردند. اکنون هم ردشده و هم مسدود جدا هستند.

### ۲.۵ بدون تغییر

- Guard و Pinned State (۱۵ ستون، چهار تسک): `common.py` بایت‌به‌بایت همان نسخهٔ هفتم است.
- نگاشت `ttt` (changes_requested → backlog).
- استثناهای `vvvvvvv` و `rgdfdgf` و Guard دقیق آن‌ها.
- عضویت، Snapshot، Review، قفل‌ها، Override، سیاست همکار، سخت‌گیری restricted، مرز اعتماد تاریخچه، و سیاست Rollback.

## ۳. محیط (خوانده‌شده)

- PostgreSQL 17.11 (Supabase Local). PostgREST فقط `public` و `graphql_public` را منتشر می‌کند.
- `postgres` مالک اشیا است و Superuser نیست. اجازهٔ `session_replication_role` دارد.
- Default Privileges و جزئیات `service_role` مثل نسخهٔ ششم.
- ACL واقعی توابع بازگردانده‌شده خوانده و در Rollback عیناً تکرار شده است. `app.dashboard_summary_v1` فقط برای `postgres` است.

## ۴. وضعیت دادهٔ واقعی (گزارش فقط‌خواندنی، 2026-11-09، نسخهٔ هشتم)

| تسک | تصمیم | project_id | workflow_id | status_id |
|---|---|---|---|---|
| `ttt` (`f4725489…`) | changes_requested → backlog | — | `397a6e0a…` | `e0655322…` |
| «لندینگ باگ بانتی» (`30445be8…`) | approved → done | — | `397a6e0a…` | `e7216b79…` |
| `vvvvvvv` (`cf890d3d…`) | excluded | — | `397a6e0a…` | `e7216b79…` |
| `rgdfdgf` (`47d8d5a3…`) | excluded | `c4fa2aef…` «باگ بانتی» | `92986332…` | `6aa7533b…` |

- Integrity: rgdfdgf `assignee_not_member` و vvvvvvv `personal_created_for_other` (فقط گزارش).
- **R8:** `todo` و `in_progress` در هر ۵ Workflow صفر تسک دارند. تنها تسکی که پس از Migration در وضعیت بازنشسته می‌ماند، `vvvvvvv` (excluded، در approved) است.
- **R7: خالی.**

## ۵. بدنهٔ دو تابع کمکی (بدون تغییر در Migration)

`app.task_children_block_done` (SHA-256 Dump: `a205f160…`) و `app.task_counts_complete` (SHA-256 Dump: `6de918f4…`):

```sql
-- task_children_block_done(p_task): a required, non-archived child that is not
-- (done/approved) or still needs an approval it has not got
select exists (select 1 from public.tasks child join public.workflow_statuses st on st.id = child.status_id
  where child.parent_task_id = p_task and child.is_required and child.archived_at is null
    and (st.category not in ('done', 'approved') or (child.approval_required and child.approval_state <> 'approved')));

-- task_counts_complete(p_task): not archived, done/approved, approval satisfied
select exists (select 1 from public.tasks t join public.workflow_statuses s on s.id = t.status_id
  where t.id = p_task and t.archived_at is null and s.category in ('done', 'approved')
    and (t.approval_required = false or t.approval_state = 'approved'));
```

دو تابع جدید (متن کامل در Migration):

```sql
-- app.task_is_unresolved(p_task)
select exists (select 1 from public.tasks t join public.workflow_statuses s on s.id = t.status_id
  where t.id = p_task and t.archived_at is null and s.category <> 'rejected')
  and not app.task_counts_complete(p_task);

-- app.task_is_open(p_task)
select app.task_is_unresolved(p_task)
   and exists (select 1 from public.tasks t where t.id = p_task and t.blocked_at is null);
```

## ۶. بررسی‌های انجام‌شده (بدون اجرای Migration)

| بررسی | نتیجه |
|---|---|
| Parser PostgreSQL (`pglast`) | Migration ۱۸۸ دستور و ۴۴ بدنهٔ PL/pgSQL؛ Rollback ۱۲۲ و ۲۸؛ Report ۱۲ — بدون خطا |
| Lint امنیتی | `search_path = ''`؛ Revoke برای هر تابع جدید (از جمله `app.task_is_unresolved`)؛ بدون Grant عمومی؛ بدون تغییر `profiles` |
| ارجاع‌ها | ۱۲۰ ارجاع با Catalog زنده |
| **ترتیب ساخت (جدید)** | ۱۱ بدنهٔ `LANGUAGE sql`: هر تابع فراخوانده‌شده زنده است یا پیش‌تر ساخته شده |
| **وضعیت‌های بازنشسته (جدید)** | Seed هیچ دستهٔ بازنشسته‌ای ندارد؛ `category_retired` هر پنج را رد می‌کند؛ بیرون از Plan و طبقه‌بندی Workflow قدیمی، `'todo'` یا `'in_progress'` فقط در خود غیرفعال‌سازی، رد D7، فهرست دسته‌های معتبر و وضعیت مایلستون آمده است |
| **حذف عضو (جدید)** | دو تابع B3 از `task_is_unresolved` استفاده می‌کنند و `task_is_open` ندارند |
| Rollback | MD5 هر **۲۷** بدنهٔ اصلی = `prosrc` زنده؛ `app.task_is_unresolved` و `app.task_is_open` حذف می‌شوند |
| Report | R7 خالی؛ R8 مطابق بالا |
| حضور بندها در SQL | ۱۳ فراخوانی `app.task_is_open(t.id)` و ۱۴ `app.task_is_unresolved(`؛ صفر `not app.task_counts_complete(t.id)`؛ `reopen_backlog_only`؛ `task.reopen` (Event و Audit)؛ `rejected_tasks` و `blocked_tasks` |
| پایگاه دادهٔ Local پس از همهٔ بررسی‌ها | بدون تغییر: `task_is_open` و `task_is_unresolved` وجود ندارند؛ `task_revision_requests` وجود ندارد؛ `decide_task(p_task, p_decision, p_reason)` قدیمی؛ `project_sprint_counts` چهارستونی؛ ۵ وضعیت `todo` فعال؛ آخرین Migration همان `20261108120000_dashboard_split.sql` |

**نکتهٔ اجرا:** گزارش باید با Redirect بایت‌به‌بایت (`<` در bash) اجرا شود. Pipe در PowerShell متن فارسی SQL را دوباره Encode می‌کند و R7 تفاوت کاذب نشان می‌دهد. این در README Generator ثبت شد.

## ۷. نقاطی که بازبینی دقیق‌تر لازم دارند

1. **تسک مسدود در انتقال باقی‌ماندهٔ اسپرینت و رسیدن به مایلستون:** Draft آن را «کار حل‌نشده» می‌داند. پس منتقل می‌شود و مایلستون را بدون دلیل نمی‌بندد، در حالی که در Remaining شمرده نمی‌شود. دلیل: پس از رفع انسداد تسک به ستونش برمی‌گردد و در اسپرینت بسته‌شده رها نمی‌شود. اگر باید مثل «رد نهایی» رفتار کند، فقط این دو Patch به `task_is_open` تغییر می‌کنند.
2. **مجوز بازگشایی «رد نهایی»** همان مجوز امروز است (`tasks.manage.project` یا `tasks.view.all`). Override در نسخهٔ ششم به `tasks.manage.project` یا super admin محدود شد. محدود کردن بازگشایی تصمیم جداگانه است.
3. **«نیازمند اصلاح» و مسدود با هم:** شمارش `needs_revision` یا `revision` از `approval_state` خوانده می‌شود. تسکی که هر دو باشد در هر دو شمرده می‌شود (هم در «نیازمند اصلاح» و هم در گروه «رد شده»).
4. **تغییر نوع خروجی** `project_sprint_counts` و `project_milestone_counts` (ستون‌های `blocked` و `rejected`): Drop و Create دوباره در یک Transaction با همان Grantها.
5. **موارد نسخه‌های قبل که هنوز باز هستند:** کفایت قفل‌ها، ترتیب قفل والد و فرزند، `stale_round`، و Rollback.

## ۸. کار UI و آزمون که باید هم‌زمان با Migration انجام شود (خارج از این SQL)

فهرست کامل با شمارهٔ خط در بخش ۱۷ طرح. خلاصه:
- **Workflow:** دسته‌های قابل‌انتخاب (`project_pages.dart:46`) فقط چهار دسته. پیش‌فرض وضعیت جدید (`project_pages.dart:926`) و Fallback دسته (`work_repository.dart:556`) `backlog` شود، نه `todo`. کلید روشن کردن برای دسته‌های بازنشسته غیرفعال شود.
- **Home و کارهای من:** `assignedOpen` ردشده و مسدود را کنار بگذارد. بخش «رد شده» با دو برچسب «رد نهایی» و «مسدود»، شمارش از `dashboard_personal`، و فهرست و جزئیات.
- **Kanban:** کارت مسدود در گروه «رد شده» دیده شود و پس از رفع انسداد در همان ستون.
- **اسپرینت، مایلستون و گزارش:** `PlanCounts` و ستون‌های گزارش، `rejected` و `blocked` را جدا نشان دهند و `remaining` بدون آن‌ها باشد.
- **همکار:** فرم افزودن فقط برای مسئول، مدیر پروژه، `tasks.manage.project` یا super admin.
- **برچسب‌های دسته‌های بازنشسته** (`work_ui.dart`، `fa.dart`) فقط برای نمایش تاریخچه و وضعیت‌های غیرفعال می‌مانند.
- **آزمون‌ها:** `supabase/tests/critical.sql` و `dashboard_split.sql`، و آزمون‌های Flutter با دستهٔ todo و in_progress، با گردش جدید بازنویسی شوند.

## ۹. مراحل پس از تأیید نهایی (فقط با مجوز)

1. پشتیبان‌گیری Local.
2. توقف API و اطمینان از نبود تراکنش باز.
3. اجرای Report: R7 خالی و R8 مطابق انتظار.
4. Migration روی Local.
5. آزمون‌های M (تا M6)، A (تا A71)، C، V و R.
6. راه‌اندازی دوبارهٔ API؛ سپس به‌روزرسانی UI و آزمون‌ها.
