-- Critical paths for attendance, access, and task approval.
-- Runs after migrations on the local Postgres stub, as the postgres user.

\set admin a1111111-1111-4111-8111-111111111111
\set manager a2222222-2222-4222-8222-222222222222
\set employee a3333333-3333-4333-8333-333333333333
\set peer a4444444-4444-4444-8444-444444444444
\set manager2 a5555555-5555-4555-8555-555555555555
\set workspace a0000000-0000-4000-8000-000000000001

insert into auth.users (id, email) values
  (:'admin', 'admin@jibcart.test'),
  (:'manager', 'manager@jibcart.test'),
  (:'employee', 'employee@jibcart.test'),
  (:'peer', 'peer@jibcart.test'),
  (:'manager2', 'manager2@jibcart.test');

insert into public.profiles (id, workspace_id, first_name, last_name)
values
  (:'admin', :'workspace', 'ادمین', 'سیستم'),
  (:'manager', :'workspace', 'مدیر', 'تیم'),
  (:'employee', :'workspace', 'کارمند', 'یک'),
  (:'peer', :'workspace', 'کارمند', 'دو'),
  (:'manager2', :'workspace', 'مدیر', 'دوم');

insert into public.profile_accounts (profile_id, workspace_id, username, email)
values
  (:'admin', :'workspace', 'admin', 'admin@jibcart.test'),
  (:'manager', :'workspace', 'manager', 'manager@jibcart.test'),
  (:'employee', :'workspace', 'employee', 'employee@jibcart.test'),
  (:'peer', :'workspace', 'peer', 'peer@jibcart.test'),
  (:'manager2', :'workspace', 'manager2', 'manager2@jibcart.test');

insert into public.user_roles (workspace_id, profile_id, role_id)
select :'workspace', :'admin', id from public.roles where key = 'super_admin';
insert into public.user_roles (workspace_id, profile_id, role_id)
select :'workspace', :'manager', id from public.roles where key = 'team_manager';
insert into public.user_roles (workspace_id, profile_id, role_id)
select :'workspace', :'manager2', id from public.roles where key = 'team_manager';
insert into public.user_roles (workspace_id, profile_id, role_id)
select :'workspace', :'employee', id from public.roles where key = 'employee';
insert into public.user_roles (workspace_id, profile_id, role_id)
select :'workspace', :'peer', id from public.roles where key = 'employee';

-- Calendar anchors and the Saturday week.
do $$
declare
  v_parts record;
  v_back date;
  v_sat date;
  v_bounds record;
  d date;
begin
  if app.jalali_to_gregorian(1403, 1, 1) <> date '2024-03-20' then
    raise exception 'nowruz 1403';
  end if;
  -- Anchors from the algorithmic Jalaali calendar (jalaali-js / shamsi_date).
  -- 1403 is the 366-day year, so 1 Farvardin 1404 is 21 March 2025.
  if app.jalali_to_gregorian(1404, 1, 1) <> date '2025-03-21' then
    raise exception 'nowruz 1404';
  end if;
  if app.jalali_to_gregorian(1405, 1, 1) <> date '2026-03-21' then
    raise exception 'nowruz 1405';
  end if;
  select * into v_bounds from app.jalali_month_bounds(1403, 12);
  if v_bounds.end_date <> date '2025-03-20' then
    raise exception '1403 esfand should have 30 days, end %', v_bounds.end_date;
  end if;
  select * into v_bounds from app.jalali_month_bounds(1404, 12);
  if v_bounds.end_date <> date '2026-03-20' then
    raise exception '1404 esfand should have 29 days, end %', v_bounds.end_date;
  end if;
  for d in select generate_series(date '2024-03-19', date '2027-03-22', interval '1 day')::date loop
    select * into v_parts from app.gregorian_to_jalali(d);
    v_back := app.jalali_to_gregorian(v_parts.jy, v_parts.jm, v_parts.jd);
    if v_back <> d then
      raise exception 'jalali roundtrip failed for %', d;
    end if;
  end loop;

  v_sat := app.week_start(date '2026-11-05');
  if extract(dow from v_sat) <> 6 then
    raise exception 'week does not start on saturday';
  end if;
  if app.week_start(v_sat + 6) <> v_sat or app.week_start(v_sat + 7) <> v_sat + 7 then
    raise exception 'week length is not saturday through friday';
  end if;
end
$$;

select set_config('request.jwt.claim.sub', :'admin', false);
select set_config('request.jwt.claim.email', 'admin@jibcart.test', false);
set role authenticated;
select public.create_team('فلاتر') as team_id \gset
select public.add_team_member(:'manager', :'team_id'::uuid, true);
select public.add_team_member(:'manager2', :'team_id'::uuid, true);
select public.add_team_member(:'employee', :'team_id'::uuid, true);
select public.add_team_member(:'peer', :'team_id'::uuid, true);
select public.assign_team_leadership(:'manager', :'team_id'::uuid, 'manager');
select public.assign_team_leadership(:'manager2', :'team_id'::uuid, 'supervisor');
reset role;

-- Last super admin cannot be removed or deactivated.
select set_config('request.jwt.claim.sub', :'admin', false);
set role authenticated;
do $$
begin
  perform public.revoke_user_role('a1111111-1111-4111-8111-111111111111', 'super_admin');
  raise exception 'last super admin was revoked';
exception when others then
  if sqlerrm <> 'last_super_admin' then raise; end if;
end
$$;
do $$
begin
  perform public.set_employee_status('a1111111-1111-4111-8111-111111111111', 'inactive');
  raise exception 'last super admin was deactivated';
exception when others then
  if sqlerrm <> 'last_super_admin' then raise; end if;
end
$$;
reset role;

-- Live clock: server time, one open interval, two platforms.
select set_config('request.jwt.claim.sub', :'employee', false);
set role authenticated;
select public.clock_in('web') as open_id \gset
do $$
declare
  v_started timestamptz;
  v_platform text;
begin
  select original_started_at, start_platform into v_started, v_platform
  from public.attendance_intervals
  where profile_id = auth.uid() and status = 'open';
  if v_platform <> 'web' then
    raise exception 'platform not stored';
  end if;
  if abs(extract(epoch from (clock_timestamp() - v_started))) > 10 then
    raise exception 'clock-in did not use server time';
  end if;
end
$$;
do $$
begin
  perform public.clock_in('ios');
  raise exception 'second clock-in was accepted';
exception when others then
  if sqlerrm <> 'open_interval' then raise; end if;
end
$$;
do $$
begin
  insert into public.attendance_intervals (
    workspace_id, profile_id, origin, status, original_started_at, effective_started_at
  ) values (
    'a0000000-0000-4000-8000-000000000001', auth.uid(), 'clock', 'open', clock_timestamp(), clock_timestamp()
  );
  raise exception 'direct insert was accepted';
exception when insufficient_privilege then
  null;
end
$$;
select pg_sleep(1);
select public.clock_out('macos');
do $$
declare
  v_end_platform text;
begin
  select end_platform into v_end_platform
  from public.attendance_intervals
  where profile_id = auth.uid() and status = 'closed'
  order by original_started_at desc
  limit 1;
  if v_end_platform <> 'macos' then
    raise exception 'clock-out platform missing';
  end if;
end
$$;
select public.clock_in('android');
select pg_sleep(1);
select public.clock_out('windows');
select public.submit_attendance_report(app.tehran_today()) as report_id \gset
do $$
declare
  v_again uuid;
  v_count integer;
begin
  v_again := public.submit_attendance_report(app.tehran_today());
  if v_again is not null then
    raise exception 'manual submit was not idempotent';
  end if;
  select count(*) into v_count from public.attendance_report_items ri
  join public.attendance_daily_reports r on r.id = ri.report_id
  where r.profile_id = auth.uid() and r.tehran_date = app.tehran_today() and r.sequence = 1;
  if v_count <> 2 then
    raise exception 'expected 2 intervals on the first report, got %', v_count;
  end if;
end
$$;
reset role;

-- Employee cannot decide. First manager approves one item and rejects the other.
select set_config('request.jwt.claim.sub', :'employee', false);
set role authenticated;
do $$
declare
  v_item uuid;
begin
  select ri.id into v_item
  from public.attendance_report_items ri
  join public.attendance_daily_reports r on r.id = ri.report_id
  where r.profile_id = auth.uid()
  limit 1;
  perform public.decide_attendance_item(v_item, 'approved');
  raise exception 'employee approved an item';
exception when others then
  if sqlerrm <> 'forbidden' then raise; end if;
end
$$;
reset role;

select set_config('request.jwt.claim.sub', :'manager', false);
set role authenticated;
do $$
declare
  v_first uuid;
  v_second uuid;
  v_profile uuid := 'a3333333-3333-4333-8333-333333333333';
begin
  select ri.id into v_first
  from public.attendance_report_items ri
  join public.attendance_daily_reports r on r.id = ri.report_id
  where r.profile_id = v_profile and r.sequence = 1
  order by ri.id
  limit 1;
  select ri.id into v_second
  from public.attendance_report_items ri
  join public.attendance_daily_reports r on r.id = ri.report_id
  where r.profile_id = v_profile and r.sequence = 1 and ri.id <> v_first
  order by ri.id
  limit 1;
  perform public.decide_attendance_item(v_first, 'approved', null);
  perform public.decide_attendance_item(v_second, 'rejected', 'بازه نامعتبر است');
end
$$;
do $$
declare
  v_first uuid;
begin
  select ri.id into v_first
  from public.attendance_report_items ri
  join public.attendance_daily_reports r on r.id = ri.report_id
  where r.profile_id = 'a3333333-3333-4333-8333-333333333333' and r.sequence = 1
  order by ri.id
  limit 1;
  perform public.decide_attendance_item(v_first, 'rejected', 'دوباره');
  raise exception 'second decision was accepted';
exception when others then
  if sqlerrm <> 'already_decided' then raise; end if;
end
$$;
do $$
declare
  v_profile uuid := 'a3333333-3333-4333-8333-333333333333';
  v_status text;
  v_approved bigint;
  v_rejected bigint;
  v_rows integer;
begin
  select status into v_status
  from public.attendance_daily_reports
  where profile_id = v_profile and sequence = 1 and tehran_date = app.tehran_today();
  if v_status <> 'partially_approved' then
    raise exception 'report status %, expected partially_approved', v_status;
  end if;
  select approved_seconds, rejected_seconds into v_approved, v_rejected
  from public.attendance_totals(v_profile, app.tehran_today(), app.tehran_today());
  if v_approved <= 0 or v_rejected <= 0 then
    raise exception 'approved % rejected %', v_approved, v_rejected;
  end if;
  select count(*) into v_rows from public.attendance_report_items ri
  join public.attendance_daily_reports r on r.id = ri.report_id
  where r.profile_id = v_profile and r.sequence = 1;
  if v_rows <> 2 then
    raise exception 'rejection removed a row';
  end if;
end
$$;
reset role;

-- The other manager cannot override the first decision.
select set_config('request.jwt.claim.sub', :'manager2', false);
set role authenticated;
do $$
declare
  v_item uuid;
