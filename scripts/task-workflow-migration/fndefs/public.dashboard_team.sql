CREATE OR REPLACE FUNCTION public.dashboard_team()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_me uuid := auth.uid();
  v_attendance uuid[];
  v_employees uuid[];
  v_att_approve record;
  v_leave_approve record;
  v_abs_all boolean;
  v_abs_team boolean;
  v_teams uuid[];
begin
  perform app.require_active();
  if not (app.has_permission('employees.view.team')
       or app.has_permission('employees.view.all')
       or app.has_permission('attendance.view.team')
       or app.has_permission('attendance.view.all')) then
    return null;
  end if;

  v_attendance := array(select app.dash_attendance_profiles());
  v_employees := array(select app.dash_employee_profiles());
  select * into v_att_approve from app.dash_approval_scope('attendance.approve');
  select * into v_leave_approve from app.dash_approval_scope('leave.approve');
  v_abs_all := app.has_permission('absence.record.all');
  v_abs_team := app.has_permission('absence.record.team');
  v_teams := app.dash_approver_teams();

  return jsonb_build_object(
    'employees', (
      select count(*) from public.profiles p
      where p.id <> v_me and p.status = 'active' and p.id in (select unnest(v_employees))
    ),
    'open_intervals', (
      select count(distinct i.profile_id) from public.attendance_intervals i
      where i.status = 'open' and i.profile_id <> v_me and i.profile_id in (select unnest(v_attendance))
    ),
    'pending_reports', (
      select count(distinct r.profile_id) from public.attendance_daily_reports r
      where r.status in ('pending', 'partially_approved', 'needs_revision')
        and r.profile_id in (select unnest(v_attendance))
    ),
    'pending_corrections', (
      select count(*) from public.attendance_corrections c
      where c.status = 'pending' and (v_att_approve.all_teams or c.team_id = any(v_att_approve.teams))
    ),
    'pending_leave', (
      select count(*) from public.leave_requests l
      where l.status = 'pending' and (v_leave_approve.all_teams or l.team_id = any(v_leave_approve.teams))
    ),
    'pending_disputes', (
      select count(*) from public.absence_disputes d
      join public.absence_records a on a.id = d.absence_id
      where d.status = 'pending'
        and (v_abs_all or (v_abs_team and a.team_id = any(v_teams)))
    ),
    'active_tasks', (
      select count(*) from public.tasks t
      where t.archived_at is null and app.can_view_task(t.id)
        and t.primary_assignee_id in (select unnest(v_employees))
        and not app.task_counts_complete(t.id)
    ),
    'review_tasks', (
      select count(*) from public.tasks t
      join public.workflow_statuses s on s.id = t.status_id
      where t.archived_at is null and s.category = 'in_review' and app.can_view_task(t.id)
        and t.primary_assignee_id in (select unnest(v_employees))
    ),
    'overdue_tasks', (
      select count(*) from public.tasks t
      where t.archived_at is null and t.due_at < clock_timestamp()
        and app.can_view_task(t.id) and t.primary_assignee_id in (select unnest(v_employees))
        and not app.task_counts_complete(t.id)
    ),
    'complete_tasks', (
      select count(*) from public.tasks t
      where t.archived_at is null and app.can_view_task(t.id)
        and t.primary_assignee_id in (select unnest(v_employees))
        and app.task_counts_complete(t.id)
    ),
    'people', '[]'::jsonb
  );
end;
$function$
;
