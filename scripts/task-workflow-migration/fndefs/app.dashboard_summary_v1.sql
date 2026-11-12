CREATE OR REPLACE FUNCTION app.dashboard_summary_v1()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_me uuid := auth.uid();
  v_today date := app.tehran_today();
  v_week date := app.week_start(v_today);
  v_month_start date;
  v_month_end date;
  v_show_team boolean;
  v_today_row record;
  v_week_approved bigint;
  v_month_approved bigint;
  v_team jsonb;
  v_projects jsonb;
begin
  perform app.require_active();
  select b.start_date, b.end_date into v_month_start, v_month_end
  from app.gregorian_to_jalali(v_today) j
  join lateral app.jalali_month_bounds(j.jy, j.jm) b on true;

  select * into v_today_row from public.attendance_totals(v_me, v_today, v_today);
  select approved_seconds into v_week_approved from public.attendance_totals(v_me, v_week, v_week + 6);
  select approved_seconds into v_month_approved from public.attendance_totals(v_me, v_month_start, v_month_end);

  v_show_team := app.has_permission('employees.view.team')
    or app.has_permission('employees.view.all')
    or app.has_permission('attendance.view.team')
    or app.has_permission('attendance.view.all');

  if v_show_team then
    select jsonb_build_object(
      'employees', (
        select count(*) from public.profiles p
        where p.id <> v_me and p.status = 'active' and app.can_view_employee(p.id)
      ),
      'open_intervals', (
        select count(distinct i.profile_id) from public.attendance_intervals i
        where i.status = 'open' and i.profile_id <> v_me and app.can_view_attendance(i.profile_id)
      ),
      'pending_reports', (
        select count(distinct r.profile_id) from public.attendance_daily_reports r
        where r.status in ('pending', 'partially_approved', 'needs_revision')
          and app.can_view_attendance(r.profile_id)
      ),
      'pending_corrections', (
        select count(*) from public.attendance_corrections c
        where c.status = 'pending' and app.can_approve_team(c.team_id, 'attendance.approve')
      ),
      'pending_leave', (
        select count(*) from public.leave_requests l
        where l.status = 'pending' and app.can_approve_team(l.team_id, 'leave.approve')
      ),
      'pending_disputes', (
        select count(*) from public.absence_disputes d
        join public.absence_records a on a.id = d.absence_id
        where d.status = 'pending'
          and (
            app.has_permission('absence.record.all')
            or (app.has_permission('absence.record.team') and app.is_team_approver(a.team_id, v_me))
          )
      ),
      'active_tasks', (
        select count(*) from public.tasks t
        where t.archived_at is null and app.can_view_task(t.id)
          and app.can_view_employee(t.primary_assignee_id)
          and not app.task_counts_complete(t.id)
      ),
      'review_tasks', (
        select count(*) from public.tasks t
        join public.workflow_statuses s on s.id = t.status_id
        where t.archived_at is null and s.category = 'in_review' and app.can_view_task(t.id)
          and app.can_view_employee(t.primary_assignee_id)
      ),
      'overdue_tasks', (
        select count(*) from public.tasks t
        where t.archived_at is null and t.due_at < clock_timestamp()
          and app.can_view_task(t.id) and app.can_view_employee(t.primary_assignee_id)
          and not app.task_counts_complete(t.id)
      ),
      'complete_tasks', (
        select count(*) from public.tasks t
        where t.archived_at is null and app.can_view_task(t.id)
          and app.can_view_employee(t.primary_assignee_id)
          and app.task_counts_complete(t.id)
      ),
      'people', '[]'::jsonb
    ) into v_team;
  end if;

  if exists (select 1 from public.projects p where app.can_view_project(p.id))
     or app.has_permission('projects.view.all') then
    select jsonb_build_object(
      'active', (select count(*) from public.projects p where p.status = 'active' and app.can_view_project(p.id)),
      'archived', (select count(*) from public.projects p where p.status = 'archived' and app.can_view_project(p.id)),
      'tasks', (select count(*) from public.tasks t where t.archived_at is null and t.project_id is not null and app.can_view_task(t.id)),
      'awaiting_review', (
        select count(*) from public.tasks t
        join public.workflow_statuses s on s.id = t.status_id
        where t.archived_at is null and t.project_id is not null and s.category = 'in_review' and app.can_view_task(t.id)
      ),
      'overdue', (
        select count(*) from public.tasks t
        where t.archived_at is null and t.project_id is not null and t.due_at < clock_timestamp()
          and app.can_view_task(t.id) and not app.task_counts_complete(t.id)
      ),
      'complete', (
        select count(*) from public.tasks t
        where t.archived_at is null and t.project_id is not null and app.can_view_task(t.id) and app.task_counts_complete(t.id)
      ),
      'active_sprints', (
        select count(*) from public.sprints s where s.status = 'active' and app.can_view_project(s.project_id)
      ),
      'upcoming_milestones', (
        select count(*) from public.milestones m
        where m.status in ('upcoming', 'in_progress') and app.can_view_project(m.project_id)
      ),
      'reached_milestones', (
        select count(*) from public.milestones m
        where m.status = 'reached' and app.can_view_project(m.project_id)
      )
    ) into v_projects;
  end if;

  return jsonb_build_object(
    'personal', jsonb_build_object(
      'open', exists (select 1 from public.attendance_intervals i where i.profile_id = v_me and i.status = 'open'),
      'incomplete', (select count(*) from public.attendance_intervals i where i.profile_id = v_me and i.status = 'incomplete'),
      'recorded_seconds', coalesce(v_today_row.recorded_seconds, 0),
      'pending_seconds', coalesce(v_today_row.pending_seconds, 0),
      'approved_seconds', coalesce(v_today_row.approved_seconds, 0),
      'rejected_seconds', coalesce(v_today_row.rejected_seconds, 0),
      'week_approved_seconds', coalesce(v_week_approved, 0),
      'month_approved_seconds', coalesce(v_month_approved, 0),
      'personal_tasks', (
        select count(*) from public.tasks t
        where t.primary_assignee_id = v_me and t.project_id is null and t.archived_at is null
          and not app.task_counts_complete(t.id)
      ),
      'project_tasks', (
        select count(*) from public.tasks t
        where t.primary_assignee_id = v_me and t.project_id is not null and t.archived_at is null
          and app.can_view_task(t.id) and not app.task_counts_complete(t.id)
      ),
      'awaiting_review', (
        select count(*) from public.tasks t
        join public.workflow_statuses s on s.id = t.status_id
        where t.primary_assignee_id = v_me and t.archived_at is null and s.category = 'in_review' and app.can_view_task(t.id)
      ),
      'needs_revision', (
        select count(*) from public.tasks t
        join public.workflow_statuses s on s.id = t.status_id
        where t.primary_assignee_id = v_me and t.archived_at is null and app.can_view_task(t.id)
          and (s.category = 'changes_requested' or t.approval_state = 'changes_requested')
      ),
      'leave_pending', (select count(*) from public.leave_requests l where l.profile_id = v_me and l.status = 'pending'),
      'unread', (select count(*) from public.notifications n where n.recipient_id = v_me and n.read_at is null),
      'statuses', coalesce((
        select jsonb_agg(jsonb_build_object('name', s.name, 'category', s.category, 'total', counted.total) order by s.position)
        from (
          select t.status_id, count(*)::integer as total
          from public.tasks t
          where t.primary_assignee_id = v_me and t.archived_at is null and app.can_view_task(t.id)
          group by t.status_id
        ) counted
        join public.workflow_statuses s on s.id = counted.status_id
      ), '[]'::jsonb)
    ),
    'team', v_team,
    'projects', v_projects,
    'queues', jsonb_build_object(
      'attendance', (
        select count(*) from public.attendance_daily_reports r
        where r.status in ('pending', 'partially_approved', 'needs_revision')
          and app.can_approve_team(r.team_id, 'attendance.approve')
      ),
      'corrections', (
        select count(*) from public.attendance_corrections c
        where c.status = 'pending' and app.can_approve_team(c.team_id, 'attendance.approve')
      ),
      'leave', (
        select count(*) from public.leave_requests l
        where l.status = 'pending' and app.can_approve_team(l.team_id, 'leave.approve')
      ),
      'disputes', (
        select count(*) from public.absence_disputes d
        join public.absence_records a on a.id = d.absence_id
        where d.status = 'pending'
          and (
            app.has_permission('absence.record.all')
            or (app.has_permission('absence.record.team') and app.is_team_approver(a.team_id, v_me))
          )
      ),
      'task_reviews', (
        select count(*) from public.tasks t
        join public.workflow_statuses s on s.id = t.status_id
        where t.archived_at is null and s.category = 'in_review' and t.approval_required and t.approval_state = 'pending'
          and (
            t.reviewer_id = v_me
            or app.is_super_admin(v_me)
            or (t.reviewer_id is null and t.project_id is null and app.is_team_approver(app.primary_team(t.primary_assignee_id), v_me))
            or (t.reviewer_id is null and t.project_id is not null and exists (
              select 1 from public.project_members m
              where m.project_id = t.project_id and m.profile_id = v_me and m.removed_at is null
                and m.member_role in ('manager', 'reviewer')
            ))
          )
      )
    )
  );
end;
$function$
;