begin
  select ri.id into v_item
  from public.attendance_report_items ri
  join public.attendance_daily_reports r on r.id = ri.report_id
  where r.profile_id = 'a3333333-3333-4333-8333-333333333333' and r.sequence = 1
  limit 1;
  perform public.decide_attendance_item(v_item, 'rejected', 'نظر دیگر');
  raise exception 'second manager overrode the decision';
exception when others then
  if sqlerrm <> 'already_decided' then raise; end if;
end
$$;
reset role;

-- Supplemental report after a new closed interval, without touching the first report.
select set_config('request.jwt.claim.sub', :'employee', false);
set role authenticated;
select public.clock_in('web');
select public.clock_out('web');
do $$
declare
  v_seq integer;
  v_first integer;
begin
  select max(sequence) into v_seq
  from public.attendance_daily_reports
  where profile_id = auth.uid() and tehran_date = app.tehran_today();
  if v_seq <> 2 then
    raise exception 'supplemental sequence %, expected 2', v_seq;
  end if;
  select count(*) into v_first
  from public.attendance_report_items
  where report_id = (
    select id from public.attendance_daily_reports
    where profile_id = auth.uid() and sequence = 1 and tehran_date = app.tehran_today()
  );
  if v_first <> 2 then
    raise exception 'original report changed';
  end if;
end
$$;
reset role;

-- Forgotten clock-out releases the open slot and does not invent an end.
select set_config('request.jwt.claim.sub', :'employee', false);
set role authenticated;
select public.clock_in('web') as stuck_id \gset
select set_config('jibhr.stuck_id', :'stuck_id', false);
select public.request_attendance_correction(
  'missing_out', current_setting('jibhr.stuck_id')::uuid, null, clock_timestamp(), 'خروج را فراموش کردم'
) as correction_id \gset
do $$
declare
  v_status text;
  v_ended timestamptz;
  v_approved bigint;
begin
  select status, effective_ended_at into v_status, v_ended
  from public.attendance_intervals where id = current_setting('jibhr.stuck_id')::uuid;
  if v_status <> 'incomplete' or v_ended is not null then
    raise exception 'incomplete interval was guessed, status % end %', v_status, v_ended;
  end if;
  select approved_seconds into v_approved
  from public.attendance_totals(auth.uid(), app.tehran_today(), app.tehran_today());
  -- The open piece must not be part of the approved total. Comparing to the
  -- previously approved closed intervals is enough: a new clock-in still open
  -- has no segment yet.
  if exists (
    select 1 from public.attendance_daily_segments
    where interval_id = current_setting('jibhr.stuck_id')::uuid
  ) then
    raise exception 'incomplete interval produced segments';
  end if;
end
$$;
select public.clock_in('android');
select public.clock_out('android');
reset role;

-- Cross-midnight split is only a reporting cut. 23:30 to 01:30 => 30 + 90 minutes.
reset role;
do $$
declare
  v_profile uuid := 'a4444444-4444-4444-8444-444444444444';
  v_day date := app.tehran_today() - 2;
  v_start timestamptz;
  v_end timestamptz;
  v_id uuid;
  v_first integer;
  v_second integer;
  v_events integer;
begin
  v_start := ((v_day::timestamp + time '23:30') at time zone 'Asia/Tehran');
  v_end := (((v_day + 1)::timestamp + time '01:30') at time zone 'Asia/Tehran');
  insert into public.attendance_intervals (
    workspace_id, profile_id, origin, status,
    original_started_at, original_ended_at, effective_started_at, effective_ended_at,
    start_platform, end_platform
  ) values (
    'a0000000-0000-4000-8000-000000000001', v_profile, 'clock', 'closed',
    v_start, v_end, v_start, v_end, 'web', 'windows'
  ) returning id into v_id;
  perform app.materialize_segments(v_id, 'report', null);
  select extract(epoch from (ended_at - started_at))::integer into v_first
  from public.attendance_daily_segments where interval_id = v_id and tehran_date = v_day;
  select extract(epoch from (ended_at - started_at))::integer into v_second
  from public.attendance_daily_segments where interval_id = v_id and tehran_date = v_day + 1;
  if v_first <> 1800 or v_second <> 5400 then
    raise exception 'midnight split % and %', v_first, v_second;
  end if;
  select count(*) into v_events from public.attendance_events where interval_id = v_id;
  if v_events <> 0 then
    raise exception 'midnight split created clock events';
  end if;
end
$$;

-- Due-job is idempotent and does not submit today.
select public.submit_due_attendance_reports() as due_first \gset
select public.submit_due_attendance_reports() as due_second \gset
select set_config('jibhr.due_second', :'due_second', false);
do $$
begin
  if current_setting('jibhr.due_second')::integer <> 0 then
    raise exception 'due job created reports on the second run: %', current_setting('jibhr.due_second');
  end if;
  if exists (
    select 1 from public.attendance_daily_reports
    where tehran_date = app.tehran_today() and submission_source = 'automatic' and kind = 'automatic'
  ) then
    raise exception 'today was auto-submitted';
  end if;
end
$$;

-- Weekly buckets stay inside Saturday-Friday.
select set_config('request.jwt.claim.sub', :'manager', false);
set role authenticated;
do $$
declare
  v_profile uuid := 'a4444444-4444-4444-8444-444444444444';
  v_start date;
  v_end date;
begin
  select period_start, period_end into v_start, v_end
  from public.attendance_buckets(v_profile, app.tehran_today() - 10, app.tehran_today(), 'week')
  limit 1;
  if v_start is null then
    raise exception 'week bucket missing';
  end if;
  if extract(dow from v_start) <> 6 or v_end <> v_start + 6 then
    raise exception 'week bucket % to %', v_start, v_end;
  end if;
end
$$;
reset role;

-- Jalali month bucket returns the Persian month containing the split day.
select set_config('request.jwt.claim.sub', :'manager', false);
set role authenticated;
do $$
declare
  v_profile uuid := 'a4444444-4444-4444-8444-444444444444';
  v_jy integer;
  v_jm integer;
  v_expected record;
  v_day date := app.tehran_today() - 2;
begin
  select * into v_expected from app.gregorian_to_jalali(v_day);
  select jalali_year, jalali_month into v_jy, v_jm
  from public.attendance_buckets(v_profile, v_day, v_day, 'jalali_month');
  if v_jy <> v_expected.jy or v_jm <> v_expected.jm then
    raise exception 'jalali bucket %/% expected %/%', v_jy, v_jm, v_expected.jy, v_expected.jm;
  end if;
end
$$;
reset role;

-- Personal task is invisible to a teammate. Project-restricted task too.
select set_config('request.jwt.claim.sub', :'employee', false);
set role authenticated;
select public.create_task('کار شخصی', '', null, auth.uid(), 'high', null, true, null, null, false) as personal_id \gset
select set_config('jibhr.personal_id', :'personal_id', false);
reset role;
select set_config('request.jwt.claim.sub', :'peer', false);
set role authenticated;
do $$
begin
  if exists (select 1 from public.tasks where id = current_setting('jibhr.personal_id')::uuid) then
    raise exception 'peer can see a personal task';
  end if;
end
$$;
reset role;
select set_config('request.jwt.claim.sub', :'manager', false);
set role authenticated;
do $$
begin
  if not exists (select 1 from public.tasks where id = current_setting('jibhr.personal_id')::uuid) then
    raise exception 'primary-team manager cannot see the personal task';
  end if;
end
$$;
reset role;

-- Approval cannot be skipped by moving the card, and one review wins.
select set_config('request.jwt.claim.sub', :'employee', false);
set role authenticated;
do $$
declare
  v_task uuid := current_setting('jibhr.personal_id')::uuid;
  v_status uuid;
  v_key text;
begin
  for v_key in select unnest(array['todo', 'in_progress', 'in_review']) loop
    select id into v_status from public.workflow_statuses
    where key = v_key
      and workflow_id = (select workflow_id from public.workflow_statuses where id = (select status_id from public.tasks where id = v_task));
    perform public.transition_task(v_task, v_status, null);
  end loop;
end
$$;
do $$
declare
  v_task uuid := current_setting('jibhr.personal_id')::uuid;
  v_status uuid;
begin
  select id into v_status from public.workflow_statuses
  where key = 'approved'
    and workflow_id = (select workflow_id from public.workflow_statuses s join public.tasks t on t.status_id = s.id where t.id = v_task);
  perform public.transition_task(v_task, v_status, null);
  raise exception 'done without approval';
exception when others then
  if sqlerrm <> 'approval_required' then raise; end if;
end
$$;
reset role;
select set_config('request.jwt.claim.sub', :'manager', false);
set role authenticated;
select public.decide_task(current_setting('jibhr.personal_id')::uuid, 'revision_requested', 'عنوان را دقیق‌تر بنویس');
reset role;
select set_config('request.jwt.claim.sub', :'manager2', false);
set role authenticated;
do $$
begin
  perform public.decide_task(current_setting('jibhr.personal_id')::uuid, 'approved', null);
  raise exception 'second reviewer decided the same round';
exception when others then
  if sqlerrm not in ('already_decided', 'not_submitted') then raise; end if;
end
$$;
reset role;

-- Required subtask blocks Done. Manager override is audited.
select set_config('request.jwt.claim.sub', :'admin', false);
set role authenticated;
select public.create_project('محصول داخلی') as project_id \gset
select public.set_project_visibility(:'project_id'::uuid, 'restricted');
select public.add_project_member(:'project_id'::uuid, :'peer'::uuid, 'member');
select public.add_project_member(:'project_id'::uuid, :'employee'::uuid, 'member');
select public.create_task(
  'والد', '', :'project_id'::uuid, :'employee'::uuid, 'medium', null, false, null, null, false
) as parent_id \gset
select set_config('jibhr.parent_id', :'parent_id', false);
select public.create_task(
  'فرزند', '', :'project_id'::uuid, :'employee'::uuid, 'medium', null, false, null, :'parent_id'::uuid, true
);
reset role;
select set_config('request.jwt.claim.sub', :'peer', false);
set role authenticated;
do $$
begin
  if exists (select 1 from public.tasks where id = current_setting('jibhr.parent_id')::uuid) then
    raise exception 'restricted task is visible to another member';
  end if;
end
$$;
reset role;
select set_config('request.jwt.claim.sub', :'employee', false);
set role authenticated;
do $$
declare
  v_task uuid := current_setting('jibhr.parent_id')::uuid;
  v_status uuid;
  v_key text;
begin
  for v_key in select unnest(array['todo', 'in_progress', 'in_review', 'approved', 'done']) loop
    select s.id into v_status
    from public.workflow_statuses s
    join public.tasks t on t.status_id is not null
    where s.key = v_key
      and s.workflow_id = (
        select st.workflow_id from public.workflow_statuses st
        join public.tasks task on task.status_id = st.id
        where task.id = v_task
      );
    perform public.transition_task(v_task, v_status, null);
  end loop;
  raise exception 'parent completed with an open required subtask';
exception when others then
  if sqlerrm <> 'subtasks_incomplete' then raise; end if;
end
$$;
reset role;

-- Project edits, labels, checklist, one-level subtasks, and a closed rejection.
select set_config('jibhr.project_id', :'project_id', false);
select set_config('request.jwt.claim.sub', :'employee', false);
set role authenticated;
do $$
begin
  perform public.create_project('نباید');
  raise exception 'employee created a project';
