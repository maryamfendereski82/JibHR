-- Default catalog and one workspace. Roles are data: a super admin can edit
-- them later. The permission keys are the stable contract the policies use.

insert into public.workspaces (id, name)
values ('a0000000-0000-4000-8000-000000000001', 'جیبکارت');

insert into public.permissions (key, module, action, scope, description)
values
  ('employees.view.self', 'employees', 'view', 'self', 'مشاهده پرونده خود'),
  ('employees.view.team', 'employees', 'view', 'team', 'مشاهده اعضای تیم تحت مدیریت'),
  ('employees.view.all', 'employees', 'view', 'all', 'مشاهده همه کارمندان'),
  ('employees.create', 'employees', 'create', 'all', 'ایجاد حساب و دعوت کارمند'),
  ('employees.deactivate', 'employees', 'archive', 'all', 'فعال یا غیرفعال کردن حساب'),
  ('teams.view', 'teams', 'view', 'all', 'مشاهده تیم‌ها'),
  ('teams.create', 'teams', 'create', 'all', 'ایجاد تیم'),
  ('teams.archive', 'teams', 'archive', 'all', 'غیرفعال یا بایگانی تیم'),
  ('teams.members.manage.team', 'teams', 'manage', 'team', 'عضویت تیم خود'),
  ('teams.members.manage.all', 'teams', 'manage', 'all', 'عضویت همه تیم‌ها'),
  ('teams.managers.assign', 'teams', 'manage', 'all', 'تعیین مدیر، سرپرست و جانشین'),
  ('positions.manage', 'positions', 'manage', 'all', 'تعریف سمت شغلی'),
  ('roles.view', 'roles', 'view', 'all', 'مشاهده نقش‌ها'),
  ('roles.manage', 'roles', 'manage', 'all', 'ساخت و ویرایش نقش'),
  ('roles.assign', 'roles', 'manage', 'all', 'دادن نقش به کاربر'),
  ('projects.view.all', 'projects', 'view', 'all', 'مشاهده همه پروژه‌ها'),
  ('projects.create', 'projects', 'create', 'all', 'ایجاد پروژه'),
  ('projects.edit', 'projects', 'edit', 'all', 'ویرایش پروژه'),
  ('projects.archive', 'projects', 'archive', 'all', 'بایگانی پروژه'),
  ('tasks.create.personal', 'tasks', 'create', 'self', 'ساخت تسک شخصی'),
  ('tasks.create.project', 'tasks', 'create', 'project', 'ساخت تسک پروژه‌ای'),
  ('tasks.manage.project', 'tasks', 'manage', 'project', 'مدیریت تسک و اسپرینت'),
  ('tasks.view.all', 'tasks', 'view', 'all', 'مشاهده تسک‌های شخصی دیگران'),
  ('attendance.view.self', 'attendance', 'view', 'self', 'مشاهده حضور خود'),
  ('attendance.view.team', 'attendance', 'view', 'team', 'مشاهده حضور تیم'),
  ('attendance.view.all', 'attendance', 'view', 'all', 'مشاهده حضور همه'),
  ('attendance.clock', 'attendance', 'create', 'self', 'ثبت ورود و خروج'),
  ('attendance.approve.team', 'attendance', 'approve', 'team', 'تأیید حضور تیم'),
  ('attendance.approve.all', 'attendance', 'approve', 'all', 'تأیید حضور همه'),
  ('attendance.correct.self', 'attendance', 'edit', 'self', 'درخواست اصلاح حضور'),
  ('leave.view.self', 'leave', 'view', 'self', 'مشاهده مرخصی خود'),
  ('leave.view.team', 'leave', 'view', 'team', 'مشاهده مرخصی تیم'),
  ('leave.view.all', 'leave', 'view', 'all', 'مشاهده همه مرخصی‌ها'),
  ('leave.request', 'leave', 'create', 'self', 'ثبت درخواست مرخصی'),
  ('leave.approve.team', 'leave', 'approve', 'team', 'تأیید مرخصی تیم'),
  ('leave.approve.all', 'leave', 'approve', 'all', 'تأیید همه مرخصی‌ها'),
  ('absence.view.self', 'absence', 'view', 'self', 'مشاهده غیبت خود'),
  ('absence.view.team', 'absence', 'view', 'team', 'مشاهده غیبت تیم'),
  ('absence.view.all', 'absence', 'view', 'all', 'مشاهده همه غیبت‌ها'),
  ('absence.record.team', 'absence', 'create', 'team', 'ثبت غیبت تیم'),
  ('absence.record.all', 'absence', 'create', 'all', 'ثبت غیبت همه'),
  ('reports.view.self', 'reports', 'view', 'self', 'گزارش فردی'),
  ('reports.view.team', 'reports', 'view', 'team', 'گزارش تیمی'),
  ('reports.view.all', 'reports', 'view', 'all', 'گزارش کل شرکت'),
  ('reports.export.team', 'reports', 'export', 'team', 'خروجی گزارش تیم'),
  ('reports.export.project', 'reports', 'export', 'project', 'خروجی گزارش پروژه‌های مجاز'),
  ('reports.export.all', 'reports', 'export', 'all', 'خروجی گزارش کل'),
  ('settings.manage', 'settings', 'manage', 'all', 'تنظیمات برنامه'),
  ('audit.view', 'audit', 'view', 'all', 'مشاهده ممیزی'),
  ('notifications.view.self', 'notifications', 'view', 'self', 'مشاهده اعلان‌های خود');

