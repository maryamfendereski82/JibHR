-- Dashboard split: four independent sections, and access checked once per
-- distinct key instead of once per row.
--
-- Nothing about who may see what changes. Every scope below is built from the
-- existing checks (has_permission, is_active, current_workspace,
-- is_team_approver); they are only evaluated once per call (or once per team
-- the caller is assigned to) instead of once per row. Data lookups that the
-- checks did internally (a person's primary team, a row's workspace) become
-- joins. supabase/tests/dashboard_split.sql proves the sets and the output
-- equal the previous function for every role.
--
-- Rollback: supabase/rollbacks/20261108120000_dashboard_split_down.sql.

-- 1. Keep the previous implementation, unchanged, as the reference.
alter function public.dashboard_summary() rename to dashboard_summary_v1;
alter function public.dashboard_summary_v1() set schema app;
revoke all on function app.dashboard_summary_v1() from public, anon, authenticated, service_role;

-- 2. Scopes. Internal: callable only by the security definer functions below.

-- Teams the caller approves. is_team_approver runs once per assignment row of
-- the caller, which is exactly the candidate set it can return true for.
create or replace function app.dash_approver_teams()
returns uuid[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(array_agg(distinct a.team_id), '{}')
  from public.team_manager_assignments a
  where a.profile_id = auth.uid()
    and app.is_team_approver(a.team_id, auth.uid());
$$;

-- Exactly { p | app.can_view_attendance(p) }, same branch order:
-- self (same workspace), else view.all (same workspace), else view.team and
-- approver of p's primary team (no workspace check, as before).
create or replace function app.dash_attendance_profiles()
returns setof uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_me uuid := auth.uid();
  v_ws uuid;
  v_all boolean;
  v_team boolean;
  v_teams uuid[];
begin
  if v_me is null or not app.is_active() then
    return;
  end if;
  v_ws := app.current_workspace();
  v_all := app.has_permission('attendance.view.all');
  v_team := app.has_permission('attendance.view.team');
  v_teams := case when v_team then app.dash_approver_teams() else '{}'::uuid[] end;
  return query
    select p.id
    from public.profiles p
    left join lateral (
      select m.team_id from public.team_memberships m
      where m.profile_id = p.id and m.is_primary and m.left_at is null
      limit 1
    ) pt on true
    where case
      when p.id = v_me then v_ws = p.workspace_id
      when v_all then v_ws = p.workspace_id
      else v_team and pt.team_id = any(v_teams)
    end;
end;
$$;

-- Exactly { p | app.can_view_employee(p) }: same workspace, and self, or
-- employees.view.all, or employees.view.team and approver of p's primary team.
create or replace function app.dash_employee_profiles()
returns setof uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_me uuid := auth.uid();
  v_ws uuid;
  v_all boolean;
  v_team boolean;
  v_teams uuid[];
begin
  if v_me is null or not app.is_active() then
    return;
  end if;
  v_ws := app.current_workspace();
  v_all := app.has_permission('employees.view.all');
  v_team := app.has_permission('employees.view.team');
  v_teams := case when v_team then app.dash_approver_teams() else '{}'::uuid[] end;
  return query
    select p.id
    from public.profiles p
    left join lateral (
      select m.team_id from public.team_memberships m
      where m.profile_id = p.id and m.is_primary and m.left_at is null
      limit 1
    ) pt on true
    where p.workspace_id = v_ws
      and (p.id = v_me or v_all or (v_team and pt.team_id = any(v_teams)));
end;
$$;

-- app.can_approve_team(t, p_permission) is true exactly when
-- all_teams or t = any(teams).
create or replace function app.dash_approval_scope(p_permission text, out all_teams boolean, out teams uuid[])
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not app.is_active() then
    all_teams := false;
    teams := '{}';
    return;
  end if;
  all_teams := app.has_permission(p_permission || '.all');
  teams := case when app.has_permission(p_permission || '.team') then app.dash_approver_teams() else '{}'::uuid[] end;
end;
$$;

revoke all on function app.dash_approver_teams() from public, anon, authenticated;
revoke all on function app.dash_attendance_profiles() from public, anon, authenticated;
revoke all on function app.dash_employee_profiles() from public, anon, authenticated;
revoke all on function app.dash_approval_scope(text) from public, anon, authenticated;

-- 3. The four sections. Same expressions as dashboard_summary_v1, except that
-- per-row access calls are replaced by the scopes above.

create or replace function public.dashboard_personal()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_me uuid := auth.uid();
  v_today date := app.tehran_today();
  v_week date := app.week_start(v_today);
  v_month_start date;
  v_month_end date;
  v_today_row record;
  v_week_approved bigint;
  v_month_approved bigint;
begin
  perform app.require_active();
  select b.start_date, b.end_date into v_month_start, v_month_end
  from app.gregorian_to_jalali(v_today) j
  join lateral app.jalali_month_bounds(j.jy, j.jm) b on true;

  select * into v_today_row from public.attendance_totals(v_me, v_today, v_today);
  select approved_seconds into v_week_approved from public.attendance_totals(v_me, v_week, v_week + 6);
  select approved_seconds into v_month_approved from public.attendance_totals(v_me, v_month_start, v_month_end);

  return jsonb_build_object(
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
  );
end;
$$;

-- Null when the caller has no team view, as the 'team' key was before.
create or replace function public.dashboard_team()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
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
$$;

-- Null when the caller sees no project, as the 'projects' key was before.
-- Unchanged logic: its per-row checks run over projects and project tasks only.
create or replace function public.dashboard_projects()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform app.require_active();
  if not (exists (select 1 from public.projects p where app.can_view_project(p.id))
          or app.has_permission('projects.view.all')) then
    return null;
  end if;
  return jsonb_build_object(
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
  );
end;
$$;

create or replace function public.dashboard_queues()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_me uuid := auth.uid();
  v_att_approve record;
  v_leave_approve record;
  v_abs_all boolean;
  v_abs_team boolean;
  v_teams uuid[];
  v_super boolean;
begin
  perform app.require_active();
  select * into v_att_approve from app.dash_approval_scope('attendance.approve');
  select * into v_leave_approve from app.dash_approval_scope('leave.approve');
  v_abs_all := app.has_permission('absence.record.all');
  v_abs_team := app.has_permission('absence.record.team');
  v_teams := app.dash_approver_teams();
  v_super := app.is_super_admin(v_me);

  return jsonb_build_object(
    'attendance', (
      select count(*) from public.attendance_daily_reports r
      where r.status in ('pending', 'partially_approved', 'needs_revision')
        and (v_att_approve.all_teams or r.team_id = any(v_att_approve.teams))
    ),
    'corrections', (
      select count(*) from public.attendance_corrections c
      where c.status = 'pending' and (v_att_approve.all_teams or c.team_id = any(v_att_approve.teams))
    ),
    'leave', (
      select count(*) from public.leave_requests l
      where l.status = 'pending' and (v_leave_approve.all_teams or l.team_id = any(v_leave_approve.teams))
    ),
    'disputes', (
      select count(*) from public.absence_disputes d
      join public.absence_records a on a.id = d.absence_id
      where d.status = 'pending'
        and (v_abs_all or (v_abs_team and a.team_id = any(v_teams)))
    ),
    'task_reviews', (
      select count(*) from public.tasks t
      join public.workflow_statuses s on s.id = t.status_id
      left join lateral (
        select m.team_id from public.team_memberships m
        where m.profile_id = t.primary_assignee_id and m.is_primary and m.left_at is null
        limit 1
      ) pt on true
      where t.archived_at is null and s.category = 'in_review' and t.approval_required and t.approval_state = 'pending'
        and (
          t.reviewer_id = v_me
          or v_super
          or (t.reviewer_id is null and t.project_id is null and pt.team_id = any(v_teams))
          or (t.reviewer_id is null and t.project_id is not null and exists (
            select 1 from public.project_members m
            where m.project_id = t.project_id and m.profile_id = v_me and m.removed_at is null
              and m.member_role in ('manager', 'reviewer')
          ))
        )
    )
  );
end;
$$;

-- 4. The previous entry point, now a wrapper with the same JSON contract.
create function public.dashboard_summary()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform app.require_active();
  return jsonb_build_object(
    'personal', public.dashboard_personal(),
    'team', public.dashboard_team(),
    'projects', public.dashboard_projects(),
    'queues', public.dashboard_queues()
  );
end;
$$;

revoke all on function public.dashboard_personal() from public, anon;
revoke all on function public.dashboard_team() from public, anon;
revoke all on function public.dashboard_projects() from public, anon;
revoke all on function public.dashboard_queues() from public, anon;
revoke all on function public.dashboard_summary() from public, anon;
grant execute on function public.dashboard_personal() to authenticated, service_role;
grant execute on function public.dashboard_team() to authenticated, service_role;
grant execute on function public.dashboard_projects() to authenticated, service_role;
grant execute on function public.dashboard_queues() to authenticated, service_role;
grant execute on function public.dashboard_summary() to authenticated, service_role;