exception when others then
  if sqlerrm <> 'forbidden' then raise; end if;
end
$$;
do $$
begin
  perform public.update_project(current_setting('jibhr.project_id')::uuid, 'نام تازه', '', true);
  raise exception 'member edited the project';
exception when others then
  if sqlerrm <> 'forbidden' then raise; end if;
end
$$;
reset role;

select set_config('request.jwt.claim.sub', :'admin', false);
set role authenticated;
select public.update_project(current_setting('jibhr.project_id')::uuid, 'محصول داخلی', 'شرح', true);
select public.add_project_member(current_setting('jibhr.project_id')::uuid, :'manager2'::uuid, 'manager');
select public.remove_project_member(current_setting('jibhr.project_id')::uuid, :'manager2'::uuid);
do $$
begin
  perform public.remove_project_member(current_setting('jibhr.project_id')::uuid, auth.uid());
  raise exception 'last project manager was removed';
exception when others then
  if sqlerrm <> 'last_manager' then raise; end if;
end
$$;
select public.archive_project(current_setting('jibhr.project_id')::uuid, true);
select public.archive_project(current_setting('jibhr.project_id')::uuid, false);
select public.save_label(current_setting('jibhr.project_id')::uuid, null, 'انتشار', true) as extra_label \gset
select set_config('jibhr.extra_label', :'extra_label', false);
select public.save_label(current_setting('jibhr.project_id')::uuid, current_setting('jibhr.extra_label')::uuid, 'انتشار', false);
select public.add_checklist_item(current_setting('jibhr.parent_id')::uuid, 'یک') as item_a \gset
select public.add_checklist_item(current_setting('jibhr.parent_id')::uuid, 'دو') as item_b \gset
select set_config('jibhr.item_a', :'item_a', false);
select set_config('jibhr.item_b', :'item_b', false);
select public.toggle_checklist_item(current_setting('jibhr.item_a')::uuid, true);
select public.rename_checklist_item(current_setting('jibhr.item_a')::uuid, 'یک‌ویرایش');
select public.move_checklist_item(current_setting('jibhr.item_b')::uuid, -1);
select public.set_project_visibility(current_setting('jibhr.project_id')::uuid, 'project_wide');
reset role;

select set_config('request.jwt.claim.sub', :'peer', false);
set role authenticated;
do $$
begin
  if not exists (select 1 from public.tasks where id = current_setting('jibhr.parent_id')::uuid) then
    raise exception 'project-wide member cannot see the task';
  end if;
end
$$;
reset role;

select set_config('request.jwt.claim.sub', :'admin', false);
set role authenticated;
select public.set_project_visibility(current_setting('jibhr.project_id')::uuid, 'restricted');
select public.add_task_collaborator(current_setting('jibhr.parent_id')::uuid, :'peer'::uuid);
reset role;
select set_config('request.jwt.claim.sub', :'peer', false);
set role authenticated;
do $$
begin
  if not exists (select 1 from public.tasks where id = current_setting('jibhr.parent_id')::uuid) then
    raise exception 'collaborator cannot see the restricted task';
  end if;
end
$$;
reset role;
select set_config('request.jwt.claim.sub', :'admin', false);
set role authenticated;
select public.remove_task_collaborator(current_setting('jibhr.parent_id')::uuid, :'peer'::uuid);
do $$
declare
  v_child uuid;
  v_done integer;
  v_total integer;
  v_workflow uuid;
  v_status uuid;
  v_backlog uuid;
begin
  if exists (
    select 1 from public.project_members
    where project_id = current_setting('jibhr.project_id')::uuid
      and profile_id = 'a5555555-5555-4555-8555-555555555555'
      and removed_at is null
  ) then
    raise exception 'removed member is still active';
  end if;
  if not exists (
    select 1 from public.projects
    where id = current_setting('jibhr.project_id')::uuid
      and name = 'محصول داخلی' and status = 'active' and approval_required
  ) then
    raise exception 'project edit did not persist';
  end if;
  if (select count(*) from public.labels where project_id = current_setting('jibhr.project_id')::uuid) < 6 then
    raise exception 'default labels missing';
  end if;
  select count(*) filter (where is_done), count(*) into v_done, v_total
  from public.task_checklist_items
  where task_id = current_setting('jibhr.parent_id')::uuid;
  if v_total <> 2 or v_done <> 1 then
    raise exception 'checklist progress is %/%', v_done, v_total;
  end if;
  select id into v_child from public.tasks
  where parent_task_id = current_setting('jibhr.parent_id')::uuid
  limit 1;
  begin
    perform public.create_task('نوه', '', current_setting('jibhr.project_id')::uuid, auth.uid(), 'low', null, false, null, v_child, false);
    raise exception 'nested subtask was stored';
  exception when others then
    if sqlerrm <> 'nesting_limit' then raise; end if;
  end;
  perform public.update_task(
    current_setting('jibhr.parent_id')::uuid,
    'والد', 'شرح تسک', 'a3333333-3333-4333-8333-333333333333', null,
    'critical', ((app.tehran_today() + 4)::timestamp) at time zone 'Asia/Tehran', false
  );
  if not exists (
    select 1 from public.tasks
    where id = current_setting('jibhr.parent_id')::uuid
      and priority = 'critical' and priority_rank = 4
      and (due_at at time zone 'Asia/Tehran')::date = app.tehran_today() + 4
  ) then
    raise exception 'task priority or jalali due date was not stored';
  end if;
  if not exists (
    select 1 from public.task_activity_events
    where task_id = current_setting('jibhr.parent_id')::uuid and action = 'task.priority'
  ) then
    raise exception 'assignment history missed the priority change';
  end if;
  select id into v_workflow from public.workflows where project_id = current_setting('jibhr.project_id')::uuid;
  v_status := public.save_workflow_status(v_workflow, null, 'منتظر', 'blocked', 10, false, true);
  select id into v_backlog from public.workflow_statuses where workflow_id = v_workflow and key = 'backlog';
  perform set_config('jibhr.custom_status', v_status::text, false);
  perform set_config('jibhr.backlog_status', v_backlog::text, false);
end
$$;
reset role;

select set_config('request.jwt.claim.sub', :'employee', false);
set role authenticated;
do $$
begin
  perform public.transition_task(
    current_setting('jibhr.parent_id')::uuid,
    current_setting('jibhr.custom_status')::uuid,
    null
  );
  raise exception 'transition without an edge was accepted';
exception when others then
  if sqlerrm <> 'transition_denied' then raise; end if;
end
$$;
reset role;
select set_config('request.jwt.claim.sub', :'admin', false);
set role authenticated;
select public.set_workflow_transition(
  current_setting('jibhr.backlog_status')::uuid,
  current_setting('jibhr.custom_status')::uuid,
  true
);
reset role;
select set_config('request.jwt.claim.sub', :'employee', false);
set role authenticated;
select public.transition_task(
  current_setting('jibhr.parent_id')::uuid,
  current_setting('jibhr.custom_status')::uuid,
  null
);
select public.create_task('برای رد', '', null, auth.uid(), 'low', null, true, null, null, false) as reject_task \gset
select set_config('jibhr.reject_task', :'reject_task', false);
do $$
declare
  v_task uuid := current_setting('jibhr.reject_task')::uuid;
  v_status uuid;
  v_key text;
begin
  for v_key in select unnest(array['todo', 'in_progress', 'in_review']) loop
    select id into v_status from public.workflow_statuses
    where key = v_key
      and workflow_id = (select workflow_id from public.workflow_statuses where id = (select status_id from public.tasks where id = v_task));
    perform public.transition_task(v_task, v_status, null);
  end loop;
end
$$;
reset role;
select set_config('request.jwt.claim.sub', :'manager', false);
set role authenticated;
do $$
begin
  perform public.decide_task(current_setting('jibhr.reject_task')::uuid, 'rejected', '  ');
  raise exception 'rejection without a reason was stored';
exception when others then
  if sqlerrm <> 'reason_required' then raise; end if;
end
$$;
select public.decide_task(current_setting('jibhr.reject_task')::uuid, 'rejected', 'این کار بسته شد');
reset role;
select set_config('request.jwt.claim.sub', :'manager2', false);
set role authenticated;
do $$
begin
  perform public.decide_task(current_setting('jibhr.reject_task')::uuid, 'approved', null);
  raise exception 'second reviewer overrode the rejection';
exception when others then
  if sqlerrm not in ('already_decided', 'not_submitted') then raise; end if;
end
$$;
reset role;
select set_config('request.jwt.claim.sub', :'employee', false);
set role authenticated;
do $$
declare
  v_todo uuid;
begin
  select id into v_todo from public.workflow_statuses
  where key = 'todo'
    and workflow_id = (
      select workflow_id from public.workflow_statuses
      where id = (select status_id from public.tasks where id = current_setting('jibhr.reject_task')::uuid)
    );
  perform public.transition_task(current_setting('jibhr.reject_task')::uuid, v_todo, null);
  raise exception 'employee reopened a rejected task';
exception when others then
  if sqlerrm <> 'rejected_closed' then raise; end if;
end
$$;
reset role;
select set_config('request.jwt.claim.sub', :'admin', false);
set role authenticated;
do $$
declare
  v_from uuid;
  v_to uuid;
begin
  select id into v_from from public.workflow_statuses
  where key = 'rejected' and workflow_id = (select id from public.workflows where project_id is null);
  select id into v_to from public.workflow_statuses
  where key = 'todo' and workflow_id = (select id from public.workflows where project_id is null);
  perform public.set_workflow_transition(v_from, v_to, true);
  perform set_config('jibhr.reopen_from', v_from::text, false);
  perform set_config('jibhr.reopen_to', v_to::text, false);
end
$$;
reset role;
select set_config('request.jwt.claim.sub', :'manager', false);
set role authenticated;
select public.transition_task(
  current_setting('jibhr.reject_task')::uuid,
  current_setting('jibhr.reopen_to')::uuid,
  null
);
reset role;
select set_config('request.jwt.claim.sub', :'admin', false);
set role authenticated;
select public.set_workflow_transition(
  current_setting('jibhr.reopen_from')::uuid,
  current_setting('jibhr.reopen_to')::uuid,
  false
);
reset role;
do $$
begin
  if not exists (
    select 1 from public.tasks t
    join public.workflow_statuses s on s.id = t.status_id
    where t.id = current_setting('jibhr.reject_task')::uuid
      and s.key = 'todo'
      and t.approval_state = 'rejected'
  ) then
    raise exception 'manager reopen did not keep the rejection history';
  end if;
  if exists (
    select 1 from public.tasks where id = current_setting('jibhr.parent_id')::uuid
      and status_id = current_setting('jibhr.backlog_status')::uuid
  ) then
    raise exception 'allowed transition did not move the task';
  end if;
end
$$;

