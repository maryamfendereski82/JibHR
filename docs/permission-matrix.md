# ماتریس دسترسی

مجوزها ردیف جدول `permissions` هستند. نقش پیش‌فرض فقط داده اولیه است و سوپر ادمین می‌تواند نقش تازه بسازد. نقش سیستم `super_admin` را نمی‌توان غیرفعال کرد و باید `roles.manage` و `roles.assign` را نگه دارد.

مخفی کردن دکمه کافی نیست. تابع‌ها `app.require_permission` یا معادل دامنه‌ای را صدا می‌زنند و RLS خواندن را محدود می‌کند.

## دامنه

`self` فقط رکورد خود شخص است. `team` نیاز به مجوز تیمی و بودن در نقش مدیر، سرپرست یا جانشین همان تیم اصلی کارمند دارد. `all` کل فضای کار است. تصمیم جانشین در این نسخه مثل مدیر و سرپرست برای تأیید پذیرفته می‌شود.

## نقش‌های اولیه

| مجوز | کارمند | سرپرست | مدیر تیم | مدیر پروژه | ادمین کل | سوپر ادمین |
|---|---|---|---|---|---|---|
| employees.view.self | yes | yes | yes | yes | yes | yes |
| employees.view.team | | yes | yes | | yes | yes |
| employees.view.all / create / deactivate | | | | | yes | yes |
| teams.members.manage.team | | | yes | | yes | yes |
| teams.members.manage.all / teams.create / teams.archive | | | | | yes | yes |
| teams.managers.assign | | | | | yes | yes |
| positions.manage | | | | | yes | yes |
| roles.view / roles.assign | | | | | yes | yes |
| roles.manage | | | | | | yes |
| projects.create / projects.edit | | | yes | yes | yes | yes |
| projects.view.all / projects.archive | | | | | yes | yes |

`projects.edit` به‌تنهایی تنظیمات هر پروژه‌ای را باز نمی‌کند. تابع `app.can_edit_project` مدیر همان پروژه یا دارنده `projects.view.all` را می‌خواهد. کارمند عضو، پروژه را ویرایش نمی‌کند.
| tasks.create.personal | yes | yes | yes | yes | yes | yes |
| tasks.create.project / tasks.manage.project | | | yes | yes | yes | yes |

اسپرینت و مایلستون کلید جدا ندارند. دیدن با `can_view_project` است. ساخت، ویرایش، بستن، لغو، پیوند تسک و عبور از تسک ناتمام `tasks.manage.project` به‌علاوه `can_edit_project` می‌خواهد. شرح مجوز موجود «مدیریت تسک و اسپرینت» است.
| tasks.view.all | | | | | yes | yes |
| attendance.view.self / clock / correct.self | yes | yes | yes | yes | yes | yes |
| attendance.view.team / approve.team | | yes | yes | | yes | yes |
| attendance.view.all / approve.all | | | | | yes | yes |
| leave و absence خود | yes | yes | yes | yes | yes | yes |
| leave و absence تیم و تأیید یا ثبت تیمی | | yes | yes | | yes | yes |
| reports.view.team | | yes | yes | | yes | yes |
| reports.export.team | | | yes | | yes | yes |
| reports.view.all / export.all / settings / audit | | | | | yes | yes |

ادمین کل همه مجوزها را دارد به‌جز `roles.manage`. دادن نقش `super_admin` فقط از دست سوپر ادمین فعلی ممکن است.

`public.report_export` کلید `reports.export.team`، `reports.export.project` و `reports.export.all` را در `app.assert_report_export` چک می‌کند. داده خود کاربر با `reports.view.self` هم بیرون می‌رود. `reports.export.project` فقط وقتی شناسه یک پروژه دیده‌شده باشد قبول می‌شود و خروجی بدون پروژه را به مدیر پروژه نمی‌دهد.

صندوق اعلان کلید تازه ندارد. `notifications.view.self` در نقش‌های اولیه هست، ولی سیاست خواندن فقط `recipient_id` را می‌سنجد. کاربر واردشده نمی‌تواند ردیف اعلان درج کند.