insert into public.roles (workspace_id, key, name, is_system)
values
  ('a0000000-0000-4000-8000-000000000001', 'super_admin', 'سوپر ادمین', true),
  ('a0000000-0000-4000-8000-000000000001', 'general_admin', 'ادمین کل', true),
  ('a0000000-0000-4000-8000-000000000001', 'team_manager', 'مدیر تیم', true),
  ('a0000000-0000-4000-8000-000000000001', 'team_supervisor', 'سرپرست تیم', true),
  ('a0000000-0000-4000-8000-000000000001', 'project_manager', 'مدیر پروژه', true),
  ('a0000000-0000-4000-8000-000000000001', 'employee', 'کارمند', true);

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
join public.permissions p on true
where r.key = 'super_admin';

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
join public.permissions p on p.key <> 'roles.manage'
where r.key = 'general_admin';

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
join public.permissions p on p.key = any (array[
  'employees.view.self', 'tasks.create.personal',
  'attendance.view.self', 'attendance.clock', 'attendance.correct.self',
  'leave.view.self', 'leave.request', 'absence.view.self',
  'reports.view.self', 'notifications.view.self'
])
where r.key = 'employee';

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
join public.permissions p on p.key = any (array[
  'employees.view.self', 'employees.view.team', 'tasks.create.personal',
  'attendance.view.self', 'attendance.view.team', 'attendance.clock', 'attendance.correct.self',
  'attendance.approve.team',
  'leave.view.self', 'leave.view.team', 'leave.request', 'leave.approve.team',
  'absence.view.self', 'absence.view.team', 'absence.record.team',
  'reports.view.self', 'reports.view.team', 'notifications.view.self'
])
where r.key = 'team_supervisor';

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
join public.permissions p on p.key = any (array[
  'employees.view.self', 'employees.view.team', 'tasks.create.personal',
  'tasks.create.project', 'tasks.manage.project',
  'teams.members.manage.team', 'projects.create', 'projects.edit',
  'attendance.view.self', 'attendance.view.team', 'attendance.clock', 'attendance.correct.self',
  'attendance.approve.team',
  'leave.view.self', 'leave.view.team', 'leave.request', 'leave.approve.team',
  'absence.view.self', 'absence.view.team', 'absence.record.team',
  'reports.view.self', 'reports.view.team', 'reports.export.team',
  'notifications.view.self'
])
where r.key = 'team_manager';

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
join public.permissions p on p.key = any (array[
  'employees.view.self', 'tasks.create.personal', 'tasks.create.project', 'tasks.manage.project',
  'projects.create', 'projects.edit',
  'attendance.view.self', 'attendance.clock', 'attendance.correct.self',
  'leave.view.self', 'leave.request', 'absence.view.self',
  'reports.view.self', 'reports.export.project', 'notifications.view.self'
])
where r.key = 'project_manager';

select app.seed_workflow('a0000000-0000-4000-8000-000000000001', null);

insert into public.app_settings (workspace_id, key, value)
values
  ('a0000000-0000-4000-8000-000000000001', 'timezone', '"Asia/Tehran"'),
  ('a0000000-0000-4000-8000-000000000001', 'week_start', '"saturday"'),
  ('a0000000-0000-4000-8000-000000000001', 'locale', '"fa"');