-- Sprints and milestones: one active sprint, history, approval-aware progress.
select set_config('request.jwt.claim.sub', :'admin', false);
set role authenticated;
select public.create_project('پروژه اسپرینت', '') as sprint_project \gset
select set_config('jibhr.sprint_project', :'sprint_project', false);
select public.create_project('پروژه دیگر', '') as other_project \gset
select set_config('jibhr.other_project', :'other_project', false);
select public.create_task('تسک بیگانه', '', :'other_project', :'admin', 'low', null, false, null, null, false) as foreign_task \gset
select set_config('jibhr.foreign_task', :'foreign_task', false);
select public.create_task('تسک باز', '', :'sprint_project', :'admin', 'medium', null, false, null, null, false) as open_task \gset
select set_config('jibhr.open_task', :'open_task', false);
reset role;

select set_config('request.jwt.claim.sub', :'employee', false);
set role authenticated;
do $$
begin
  begin
    perform public.create_sprint(current_setting('jibhr.sprint_project')::uuid, 'غیرمجاز', '2026-03-21', '2026-03-28', '', '{}');
    raise exception 'employee created a sprint';
  exception when others then
    if sqlerrm <> 'forbidden' then raise; end if;
  end;
end
$$;
reset role;

select set_config('request.jwt.claim.sub', :'manager', false);
set role authenticated;
do $$
begin
  begin
    perform public.create_sprint(current_setting('jibhr.sprint_project')::uuid, 'مدیر تیم', '2026-03-21', '2026-03-28', '', '{}');
    raise exception 'team manager outside the project created a sprint';
  exception when others then
    if sqlerrm <> 'forbidden' then raise; end if;
  end;
end
$$;
reset role;

select set_config('request.jwt.claim.sub', :'admin', false);
set role authenticated;
do $$
begin
  begin
    perform public.create_sprint(current_setting('jibhr.sprint_project')::uuid, 'بازه', '2026-04-03', '2026-03-21', '', '{}');
    raise exception 'invalid sprint range was stored';
  exception when others then
    if sqlerrm <> 'invalid_range' then raise; end if;
  end;
  begin
    perform public.create_sprint(
      current_setting('jibhr.sprint_project')::uuid, 'نباید بماند', '2026-03-21', '2026-03-28', '',
      array[current_setting('jibhr.foreign_task')::uuid]
    );
    raise exception 'cross-project sprint task was accepted';
  exception when others then
    if sqlerrm <> 'project_mismatch' then raise; end if;
  end;
  if exists (select 1 from public.sprints where name = 'نباید بماند') then
    raise exception 'failed sprint create was kept';
  end if;
end
$$;
select public.create_sprint(
  :'sprint_project', 'اسپرینت اول', '2026-03-21', '2026-04-03', 'شرح',
  array[:'open_task']::uuid[]
) as sprint_a \gset
select set_config('jibhr.sprint_a', :'sprint_a', false);
reset role;
select set_config('request.jwt.claim.sub', :'employee', false);
set role authenticated;
do $$
begin
  begin
    perform public.move_task_to_sprint(current_setting('jibhr.open_task')::uuid, current_setting('jibhr.sprint_a')::uuid);
    raise exception 'employee moved a sprint task';
  exception when others then
    if sqlerrm <> 'forbidden' then raise; end if;
  end;
  begin
    perform public.set_sprint_status(current_setting('jibhr.sprint_a')::uuid, 'active');
    raise exception 'employee activated a sprint';
  exception when others then
    if sqlerrm <> 'forbidden' then raise; end if;
  end;
end
$$;
reset role;
select set_config('request.jwt.claim.sub', :'admin', false);
set role authenticated;
select public.remove_task_from_sprint(:'open_task', :'sprint_a');
do $$
begin
  if (select count(*) from public.sprint_tasks where task_id = current_setting('jibhr.open_task')::uuid) <> 1 then
    raise exception 'removing a task deleted its sprint history';
  end if;
  if exists (
    select 1 from public.sprint_tasks
    where task_id = current_setting('jibhr.open_task')::uuid and removed_at is null
  ) then
    raise exception 'removed task is still current';
  end if;
end
$$;
select public.move_task_to_sprint(:'open_task', :'sprint_a');
select public.create_task('تسک تمام', '', :'sprint_project', :'admin', 'high', null, false, null, null, false) as done_task \gset
select set_config('jibhr.done_task', :'done_task', false);
select public.create_task('تسک مسدود', '', :'sprint_project', :'admin', 'low', null, false, null, null, false) as blocked_task \gset
select set_config('jibhr.blocked_task', :'blocked_task', false);
select public.move_task_to_sprint(:'done_task', :'sprint_a');
select public.move_task_to_sprint(:'blocked_task', :'sprint_a');
select public.create_sprint(:'sprint_project', 'اسپرینت دوم', '2026-04-04', '2026-04-17', '', '{}') as sprint_b \gset
select set_config('jibhr.sprint_b', :'sprint_b', false);
select public.set_sprint_status(:'sprint_a', 'active');
do $$
begin
  begin
    perform public.set_sprint_status(current_setting('jibhr.sprint_b')::uuid, 'active');
    raise exception 'two active sprints were allowed';
  exception when others then
    if sqlerrm <> 'already_active' then raise; end if;
  end;
  begin
    perform public.update_sprint(current_setting('jibhr.sprint_a')::uuid, 'اسپرینت اول', '', '2026-04-10', '2026-04-01');
    raise exception 'invalid sprint edit was stored';
  exception when others then
    if sqlerrm <> 'invalid_range' then raise; end if;
  end;
  begin
    perform public.move_task_to_sprint(current_setting('jibhr.foreign_task')::uuid, current_setting('jibhr.sprint_a')::uuid);
    raise exception 'cross-project move was accepted';
  exception when others then
    if sqlerrm <> 'project_mismatch' then raise; end if;
  end;
end
$$;
select public.update_sprint(:'sprint_a', 'اسپرینت ویرایش‌شده', 'شرح تازه', '2026-03-21', '2026-04-03');
do $$
declare
  v_key text;
  v_total integer;
  v_complete integer;
  v_blocked integer;
begin
  select total, complete, blocked into v_total, v_complete, v_blocked
  from public.project_sprint_counts(current_setting('jibhr.sprint_project')::uuid)
  where sprint_id = current_setting('jibhr.sprint_a')::uuid;
  if v_total <> 3 or v_complete <> 0 or v_blocked <> 0 then
    raise exception 'sprint start counts %/%/%', v_total, v_complete, v_blocked;
  end if;
  foreach v_key in array array['todo', 'in_progress', 'in_review', 'approved', 'done'] loop
    perform public.transition_task(current_setting('jibhr.done_task')::uuid, (
      select s.id from public.workflow_statuses s
      join public.workflows w on w.id = s.workflow_id
      where w.project_id = current_setting('jibhr.sprint_project')::uuid and s.key = v_key
    ));
  end loop;
  select total, complete into v_total, v_complete
  from public.project_sprint_counts(current_setting('jibhr.sprint_project')::uuid)
  where sprint_id = current_setting('jibhr.sprint_a')::uuid;
  if v_complete <> 1 or v_total <> 3 then
    raise exception 'done task did not change sprint progress';
  end if;
  foreach v_key in array array['todo', 'in_progress', 'blocked'] loop
    perform public.transition_task(current_setting('jibhr.blocked_task')::uuid, (
      select s.id from public.workflow_statuses s
      join public.workflows w on w.id = s.workflow_id
      where w.project_id = current_setting('jibhr.sprint_project')::uuid and s.key = v_key
    ));
  end loop;
  select blocked into v_blocked
  from public.project_sprint_counts(current_setting('jibhr.sprint_project')::uuid)
  where sprint_id = current_setting('jibhr.sprint_a')::uuid;
  if v_blocked <> 1 then
    raise exception 'blocked task is not counted';
  end if;
end
$$;
select public.set_sprint_status(:'sprint_a', 'closed');
select public.transfer_sprint_remainder(:'sprint_a', :'sprint_b') as moved_count \gset
select set_config('jibhr.moved_count', :'moved_count', false);
do $$
declare
  v_summary jsonb;
  v_total integer;
  v_complete integer;
  v_blocked integer;
begin
  if current_setting('jibhr.moved_count') <> '2' then
    raise exception 'remainder transfer moved %', current_setting('jibhr.moved_count');
  end if;
  select summary into v_summary from public.sprints where id = current_setting('jibhr.sprint_a')::uuid;
  if v_summary is null
     or (v_summary->>'total')::int <> 3
     or (v_summary->>'complete')::int <> 1
     or (v_summary->>'blocked')::int <> 1
     or (v_summary->>'remaining')::int <> 2
     or (v_summary->>'percent')::int <> 33
  then
    raise exception 'sprint summary %', v_summary;
  end if;
  if not exists (
    select 1 from public.tasks t
    join public.workflow_statuses s on s.id = t.status_id
    where t.id = current_setting('jibhr.open_task')::uuid and s.key = 'backlog'
  ) then
    raise exception 'closing a sprint completed an open task';
  end if;
  if (select count(*) from public.sprint_tasks where task_id = current_setting('jibhr.open_task')::uuid and removed_at is null) <> 1 then
    raise exception 'task belongs to more than one current sprint';
  end if;
  if not exists (
    select 1 from public.sprint_tasks
    where task_id = current_setting('jibhr.open_task')::uuid
      and sprint_id = current_setting('jibhr.sprint_b')::uuid
      and removed_at is null
      and carried_from_sprint_id = current_setting('jibhr.sprint_a')::uuid
  ) then
    raise exception 'transfer did not keep the previous sprint';
  end if;
  if not exists (
    select 1 from public.sprint_tasks
    where task_id = current_setting('jibhr.open_task')::uuid
      and sprint_id = current_setting('jibhr.sprint_a')::uuid
      and removed_at is not null
  ) then
    raise exception 'old sprint membership was deleted';
  end if;
  if not exists (
    select 1 from public.sprint_tasks
    where task_id = current_setting('jibhr.done_task')::uuid
      and sprint_id = current_setting('jibhr.sprint_a')::uuid
      and removed_at is null
  ) then
    raise exception 'completed task left its sprint';
  end if;
  if not exists (
    select 1 from public.task_activity_events
    where task_id = current_setting('jibhr.open_task')::uuid and action = 'task.create'
  ) then
    raise exception 'transfer removed task activity';
  end if;
  select total, complete, blocked into v_total, v_complete, v_blocked
  from public.project_sprint_counts(current_setting('jibhr.sprint_project')::uuid)
  where sprint_id = current_setting('jibhr.sprint_a')::uuid;
  if v_total <> 1 or v_complete <> 1 or v_blocked <> 0 then
    raise exception 'closed sprint live counts %/%/%', v_total, v_complete, v_blocked;
  end if;
  select total, complete, blocked into v_total, v_complete, v_blocked
  from public.project_sprint_counts(current_setting('jibhr.sprint_project')::uuid)
  where sprint_id = current_setting('jibhr.sprint_b')::uuid;
  if v_total <> 2 or v_complete <> 0 or v_blocked <> 1 then
    raise exception 'destination sprint counts %/%/%', v_total, v_complete, v_blocked;
  end if;
  if not exists (select 1 from public.sprints where id = current_setting('jibhr.sprint_a')::uuid and name = 'اسپرینت ویرایش‌شده') then
    raise exception 'sprint edit did not persist';
  end if;
end
$$;
select public.set_sprint_status(:'sprint_b', 'active');
select public.create_sprint(:'sprint_project', 'اسپرینت سوم', '2026-04-18', '2026-05-01', '', '{}') as sprint_c \gset
select set_config('jibhr.sprint_c', :'sprint_c', false);
do $$
begin
  begin
    perform public.set_sprint_status(current_setting('jibhr.sprint_c')::uuid, 'active');
    raise exception 'active sprint was replaced without closing it';
  exception when others then
    if sqlerrm <> 'already_active' then raise; end if;
  end;
end
$$;
select public.set_sprint_status(:'sprint_b', 'cancelled');
select public.set_sprint_status(:'sprint_c', 'active');
do $$
begin
  begin
    perform public.set_sprint_status(current_setting('jibhr.sprint_b')::uuid, 'active');
    raise exception 'cancelled sprint was reactivated';
  exception when others then
    if sqlerrm <> 'invalid_status' then raise; end if;
  end;
end
$$;
reset role;
do $$
begin
  if not exists (select 1 from pg_indexes where indexname = 'sprints_one_active_idx') then
    raise exception 'one-active sprint index is missing';
  end if;
  if not exists (
    select 1 from public.audit_logs
    where action = 'sprint.transfer' and entity_id = current_setting('jibhr.sprint_a')::uuid
  ) then
    raise exception 'sprint transfer was not audited';
  end if;
end
$$;

select set_config('request.jwt.claim.sub', :'admin', false);
set role authenticated;
select public.create_milestone(:'sprint_project', 'مایلستون خالی', '2026-06-01', '', '{}') as empty_milestone \gset
select set_config('jibhr.empty_milestone', :'empty_milestone', false);
select public.create_milestone(
  :'sprint_project', 'تحویل اول', '2026-05-01', 'شرح',
  array[:'open_task']::uuid[]
) as milestone_a \gset
select set_config('jibhr.milestone_a', :'milestone_a', false);
do $$
declare
  v_total integer;
  v_complete integer;
  v_blocked integer;
begin
  select total, complete, blocked into v_total, v_complete, v_blocked
  from public.project_milestone_counts(current_setting('jibhr.sprint_project')::uuid)
  where milestone_id = current_setting('jibhr.empty_milestone')::uuid;
  if v_total <> 0 or v_complete <> 0 or v_blocked <> 0 then
    raise exception 'empty milestone counts %/%/%', v_total, v_complete, v_blocked;
  end if;
  perform public.set_milestone_status(current_setting('jibhr.empty_milestone')::uuid, 'reached', '');
  begin
    perform public.link_milestone_task(current_setting('jibhr.milestone_a')::uuid, current_setting('jibhr.foreign_task')::uuid);
    raise exception 'cross-project milestone link was accepted';
  exception when others then
    if sqlerrm <> 'project_mismatch' then raise; end if;
  end;
  begin
    perform public.set_milestone_status(current_setting('jibhr.milestone_a')::uuid, 'reached', '');
    raise exception 'milestone completed with an open task';
  exception when others then
    if sqlerrm <> 'tasks_incomplete' then raise; end if;
  end;
end
$$;
select public.set_milestone_status(:'milestone_a', 'reached', 'تحویل با کار باز');
select public.create_milestone(:'sprint_project', 'تحویل دوم', '2026-07-01', '', '{}') as milestone_b \gset
select set_config('jibhr.milestone_b', :'milestone_b', false);
select public.link_milestone_task(:'milestone_b', :'open_task');
select public.update_milestone(:'milestone_b', 'تحویل دوم ویرایش', 'شرح', '2026-07-15');
select public.create_task('تسک تأیید', '', :'sprint_project', :'admin', 'medium', null, true, null, null, false) as approval_task \gset
select set_config('jibhr.approval_task', :'approval_task', false);
select public.link_milestone_task(:'milestone_b', :'approval_task');
do $$
declare
  v_key text;
  v_complete integer;
  v_tasks integer;
begin
  foreach v_key in array array['todo', 'in_progress', 'in_review'] loop
    perform public.transition_task(current_setting('jibhr.approval_task')::uuid, (
      select s.id from public.workflow_statuses s
      join public.workflows w on w.id = s.workflow_id
      where w.project_id = current_setting('jibhr.sprint_project')::uuid and s.key = v_key
    ));
  end loop;
  select complete into v_complete
  from public.project_milestone_counts(current_setting('jibhr.sprint_project')::uuid)
  where milestone_id = current_setting('jibhr.milestone_b')::uuid;
  if v_complete <> 0 then
    raise exception 'unapproved task counted as complete';
  end if;
  perform public.decide_task(current_setting('jibhr.approval_task')::uuid, 'approved', null);
  select complete into v_complete
  from public.project_milestone_counts(current_setting('jibhr.sprint_project')::uuid)
  where milestone_id = current_setting('jibhr.milestone_b')::uuid;
  if v_complete <> 1 then
    raise exception 'approved task did not change milestone progress';
  end if;
  select count(*) into v_tasks from public.tasks where id = current_setting('jibhr.open_task')::uuid;
  if v_tasks <> 1 then
    raise exception 'linking two milestones duplicated the task';
  end if;
  if (select count(*) from public.milestone_tasks where task_id = current_setting('jibhr.open_task')::uuid) <> 2 then
    raise exception 'task is not linked to both milestones';
  end if;
  if not exists (
    select 1 from public.milestones
    where id = current_setting('jibhr.milestone_b')::uuid and title = 'تحویل دوم ویرایش'
  ) then
    raise exception 'milestone edit did not persist';
  end if;
end
$$;
reset role;
select set_config('request.jwt.claim.sub', :'admin', false);
set role authenticated;
select public.create_task('تسک فرمول', '', :'sprint_project', :'admin', 'low', null, false, null, null, false) as formula_task \gset
select set_config('jibhr.formula_task', :'formula_task', false);
reset role;
update public.tasks set
  status_id = (
    select s.id from public.workflow_statuses s
    join public.workflows w on w.id = s.workflow_id
    where w.project_id = :'sprint_project' and s.key = 'done'
  ),
  approval_required = true,
  approval_state = 'pending'
where id = :'formula_task';
select set_config('request.jwt.claim.sub', :'admin', false);
set role authenticated;
select public.create_milestone(:'sprint_project', 'فرمول', '2026-08-01', '', array[:'formula_task']::uuid[]) as formula_milestone \gset
select set_config('jibhr.formula_milestone', :'formula_milestone', false);
do $$
declare
  v_complete integer;
begin
  select complete into v_complete
  from public.project_milestone_counts(current_setting('jibhr.sprint_project')::uuid)
  where milestone_id = current_setting('jibhr.formula_milestone')::uuid;
  if v_complete <> 0 then
    raise exception 'done but unapproved task counted';
  end if;
end
$$;
reset role;
update public.tasks set approval_state = 'approved' where id = :'formula_task';
select set_config('request.jwt.claim.sub', :'admin', false);
set role authenticated;
do $$
declare
  v_complete integer;
begin
  select complete into v_complete
  from public.project_milestone_counts(current_setting('jibhr.sprint_project')::uuid)
  where milestone_id = current_setting('jibhr.formula_milestone')::uuid;
  if v_complete <> 1 then
    raise exception 'approved done task is still pending';
  end if;
end
$$;
reset role;
do $$
begin
  if not exists (
    select 1 from public.audit_logs
    where action = 'milestone.override' and entity_id = current_setting('jibhr.milestone_a')::uuid
  ) then
    raise exception 'milestone override was not audited';
  end if;
  if not exists (select 1 from public.milestones where id = current_setting('jibhr.milestone_a')::uuid and status = 'reached') then
    raise exception 'override did not complete the milestone';
  end if;
  if not exists (select 1 from public.milestones where id = current_setting('jibhr.empty_milestone')::uuid and status = 'reached') then
    raise exception 'empty milestone did not complete';
  end if;
end
$$;

-- Leave: hourly shape is stored, a second decision loses, absence does not delete clocks.
select set_config('request.jwt.claim.sub', :'employee', false);
set role authenticated;
select public.request_leave('hourly', null, null, app.tehran_today(), time '09:00', time '11:00', '') as leave_id \gset
select set_config('jibhr.leave_id', :'leave_id', false);
select public.request_leave('daily', app.tehran_today(), app.tehran_today() + 1, null, null, null, 'مرخصی روزانه') as daily_id \gset
reset role;
select set_config('request.jwt.claim.sub', :'manager', false);
set role authenticated;
select public.decide_leave(:'leave_id'::uuid, false, 'با برنامه تیم نمی‌خواند');
do $$
begin
  perform public.decide_leave(current_setting('jibhr.leave_id')::uuid, true, null);
  raise exception 'leave was decided twice';
exception when others then
  if sqlerrm <> 'already_decided' then raise; end if;
end
$$;
select count(*) as intervals_before from public.attendance_intervals where profile_id = :'employee' \gset
select set_config('jibhr.intervals_before', :'intervals_before', false);
select public.record_absence(:'employee'::uuid, app.tehran_today(), app.tehran_today(), 'غیبت اعلام‌شده') as absence_id \gset
select set_config('jibhr.absence_id', :'absence_id', false);
reset role;
do $$
declare
  v_after integer;
begin
  select count(*) into v_after from public.attendance_intervals where profile_id = 'a3333333-3333-4333-8333-333333333333';
  if v_after <> current_setting('jibhr.intervals_before')::integer then
    raise exception 'absence rewrote attendance';
  end if;
  if not exists (select 1 from public.absence_records where id = current_setting('jibhr.absence_id')::uuid) then
    raise exception 'absence missing';
  end if;
end
$$;

-- Leave decisions, team isolation, and absence disputes.
-- A second call after FOR UPDATE stands in for two overlapping manager sessions.
select set_config('jibhr.daily_id', :'daily_id', false);

select set_config('request.jwt.claim.sub', :'employee', false);
set role authenticated;
do $$
begin
  perform public.request_leave('hourly', null, null, app.tehran_today(), time '12:00', time '11:00', '');
  raise exception 'invalid hourly range was stored';
exception when check_violation then
  null;
end
$$;
select public.request_leave('daily', app.tehran_today(), app.tehran_today(), null, null, null, 'برای رد بدون دلیل') as reason_leave \gset
select set_config('jibhr.reason_leave', :'reason_leave', false);
reset role;

do $$
begin
  if not exists (
    select 1 from public.leave_requests
    where id = current_setting('jibhr.leave_id')::uuid
      and kind = 'hourly'
      and status = 'rejected'
      and decision_reason = 'با برنامه تیم نمی‌خواند'
  ) then
    raise exception 'hourly rejection was not stored';
  end if;
  if not exists (
    select 1 from public.leave_requests
    where id = current_setting('jibhr.daily_id')::uuid
      and kind = 'daily'
      and status = 'pending'
      and end_date = start_date + 1
  ) then
    raise exception 'multi-day leave is not still pending';
  end if;
  if not exists (
    select 1 from public.notifications
    where entity_id = current_setting('jibhr.daily_id')::uuid
      and recipient_id = 'a2222222-2222-4222-8222-222222222222'
      and category = 'leave'
  ) then
    raise exception 'leave request did not notify the manager';
  end if;
end
$$;

select set_config('request.jwt.claim.sub', :'peer', false);
set role authenticated;
do $$
begin
  if exists (
    select 1 from public.leave_requests
    where profile_id = 'a3333333-3333-4333-8333-333333333333'
  ) then
    raise exception 'peer can see another employee leave';
  end if;
  if exists (
    select 1 from public.absence_records
    where profile_id = 'a3333333-3333-4333-8333-333333333333'
  ) then
    raise exception 'peer can see another employee absence';
  end if;
end
$$;
do $$
begin
  perform public.record_absence(
    'a3333333-3333-4333-8333-333333333333', app.tehran_today(), app.tehran_today(), 'نباید'
  );
  raise exception 'peer recorded an absence';
exception when others then
  if sqlerrm <> 'forbidden' then raise; end if;
end
$$;
do $$
begin
  perform public.dispute_absence(current_setting('jibhr.absence_id')::uuid, 'مال من نیست');
  raise exception 'peer disputed another absence';
exception when others then
  if sqlerrm <> 'forbidden' then raise; end if;
end
$$;
reset role;

select set_config('request.jwt.claim.sub', :'manager', false);
set role authenticated;
do $$
begin
  perform public.decide_leave(current_setting('jibhr.reason_leave')::uuid, false, '   ');
  raise exception 'blank rejection reason was accepted';
exception when others then
  if sqlerrm <> 'reason_required' then raise; end if;
end
$$;
select public.decide_leave(current_setting('jibhr.daily_id')::uuid, true, null);
reset role;

select set_config('request.jwt.claim.sub', :'manager2', false);
set role authenticated;
do $$
begin
  perform public.decide_leave(current_setting('jibhr.daily_id')::uuid, false, 'دیر شد');
  raise exception 'second manager overrode leave';
exception when others then
  if sqlerrm <> 'already_decided' then raise; end if;
end
$$;
reset role;

select set_config('request.jwt.claim.sub', :'admin', false);
set role authenticated;
do $$
begin
  if not exists (
    select 1 from public.leave_requests
    where id = current_setting('jibhr.daily_id')::uuid
      and status = 'approved'
      and end_date = start_date + 1
  ) then
    raise exception 'super admin cannot see the approved multi-day leave';
  end if;
end
$$;
reset role;
do $$
begin
  if not exists (
    select 1 from public.notifications
    where entity_id = current_setting('jibhr.daily_id')::uuid
      and recipient_id = 'a3333333-3333-4333-8333-333333333333'
      and title = 'مرخصی تأیید شد'
  ) then
    raise exception 'leave decision did not notify the employee';
  end if;
end
$$;

select set_config('request.jwt.claim.sub', :'employee', false);
set role authenticated;
do $$
begin
  perform public.record_absence(auth.uid(), app.tehran_today(), app.tehran_today() + 1, 'خودم');
  raise exception 'employee recorded an absence';
exception when others then
  if sqlerrm <> 'forbidden' then raise; end if;
end
$$;
do $$
begin
  perform public.dispute_absence(current_setting('jibhr.absence_id')::uuid, '   ');
  raise exception 'blank dispute was stored';
exception when others then
  if sqlerrm <> 'reason_required' then raise; end if;
end
$$;
select public.dispute_absence(current_setting('jibhr.absence_id')::uuid, 'در جلسه بودم') as dispute_id \gset
select set_config('jibhr.dispute_id', :'dispute_id', false);
do $$
begin
  perform public.decide_absence_dispute(current_setting('jibhr.dispute_id')::uuid, true, null);
  raise exception 'employee decided a dispute';
exception when others then
  if sqlerrm <> 'forbidden' then raise; end if;
end
$$;
reset role;

do $$
begin
  if not exists (
    select 1 from public.absence_records
    where id = current_setting('jibhr.absence_id')::uuid
      and reason = 'غیبت اعلام‌شده'
  ) then
    raise exception 'dispute rewrote the absence';
  end if;
  if not exists (
    select 1 from public.notifications
    where entity_id = current_setting('jibhr.dispute_id')::uuid
      and recipient_id = 'a2222222-2222-4222-8222-222222222222'
  ) then
    raise exception 'dispute did not notify the manager';
  end if;
end
$$;

select set_config('request.jwt.claim.sub', :'peer', false);
set role authenticated;
do $$
begin
  if exists (
    select 1 from public.absence_disputes
    where id = current_setting('jibhr.dispute_id')::uuid
  ) then
    raise exception 'peer can see a dispute';
  end if;
end
$$;
reset role;

select set_config('request.jwt.claim.sub', :'manager', false);
set role authenticated;
select public.decide_absence_dispute(current_setting('jibhr.dispute_id')::uuid, true, null);
reset role;

select set_config('request.jwt.claim.sub', :'manager2', false);
set role authenticated;
do $$
begin
  perform public.decide_absence_dispute(current_setting('jibhr.dispute_id')::uuid, false, 'نه');
  raise exception 'second manager overrode the dispute';
exception when others then
  if sqlerrm <> 'already_decided' then raise; end if;
end
$$;
reset role;

select set_config('request.jwt.claim.sub', :'employee', false);
set role authenticated;
select public.dispute_absence(current_setting('jibhr.absence_id')::uuid, 'لطفاً اصلاح شود') as dispute_two \gset
select set_config('jibhr.dispute_two', :'dispute_two', false);
reset role;

select set_config('request.jwt.claim.sub', :'manager', false);
set role authenticated;
do $$
begin
  perform public.decide_absence_dispute(current_setting('jibhr.dispute_two')::uuid, false, '');
  raise exception 'dispute rejected without a reason';
exception when others then
  if sqlerrm <> 'reason_required' then raise; end if;
end
$$;
select public.decide_absence_dispute(current_setting('jibhr.dispute_two')::uuid, false, 'مدارک کافی نیست');
select public.record_absence(
  :'employee'::uuid, app.tehran_today(), app.tehran_today() + 2, 'غیبت چندروزه'
) as span_absence \gset
select set_config('jibhr.span_absence', :'span_absence', false);
reset role;

do $$
declare
  v_after integer;
begin
  select count(*) into v_after
  from public.attendance_intervals
  where profile_id = 'a3333333-3333-4333-8333-333333333333';
  if v_after <> current_setting('jibhr.intervals_before')::integer then
    raise exception 'multi-day absence rewrote attendance';
  end if;
  if not exists (
    select 1 from public.absence_records
    where id = current_setting('jibhr.span_absence')::uuid
      and end_date = start_date + 2
  ) then
    raise exception 'multi-day absence was not stored';
  end if;
  if not exists (
    select 1 from public.absence_disputes
    where id = current_setting('jibhr.dispute_id')::uuid and status = 'accepted'
  ) or not exists (
    select 1 from public.absence_disputes
    where id = current_setting('jibhr.dispute_two')::uuid and status = 'rejected'
      and decision_reason = 'مدارک کافی نیست'
  ) then
    raise exception 'dispute history was overwritten';
  end if;
  if not exists (
    select 1 from public.absence_records
    where id = current_setting('jibhr.absence_id')::uuid and reason = 'غیبت اعلام‌شده'
  ) then
    raise exception 'absence reason changed after the dispute decision';
  end if;
  if not exists (
    select 1 from public.notifications
    where entity_id = current_setting('jibhr.dispute_id')::uuid
      and recipient_id = 'a3333333-3333-4333-8333-333333333333'
      and category = 'absence'
  ) then
    raise exception 'dispute decision did not notify the employee';
  end if;
  if not exists (
    select 1 from public.audit_logs
    where entity_id = current_setting('jibhr.dispute_two')::uuid
      and action = 'absence.dispute_decide'
  ) then
    raise exception 'dispute decision was not audited';
  end if;
end
$$;

-- A pending correction stays out of approved time, is hidden from a peer,
-- and the second approver cannot override the first decision.
select set_config('request.jwt.claim.sub', :'employee', false);
set role authenticated;
select approved_seconds as approved_before
from public.attendance_totals(:'employee'::uuid, app.tehran_today() - 10, app.tehran_today()) \gset
select public.request_attendance_correction(
  'missing_in', null,
  (((app.tehran_today() - 1)::timestamp + time '10:00') at time zone 'Asia/Tehran'),
  (((app.tehran_today() - 1)::timestamp + time '11:00') at time zone 'Asia/Tehran'),
  'ورود دیروز را فراموش کردم'
) as pending_correction \gset
select set_config('jibhr.pending_correction', :'pending_correction', false);
select approved_seconds as approved_after
from public.attendance_totals(:'employee'::uuid, app.tehran_today() - 10, app.tehran_today()) \gset
select set_config('jibhr.approved_before', :'approved_before', false);
select set_config('jibhr.approved_after', :'approved_after', false);
reset role;
do $$
begin
  if current_setting('jibhr.approved_before') is distinct from current_setting('jibhr.approved_after') then
    raise exception 'pending correction changed approved duration';
  end if;
end
$$;
select set_config('request.jwt.claim.sub', :'peer', false);
set role authenticated;
do $$
begin
  if exists (
    select 1 from public.attendance_corrections
    where id = current_setting('jibhr.pending_correction')::uuid
  ) then
    raise exception 'peer can see a correction';
  end if;
end
$$;
reset role;
select set_config('request.jwt.claim.sub', :'manager', false);
set role authenticated;
do $$
begin
  if not exists (
    select 1 from public.attendance_corrections
    where id = current_setting('jibhr.pending_correction')::uuid
  ) then
    raise exception 'manager cannot see the correction';
  end if;
end
$$;
select public.decide_attendance_correction(current_setting('jibhr.pending_correction')::uuid, false, 'مدرک کافی نیست');
reset role;
select set_config('request.jwt.claim.sub', :'manager2', false);
set role authenticated;
do $$
begin
  perform public.decide_attendance_correction(current_setting('jibhr.pending_correction')::uuid, true, null);
  raise exception 'second manager overrode the correction';
exception when others then
  if sqlerrm <> 'already_decided' then raise; end if;
end
$$;
reset role;
select set_config('request.jwt.claim.sub', :'admin', false);
set role authenticated;
do $$
begin
  if not exists (
    select 1 from public.attendance_daily_reports
    where profile_id = 'a3333333-3333-4333-8333-333333333333'
  ) then
    raise exception 'super admin cannot see attendance reports';
  end if;
  if not exists (
    select 1 from public.attendance_corrections
    where id = current_setting('jibhr.pending_correction')::uuid
      and status = 'rejected'
  ) then
    raise exception 'correction decision did not persist';
  end if;
end
$$;
reset role;

-- One inbox: recipients follow the real relationship, and a retry does not insert again.
select set_config('request.jwt.claim.sub', :'admin', false);
set role authenticated;
select public.create_task(
  'اعلان تسک', '', :'sprint_project'::uuid, :'employee'::uuid, 'medium', null, false, null
) as notice_task \gset
select set_config('jibhr.notice_task', :'notice_task', false);
select public.create_task(
  'اعلان بررسی', '', :'sprint_project'::uuid, :'employee'::uuid, 'medium', null, true, :'peer'::uuid
) as review_task \gset
select set_config('jibhr.review_task', :'review_task', false);
do $$
declare
  v_task uuid := current_setting('jibhr.review_task')::uuid;
  v_status uuid;
  v_key text;
begin
  foreach v_key in array array['todo', 'in_progress', 'in_review']
  loop
    select s.id into v_status
    from public.workflow_statuses s
    join public.tasks t on t.id = v_task
    join public.workflow_statuses cur on cur.id = t.status_id
    where s.workflow_id = cur.workflow_id and s.key = v_key;
    perform public.transition_task(v_task, v_status);
  end loop;
end
$$;
select public.add_task_collaborator(current_setting('jibhr.review_task')::uuid, :'manager2'::uuid);
select public.add_task_collaborator(current_setting('jibhr.review_task')::uuid, :'manager2'::uuid);
select public.update_task(
  current_setting('jibhr.notice_task')::uuid,
  'اعلان تسک', '', :'employee'::uuid, null, 'medium', null, false
);
select public.update_task(
  current_setting('jibhr.notice_task')::uuid,
  'اعلان تسک', '', :'manager2'::uuid, null, 'medium', null, false
);
select public.update_task(
  current_setting('jibhr.notice_task')::uuid,
  'اعلان تسک', '', :'employee'::uuid, null, 'medium', null, false
);
select public.add_project_member(:'sprint_project'::uuid, :'employee'::uuid, 'manager');
select public.set_sprint_status(:'sprint_c'::uuid, 'closed');
select public.create_milestone(:'sprint_project', 'اعلان مایلستون', '2026-09-01', '', '{}') as notice_milestone \gset
select set_config('jibhr.notice_milestone', :'notice_milestone', false);
select public.set_milestone_status(:'notice_milestone'::uuid, 'reached', '');
select public.add_project_member(:'sprint_project'::uuid, :'employee'::uuid, 'reviewer');
select public.remove_project_member(:'sprint_project'::uuid, :'employee'::uuid);
reset role;

select set_config('request.jwt.claim.sub', :'peer', false);
set role authenticated;
select public.decide_task(current_setting('jibhr.review_task')::uuid, 'approved', null);
reset role;
select set_config('jibhr.report_id', :'report_id', false);

do $$
declare
  v_employee uuid := 'a3333333-3333-4333-8333-333333333333';
  v_manager uuid := 'a2222222-2222-4222-8222-222222222222';
  v_admin uuid := 'a1111111-1111-4111-8111-111111111111';
  v_peer uuid := 'a4444444-4444-4444-8444-444444444444';
  v_manager2 uuid := 'a5555555-5555-4555-8555-555555555555';
  v_count integer;
begin
  select count(*) into v_count from public.notifications
  where entity_id = current_setting('jibhr.report_id')::uuid
    and recipient_id = v_employee and title = 'گزارش حضور بخشی تأیید شد';
  if v_count <> 1 then
    raise exception 'attendance outcome notified % times', v_count;
  end if;
  if not exists (
    select 1 from public.notifications
    where entity_id = current_setting('jibhr.report_id')::uuid
      and recipient_id = v_manager and title = 'گزارش روزانه حضور'
  ) then
    raise exception 'daily report did not reach the team manager';
  end if;
  if not exists (
    select 1 from public.notifications n
    join public.attendance_daily_reports r on r.id = n.entity_id
    where r.profile_id = v_employee and r.sequence = 2
      and n.recipient_id = v_manager and n.title = 'گزارش تکمیلی حضور'
  ) then
    raise exception 'supplemental report title missing';
  end if;
  select count(*) into v_count from public.notifications
  where entity_id = current_setting('jibhr.pending_correction')::uuid
    and recipient_id = v_employee and title = 'اصلاح حضور رد شد';
  if v_count <> 1 then
    raise exception 'correction decision notified % times', v_count;
  end if;
  select count(*) into v_count from public.notifications
  where entity_id = current_setting('jibhr.daily_id')::uuid
    and recipient_id = v_employee and title = 'مرخصی تأیید شد';
  if v_count <> 1 then
    raise exception 'leave decision notified % times', v_count;
  end if;
  if not exists (
    select 1 from public.notifications
    where entity_id = current_setting('jibhr.dispute_id')::uuid
      and recipient_id = v_employee and title = 'توضیح غیبت پذیرفته شد'
  ) then
    raise exception 'accepted dispute title missing';
  end if;

  select count(*) into v_count from public.notifications
  where entity_id = current_setting('jibhr.notice_task')::uuid
    and recipient_id = v_employee and title = 'تسک جدید';
  if v_count <> 1 then
    raise exception 'new task notified % times', v_count;
  end if;
  if exists (
    select 1 from public.notifications
    where title = 'تسک جدید' and body = 'اعلان تسک'
  ) then
    raise exception 'assignment leaked the task title';
  end if;
  select count(*) into v_count from public.notifications
  where entity_id = current_setting('jibhr.notice_task')::uuid and title = 'مسئول تسک عوض شد';
  if v_count <> 2 then
    raise exception 'reassignment notified % times', v_count;
  end if;
  if exists (
    select 1 from public.notifications
    where entity_id = current_setting('jibhr.notice_task')::uuid
      and recipient_id = v_admin and title in ('تسک جدید', 'مسئول تسک عوض شد')
  ) then
    raise exception 'actor was notified about their own task change';
  end if;

  select count(*) into v_count from public.notifications
  where entity_id = current_setting('jibhr.review_task')::uuid
    and recipient_id = v_peer and title = 'تسک برای بررسی';
  if v_count <> 1 then
    raise exception 'review request notified % times', v_count;
  end if;
  if exists (
    select 1 from public.notifications
    where recipient_id = v_peer and title = 'تسک برای بررسی' and body like '%اعلان بررسی%'
  ) then
    raise exception 'review request leaked the task title';
  end if;
  select count(*) into v_count from public.notifications
  where entity_id = current_setting('jibhr.review_task')::uuid
    and recipient_id = v_manager2 and title = 'همکار تسک شدید';
  if v_count <> 1 then
    raise exception 'collaborator notified % times', v_count;
  end if;
  if not exists (
    select 1 from public.notifications
    where entity_id = current_setting('jibhr.review_task')::uuid
      and recipient_id = v_employee and title = 'تسک تأیید شد'
  ) or exists (
    select 1 from public.notifications
    where entity_id = current_setting('jibhr.review_task')::uuid
      and recipient_id = v_peer and title = 'تسک تأیید شد'
  ) then
    raise exception 'review result went to the wrong people';
  end if;
  if not exists (
    select 1 from public.notifications
    where entity_id = current_setting('jibhr.review_task')::uuid
      and recipient_id = v_manager2 and title = 'تسک تأیید شد'
  ) then
    raise exception 'collaborator missed the review result';
  end if;

  select count(*) into v_count from public.notifications
  where entity_id = current_setting('jibhr.sprint_project')::uuid
    and recipient_id = v_employee and title = 'به پروژه اضافه شدید';
  if v_count <> 1 then
    raise exception 'project add notified % times', v_count;
  end if;
  if not exists (
    select 1 from public.notifications
    where entity_id = current_setting('jibhr.sprint_project')::uuid
      and recipient_id = v_employee and title = 'از پروژه برداشته شدید'
      and body = 'عضویت شما در یک پروژه پایان یافت.'
  ) then
    raise exception 'removal notice missing or named the project';
  end if;
  if not exists (
    select 1 from public.notifications
    where entity_id = current_setting('jibhr.sprint_c')::uuid and recipient_id = v_employee and title = 'اسپرینت تمام شد'
  ) or exists (
    select 1 from public.notifications
    where entity_id = current_setting('jibhr.sprint_c')::uuid and recipient_id = v_admin
  ) then
    raise exception 'sprint close notified the wrong managers';
  end if;
  if not exists (
    select 1 from public.notifications
    where entity_id = current_setting('jibhr.notice_milestone')::uuid
      and recipient_id = v_employee and title = 'مایلستون تکمیل شد'
  ) then
    raise exception 'milestone completion was not sent to the other manager';
  end if;
end
$$;

select set_config('request.jwt.claim.sub', :'peer', false);
set role authenticated;
do $$
begin
  if exists (select 1 from public.tasks where id = current_setting('jibhr.review_task')::uuid) then
    raise exception 'review notice exposed a task the reviewer cannot see';
  end if;
  if exists (
    select 1 from public.notifications
    where recipient_id = 'a3333333-3333-4333-8333-333333333333'
  ) then
    raise exception 'peer read another person''s notifications';
  end if;
end
$$;
do $$
begin
  insert into public.notifications (workspace_id, recipient_id, category, title, body)
  values ('a0000000-0000-4000-8000-000000000001', auth.uid(), 'task', 'ساخته دست کاربر', 'نباید');
  raise exception 'authenticated insert was allowed';
exception when others then
  if sqlerrm not like '%permission denied%' then raise; end if;
end
$$;
reset role;

insert into public.notifications (workspace_id, recipient_id, category, title, body, entity_type, entity_id)
values (
  :'workspace', :'peer', 'task', 'تسک پنهان', 'نباید از این راه دیده شود',
  'task', current_setting('jibhr.parent_id')::uuid
);
insert into public.notifications (workspace_id, recipient_id, category, title, body, entity_type, entity_id)
select :'workspace', :'employee', 'attendance', 'صفحه آزمون', 'بدنه', 'attendance_report', gen_random_uuid()
from generate_series(1, 31);

select set_config('request.jwt.claim.sub', :'peer', false);
set role authenticated;
do $$
begin
  if not exists (select 1 from public.notifications where title = 'تسک پنهان' and recipient_id = auth.uid()) then
    raise exception 'owner cannot read their own notification';
  end if;
  if exists (select 1 from public.tasks where id = current_setting('jibhr.parent_id')::uuid) then
    raise exception 'notification unlocked a restricted task';
  end if;
end
$$;
reset role;

select id as employee_notice from public.notifications
where recipient_id = :'employee' and read_at is null
order by created_at desc
limit 1 \gset
select set_config('jibhr.employee_notice', :'employee_notice', false);

select set_config('request.jwt.claim.sub', :'peer', false);
set role authenticated;
select public.mark_notification_read(:'employee_notice'::uuid);
reset role;
do $$
begin
  if exists (
    select 1 from public.notifications
    where id = current_setting('jibhr.employee_notice')::uuid and read_at is not null
  ) then
    raise exception 'peer marked someone else''s notification read';
  end if;
end
$$;

select set_config('request.jwt.claim.sub', :'employee', false);
set role authenticated;
do $$
declare
  v_total integer;
  v_page integer;
  v_unread integer;
begin
  if exists (select 1 from public.projects where id = current_setting('jibhr.sprint_project')::uuid) then
    raise exception 'removed member still sees the project';
  end if;
  if not exists (
    select 1 from public.notifications
    where recipient_id = auth.uid() and title = 'از پروژه برداشته شدید'
  ) then
    raise exception 'removed member cannot see their own notice';
  end if;
  select count(*) into v_total from public.notifications where recipient_id = auth.uid();
  select count(*) into v_page from (
    select id from public.notifications
    where recipient_id = auth.uid()
    order by created_at desc
    offset 30 limit 30
  ) page;
  if v_total <= 30 or v_page < 1 or v_page > 30 then
    raise exception 'notification page total % page %', v_total, v_page;
  end if;
  perform public.mark_notification_read(current_setting('jibhr.employee_notice')::uuid);
  select count(*) into v_unread from public.notifications
  where recipient_id = auth.uid() and read_at is null;
  if v_unread < 1 then
    raise exception 'unread count collapsed after one read';
  end if;
  perform public.mark_all_notifications_read();
  select count(*) into v_unread from public.notifications
  where recipient_id = auth.uid() and read_at is null;
  if v_unread <> 0 then
    raise exception 'mark all left % unread', v_unread;
  end if;
end
$$;
reset role;

-- Inactive account cannot clock in.
select set_config('request.jwt.claim.sub', :'admin', false);
set role authenticated;
select public.set_employee_status(:'peer'::uuid, 'inactive');
reset role;
select set_config('request.jwt.claim.sub', :'peer', false);
set role authenticated;
do $$
begin
  perform public.clock_in('web');
  raise exception 'inactive user clocked in';
exception when others then
  if sqlerrm <> 'inactive' then raise; end if;
end
$$;
reset role;

-- Provision is service-side only, and it writes one primary membership.
insert into auth.users (id, email) values
  ('a6666666-6666-4666-8666-666666666666', 'new.hire@jibcart.test');
select public.provision_employee(
  'a6666666-6666-4666-8666-666666666666',
  :'workspace',
  'نیرو',
  'جدید',
  'new.hire',
  'new.hire@jibcart.test',
  null,
  (select id from public.teams where name = 'فلاتر' limit 1),
  array['employee'],
  :'admin',
  true
);
do $$
begin
  if not exists (
    select 1 from public.team_memberships
    where profile_id = 'a6666666-6666-4666-8666-666666666666' and is_primary and left_at is null
  ) then
    raise exception 'provision missed the primary team';
  end if;
  if not exists (
    select 1 from public.audit_logs
    where entity_id = 'a6666666-6666-4666-8666-666666666666' and action = 'employee.provision'
  ) then
    raise exception 'provision was not audited';
  end if;
end
$$;
set role authenticated;
do $$
begin
  perform public.provision_employee(
    'a6666666-6666-4666-8666-666666666666',
    'a0000000-0000-4000-8000-000000000001',
    'x', 'y', 'abc', 'a@b.co', null,
    'a0000000-0000-4000-8000-000000000001',
    array['employee'],
    'a0000000-0000-4000-8000-000000000001',
    false
  );
  raise exception 'authenticated called provision';
exception when insufficient_privilege then
  null;
end
$$;
reset role;

-- Dashboards and exports stay inside the caller's visibility. Counts are not a side channel.
select set_config('request.jwt.claim.sub', :'employee', false);
set role authenticated;
do $$
declare
  v jsonb;
begin
  v := public.dashboard_summary();
  if jsonb_typeof(v->'team') <> 'null' then
    raise exception 'employee saw team metrics';
  end if;
  if v->'personal'->>'approved_seconds' is null then
    raise exception 'personal attendance missing';
  end if;
end
$$;
do $$
begin
  perform public.attendance_analytics(app.tehran_today() - 10, app.tehran_today(), 'a2222222-2222-4222-8222-222222222222');
  raise exception 'employee read another attendance report';
exception when others then
  if sqlerrm <> 'forbidden' then raise; end if;
end
$$;
do $$
begin
  perform public.report_export('attendance_days', jsonb_build_object(
    'profile_id', 'a2222222-2222-4222-8222-222222222222',
    'from', app.tehran_today() - 10,
    'to', app.tehran_today()
  ), 'excel', 0, 50, true);
  raise exception 'employee exported another person';
exception when others then
  if sqlerrm <> 'forbidden' then raise; end if;
end
$$;
reset role;

select set_config('request.jwt.claim.sub', :'manager', false);
set role authenticated;
do $$
declare
  v jsonb;
begin
  v := public.dashboard_summary();
  if jsonb_typeof(v->'team') <> 'object' or (v->'team'->>'employees')::integer < 1 then
    raise exception 'manager team metrics missing';
  end if;
end
$$;
reset role;

select set_config('request.jwt.claim.sub', :'admin', false);
set role authenticated;
do $$
declare
  v jsonb;
  v_direct bigint;
  v_split bigint;
begin
  v := public.attendance_analytics(app.tehran_today() - 10, app.tehran_today(), 'a3333333-3333-4333-8333-333333333333', null, 'day', 0, 200);
  select coalesce(sum(extract(epoch from (s.ended_at - s.started_at)))::bigint, 0) into v_direct
  from public.attendance_daily_segments s
  join public.attendance_intervals i on i.id = s.interval_id
  where s.profile_id = 'a3333333-3333-4333-8333-333333333333'
    and s.tehran_date between app.tehran_today() - 10 and app.tehran_today()
    and s.superseded_at is null and i.status <> 'void';
  if (v->'totals'->>'recorded_seconds')::bigint <> v_direct then
    raise exception 'analytics recorded % <> segments %', v->'totals'->>'recorded_seconds', v_direct;
  end if;
  if (v->'totals'->>'incomplete')::integer < 1 then
    raise exception 'incomplete interval disappeared from analytics';
  end if;
  v := public.attendance_analytics(app.tehran_today() - 3, app.tehran_today(), 'a4444444-4444-4444-8444-444444444444', null, 'day', 0, 200);
  select coalesce(sum((item->>'recorded_seconds')::bigint), 0) into v_split
  from jsonb_array_elements(v->'rows') item
  where (item->>'recorded_seconds')::bigint in (1800, 5400);
  if v_split <> 7200 then
    raise exception 'midnight duration was duplicated or dropped: %', v_split;
  end if;
  v := public.work_analytics(current_setting('jibhr.sprint_project')::uuid);
  if jsonb_typeof(v->'sprints') <> 'array' or jsonb_array_length(v->'sprints') < 1 then
    raise exception 'sprint analytics missing';
  end if;
  if jsonb_typeof(v->'milestones') <> 'array' then
    raise exception 'milestone analytics missing';
  end if;
end
$$;
reset role;

select set_config('request.jwt.claim.sub', 'a6666666-6666-4666-8666-666666666666', false);
set role authenticated;
do $$
declare
  v jsonb;
begin
  v := public.dashboard_summary();
  if jsonb_typeof(v->'team') <> 'null' then
    raise exception 'new hire saw team metrics';
  end if;
  perform public.work_analytics(current_setting('jibhr.project_id')::uuid);
  raise exception 'hidden project analytics were visible';
exception when others then
  if sqlerrm <> 'forbidden' then raise; end if;
end
$$;
reset role;

insert into public.leave_requests (workspace_id, profile_id, team_id, kind, start_date, end_date, status)
select :'workspace', :'employee', app.primary_team(:'employee'), 'daily', app.tehran_today(), app.tehran_today(), 'approved'
from generate_series(1, 201);
select set_config('request.jwt.claim.sub', :'employee', false);
set role authenticated;
do $$
declare
  v jsonb;
  v_total integer;
  v_rest jsonb;
begin
  v := public.report_export('leave', jsonb_build_object(
    'profile_id', 'a3333333-3333-4333-8333-333333333333',
    'from', app.tehran_today(),
    'to', app.tehran_today()
  ), 'excel', 0, 200, true);
  v_total := (v->>'total_rows')::integer;
  if v_total < 201 or jsonb_array_length(v->'rows') <> 200 then
    raise exception 'export page total % rows %', v_total, jsonb_array_length(v->'rows');
  end if;
  v_rest := public.report_export('leave', jsonb_build_object(
    'profile_id', 'a3333333-3333-4333-8333-333333333333',
    'from', app.tehran_today(),
    'to', app.tehran_today()
  ), 'excel', 200, 200, false);
  if jsonb_array_length(v_rest->'rows') <> v_total - 200 then
    raise exception 'export remainder mismatch';
  end if;
end
$$;
reset role;
do $$
begin
  if not exists (
    select 1 from public.audit_logs
    where action = 'report.export'
      and actor_id = 'a3333333-3333-4333-8333-333333333333'
      and metadata->>'kind' = 'leave'
      and metadata->>'format' = 'excel'
  ) then
    raise exception 'export was not audited';
  end if;
end
$$;

do $$
begin
  if app.period_report_status(array['approved'], 0) <> 'approved' then
    raise exception 'approved period';
  end if;
  if app.period_report_status(array['pending','pending'], 0) <> 'pending' then
    raise exception 'pending period';
  end if;
  if app.period_report_status(array['approved','pending'], 0) <> 'pending' then
    raise exception 'mixed approved and pending';
  end if;
  if app.period_report_status(array['approved','rejected'], 0) <> 'partial' then
    raise exception 'approved and rejected';
  end if;
  if app.period_report_status(array['rejected'], 0) <> 'has_rejected' then
    raise exception 'rejected period';
  end if;
  if app.period_report_status(array['approved'], 1) <> 'needs_revision' then
    raise exception 'incomplete period';
  end if;
  if app.period_report_status('{}'::text[], 0) <> 'none' then
    raise exception 'empty period';
  end if;
end
$$;

select set_config('request.jwt.claim.sub', :'manager', false);
set role authenticated;
do $$
declare
  v jsonb;
  v_page jsonb;
begin
  v := public.dashboard_people('', null, 'name', false, 0, 1);
  if (v->>'total')::integer < 1 or jsonb_array_length(v->'rows') <> 1 then
    raise exception 'people page total % rows %', v->>'total', jsonb_array_length(v->'rows');
  end if;
  v_page := public.dashboard_people('', null, 'name', false, 1, 1);
  if (v_page->>'total')::integer <> (v->>'total')::integer then
    raise exception 'people total changed between pages';
  end if;
  if jsonb_array_length(v->'rows') + jsonb_array_length(v_page->'rows') > (v->>'total')::integer + 1 then
    raise exception 'people pages overlap';
  end if;
end
$$;
reset role;

insert into public.user_roles (workspace_id, profile_id, role_id)
select :'workspace', 'a3333333-3333-4333-8333-333333333333', r.id
from public.roles r
where r.key = 'project_manager';
select set_config('request.jwt.claim.sub', :'employee', false);
set role authenticated;
do $$
declare
  v jsonb;
begin
  v := public.report_export('tasks', jsonb_build_object(
    'project_id', current_setting('jibhr.project_id'),
    'from', app.tehran_today() - 30,
    'to', app.tehran_today()
  ), 'excel', 0, 30, false);
  if v->>'total_rows' is null then
    raise exception 'project export missing total';
  end if;
end
$$;
do $$
begin
  perform public.report_export('attendance_days', jsonb_build_object(
    'profile_id', 'a2222222-2222-4222-8222-222222222222',
    'from', app.tehran_today() - 10,
    'to', app.tehran_today()
  ), 'excel', 0, 30, false);
  raise exception 'project manager exported another person';
exception when others then
  if sqlerrm <> 'forbidden' then raise; end if;
end
$$;
do $$
begin
  perform public.report_export('tasks', jsonb_build_object(
    'from', app.tehran_today() - 30,
    'to', app.tehran_today()
  ), 'excel', 0, 30, false);
  raise exception 'project manager exported the whole organization';
exception when others then
  if sqlerrm <> 'forbidden' then raise; end if;
end
$$;
reset role;
