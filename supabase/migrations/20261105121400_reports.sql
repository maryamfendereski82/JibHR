-- Aggregates stay in Postgres. security definer reads are filtered with the
-- same can_view helpers as RLS, so a hidden project cannot leak through a count.

create or replace function app.attendance_scope(p_profile uuid, p_team uuid)
returns setof uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform app.require_active();
  if p_profile is not null then
    if not app.can_view_attendance(p_profile) then
      raise exception 'forbidden';
    end if;
    return next p_profile;
    return;
  end if;
  if p_team is not null then
    if not (
      app.has_permission('attendance.view.all')
      or (app.has_permission('attendance.view.team') and app.is_team_approver(p_team, auth.uid()))
    ) then
      raise exception 'forbidden';
    end if;
    return query
    select m.profile_id
    from public.team_memberships m
    where m.team_id = p_team and m.left_at is null and m.is_primary
      and app.can_view_attendance(m.profile_id);
    return;
  end if;
  if app.has_permission('attendance.view.all') then
    return query
    select id from public.profiles
    where workspace_id = app.current_workspace() and status = 'active';
    return;
  end if;
  if app.has_permission('attendance.view.team') then
    return query
    select m.profile_id
    from public.team_memberships m
    join public.team_manager_assignments a
      on a.team_id = m.team_id and a.profile_id = auth.uid() and a.revoked_at is null
    where m.left_at is null and m.is_primary and app.can_view_attendance(m.profile_id);
    return;
  end if;
  return next auth.uid();
end;
$$;

revoke all on function app.attendance_scope(uuid, uuid) from public, anon, authenticated;

create or replace function app.assert_report_export(
  p_profile uuid,
  p_team uuid,
  p_project uuid
)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_self boolean := p_profile is null and p_team is null and p_project is null
    and not app.has_permission('attendance.view.all')
    and not app.has_permission('attendance.view.team')
    and not app.has_permission('employees.view.all')
    and not app.has_permission('projects.view.all')
    and not app.has_permission('tasks.view.all');
begin
  perform app.require_active();
  if p_profile = auth.uid()
     or (v_self and p_project is null and not app.has_permission('reports.export.project')) then
    if app.has_permission('reports.view.self') or app.has_permission('reports.export.all') then
      return;
    end if;
    raise exception 'forbidden';
  end if;
  if app.has_permission('reports.export.all') then
    if p_project is not null and not app.can_view_project(p_project) then
      raise exception 'forbidden';
    end if;
    if p_profile is not null and not app.can_view_attendance(p_profile) and not app.can_view_employee(p_profile) then
      raise exception 'forbidden';
    end if;
    return;
  end if;
  if app.has_permission('reports.export.team') then
    if p_team is not null and app.is_team_approver(p_team, auth.uid()) then
      return;
    end if;
    if p_profile is not null and app.is_team_approver(app.primary_team(p_profile), auth.uid()) then
      return;
    end if;
    if p_profile is null and p_team is null and p_project is null
       and app.has_permission('attendance.view.team') then
      return;
    end if;
  end if;
  if app.has_permission('reports.export.project')
     and p_project is not null
     and p_team is null
     and app.can_view_project(p_project)
     and (p_profile is null or p_profile = auth.uid() or app.can_view_employee(p_profile)) then
    return;
  end if;
  raise exception 'forbidden';
end;
$$;

revoke all on function app.assert_report_export(uuid, uuid, uuid) from public, anon, authenticated;

create or replace function public.dashboard_summary()
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
$$;

create or replace function app.period_report_status(p_statuses text[], p_incomplete integer)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when coalesce(p_incomplete, 0) > 0 or 'needs_revision' = any (p_statuses) then 'needs_revision'
    when 'partially_approved' = any (p_statuses)
      or ('rejected' = any (p_statuses) and ('approved' = any (p_statuses) or 'pending' = any (p_statuses))) then 'partial'
    when 'rejected' = any (p_statuses) then 'has_rejected'
    when 'pending' = any (p_statuses) then 'pending'
    when 'approved' = any (p_statuses) then 'approved'
    else 'none'
  end;
$$;

revoke all on function app.period_report_status(text[], integer) from public, anon, authenticated;

create or replace function public.attendance_analytics(
  p_from date,
  p_to date,
  p_profile uuid default null,
  p_team uuid default null,
  p_grain text default 'day',
  p_offset integer default 0,
  p_limit integer default 30
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_temp
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 30), 1), 200);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_rows jsonb;
  v_totals jsonb;
  v_count integer;
begin
  perform app.require_active();
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'invalid_range';
  end if;
  if p_grain not in ('day', 'week', 'jalali_month') then
    raise exception 'invalid_grain';
  end if;

  drop table if exists pg_temp.report_days;
  create temp table report_days on commit drop as
  with people as (
    select app.attendance_scope(p_profile, p_team) as profile_id
  ),
  segments as (
    select
      s.profile_id,
      case
        when p_grain = 'week' then app.week_start(s.tehran_date)
        when p_grain = 'jalali_month' then b.start_date
        else s.tehran_date
      end as period_start,
      case
        when p_grain = 'week' then app.week_start(s.tehran_date) + 6
        when p_grain = 'jalali_month' then b.end_date
        else s.tehran_date
      end as period_end,
      s.interval_id,
      extract(epoch from (s.ended_at - s.started_at)) as seconds,
      s.approval_mode,
      ri.decision
    from public.attendance_daily_segments s
    join public.attendance_intervals i on i.id = s.interval_id
    left join public.attendance_report_items ri on ri.segment_id = s.id
    join people pe on pe.profile_id = s.profile_id
    left join lateral app.gregorian_to_jalali(s.tehran_date) j on true
    left join lateral app.jalali_month_bounds(j.jy, j.jm) b on true
    where s.tehran_date between p_from and p_to
      and s.superseded_at is null
      and i.status <> 'void'
  )
  select
    se.profile_id,
    se.period_start,
    se.period_end,
    coalesce(sum(se.seconds), 0)::bigint as recorded_seconds,
    coalesce(sum(se.seconds) filter (
      where se.approval_mode = 'report' and coalesce(se.decision, 'pending') = 'pending'
    ), 0)::bigint as pending_seconds,
    coalesce(sum(se.seconds) filter (
      where se.approval_mode = 'correction' or se.decision = 'approved'
    ), 0)::bigint as approved_seconds,
    coalesce(sum(se.seconds) filter (where se.decision = 'rejected'), 0)::bigint as rejected_seconds,
    count(distinct se.interval_id)::integer as interval_count
  from segments se
  group by se.profile_id, se.period_start, se.period_end;

  select count(*)::integer into v_count from report_days;
  select jsonb_build_object(
    'recorded_seconds', coalesce((select sum(recorded_seconds) from report_days), 0),
    'pending_seconds', coalesce((select sum(pending_seconds) from report_days), 0),
    'approved_seconds', coalesce((select sum(approved_seconds) from report_days), 0),
    'rejected_seconds', coalesce((select sum(rejected_seconds) from report_days), 0),
    'intervals', coalesce((select sum(interval_count) from report_days), 0),
    'incomplete', (
      select count(*) from public.attendance_intervals i
      where i.status = 'incomplete'
        and i.profile_id in (select app.attendance_scope(p_profile, p_team))
        and app.tehran_date(coalesce(i.effective_started_at, i.original_started_at)) between p_from and p_to
    ),
    'pending_reports', (
      select count(*) from public.attendance_daily_reports r
      where r.status in ('pending', 'partially_approved', 'needs_revision')
        and r.profile_id in (select app.attendance_scope(p_profile, p_team))
        and r.tehran_date between p_from and p_to
    )
  ) into v_totals;

  select coalesce(jsonb_agg(jsonb_build_object(
    'profile_id', g.profile_id,
    'name', trim(concat(p.first_name, ' ', p.last_name)),
    'period_start', g.period_start,
    'period_end', g.period_end,
    'recorded_seconds', g.recorded_seconds,
    'pending_seconds', g.pending_seconds,
    'approved_seconds', g.approved_seconds,
    'rejected_seconds', g.rejected_seconds,
    'interval_count', g.interval_count,
    'report_status', app.period_report_status(coalesce((
      select array_agg(latest.status)
      from (
        select distinct on (r.tehran_date) r.status
        from public.attendance_daily_reports r
        where r.profile_id = g.profile_id
          and r.tehran_date between g.period_start and g.period_end
        order by r.tehran_date, r.sequence desc
      ) latest
    ), '{}'::text[]), coalesce((
      select count(*)::integer from public.attendance_intervals i
      where i.profile_id = g.profile_id and i.status = 'incomplete'
        and app.tehran_date(coalesce(i.effective_started_at, i.original_started_at)) between g.period_start and g.period_end
    ), 0))
  ) order by g.period_start desc, p.last_name), '[]'::jsonb)
  into v_rows
  from (
    select * from report_days
    order by period_start desc, profile_id
    offset v_offset limit v_limit
  ) g
  join public.profiles p on p.id = g.profile_id;

  return jsonb_build_object('totals', v_totals, 'rows', coalesce(v_rows, '[]'::jsonb), 'total_rows', coalesce(v_count, 0));
end;
$$;

create or replace function public.work_analytics(p_project uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform app.require_active();
  if p_project is not null and not app.can_view_project(p_project) then
    raise exception 'forbidden';
  end if;
  return jsonb_build_object(
    'by_status', coalesce((
      select jsonb_agg(jsonb_build_object('name', name, 'category', category, 'total', total) order by position)
      from (
        select s.name, s.category, s.position, count(*)::integer as total
        from public.tasks t
        join public.workflow_statuses s on s.id = t.status_id
        where t.archived_at is null and app.can_view_task(t.id)
          and (p_project is null or t.project_id = p_project)
        group by s.name, s.category, s.position
      ) buckets
    ), '[]'::jsonb),
    'by_priority', coalesce((
      select jsonb_agg(jsonb_build_object('priority', priority, 'total', total) order by priority)
      from (
        select t.priority, count(*)::integer as total
        from public.tasks t
        where t.archived_at is null and app.can_view_task(t.id)
          and (p_project is null or t.project_id = p_project)
        group by t.priority
      ) buckets
    ), '[]'::jsonb),
    'by_assignee', coalesce((
      select jsonb_agg(jsonb_build_object('name', name, 'total', total) order by total desc)
      from (
        select trim(concat(p.first_name, ' ', p.last_name)) as name, count(*)::integer as total
        from public.tasks t
        join public.profiles p on p.id = t.primary_assignee_id
        where t.archived_at is null and app.can_view_task(t.id)
          and (p_project is null or t.project_id = p_project)
        group by p.first_name, p.last_name
      ) buckets
    ), '[]'::jsonb),
    'complete', (
      select count(*) from public.tasks t
      where t.archived_at is null and app.can_view_task(t.id) and app.task_counts_complete(t.id)
        and (p_project is null or t.project_id = p_project)
    ),
    'remaining', (
      select count(*) from public.tasks t
      where t.archived_at is null and app.can_view_task(t.id) and not app.task_counts_complete(t.id)
        and (p_project is null or t.project_id = p_project)
    ),
    'awaiting', (
      select count(*) from public.tasks t
      join public.workflow_statuses s on s.id = t.status_id
      where t.archived_at is null and app.can_view_task(t.id)
        and t.approval_required and t.approval_state = 'pending' and s.category = 'in_review'
        and (p_project is null or t.project_id = p_project)
    ),
    'revision', (
      select count(*) from public.tasks t
      join public.workflow_statuses s on s.id = t.status_id
      where t.archived_at is null and app.can_view_task(t.id)
        and (s.category = 'changes_requested' or t.approval_state = 'changes_requested')
        and (p_project is null or t.project_id = p_project)
    ),
    'blocked', (
      select count(*) from public.tasks t
      join public.workflow_statuses s on s.id = t.status_id
      where t.archived_at is null and app.can_view_task(t.id) and s.category = 'blocked'
        and not app.task_counts_complete(t.id)
        and (p_project is null or t.project_id = p_project)
    ),
    'overdue', (
      select count(*) from public.tasks t
      where t.archived_at is null and app.can_view_task(t.id)
        and t.due_at < clock_timestamp() and not app.task_counts_complete(t.id)
        and (p_project is null or t.project_id = p_project)
    ),
    'sprints', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', s.id, 'project_id', s.project_id, 'name', s.name, 'status', s.status,
        'start_date', s.start_date, 'end_date', s.end_date,
        'total', coalesce(c.total, 0), 'complete', coalesce(c.complete, 0),
        'remaining', greatest(coalesce(c.total, 0) - coalesce(c.complete, 0), 0),
        'percent', case when coalesce(c.total, 0) = 0 then 0 else (c.complete * 100 / c.total) end,
        'summary', s.summary
      ) order by s.start_date desc, s.id)
      from public.sprints s
      left join lateral (
        select count(t.id)::integer as total,
          count(t.id) filter (where app.task_counts_complete(t.id))::integer as complete
        from public.sprint_tasks link
        join public.tasks t on t.id = link.task_id and t.archived_at is null and app.can_view_task(t.id)
        where link.sprint_id = s.id and link.removed_at is null
      ) c on true
      where app.can_view_project(s.project_id) and (p_project is null or s.project_id = p_project)
    ), '[]'::jsonb),
    'milestones', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', m.id, 'project_id', m.project_id, 'title', m.title, 'status', m.status,
        'target_date', m.target_date,
        'total', coalesce(c.total, 0), 'complete', coalesce(c.complete, 0),
        'remaining', greatest(coalesce(c.total, 0) - coalesce(c.complete, 0), 0),
        'percent', case when coalesce(c.total, 0) = 0 then 0 else (c.complete * 100 / c.total) end
      ) order by m.target_date, m.id)
      from public.milestones m
      left join lateral (
        select count(t.id)::integer as total,
          count(t.id) filter (where app.task_counts_complete(t.id))::integer as complete
        from public.milestone_tasks mt
        join public.tasks t on t.id = mt.task_id and t.archived_at is null and app.can_view_task(t.id)
        where mt.milestone_id = m.id
      ) c on true
      where app.can_view_project(m.project_id) and (p_project is null or m.project_id = p_project)
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.leave_absence_report(
  p_kind text,
  p_from date,
  p_to date,
  p_profile uuid default null,
  p_team uuid default null,
  p_status text default null,
  p_offset integer default 0,
  p_limit integer default 30
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_temp
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 30), 1), 200);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_count integer;
  v_rows jsonb;
  v_counts jsonb;
begin
  perform app.require_active();
  if p_kind not in ('leave', 'absence') or p_from is null or p_to is null or p_to < p_from then
    raise exception 'invalid_range';
  end if;
  if p_profile is not null and not (
    (p_kind = 'leave' and app.can_view_leave(p_profile, app.primary_team(p_profile)))
    or (p_kind = 'absence' and app.can_view_absence(p_profile, app.primary_team(p_profile)))
  ) then
    raise exception 'forbidden';
  end if;
  if p_team is not null and not (
    app.has_permission(case when p_kind = 'leave' then 'leave.view.all' else 'absence.view.all' end)
    or (
      app.has_permission(case when p_kind = 'leave' then 'leave.view.team' else 'absence.view.team' end)
      and app.is_team_approver(p_team, auth.uid())
    )
  ) then
    raise exception 'forbidden';
  end if;

  if p_kind = 'leave' then
    drop table if exists pg_temp.report_leave;
    create temp table report_leave on commit drop as
    select l.id, l.profile_id, trim(concat(p.first_name, ' ', p.last_name)) as name,
      l.kind, l.start_date, l.end_date, l.hours_date, l.start_time, l.end_time, l.status, l.note
    from public.leave_requests l
    join public.profiles p on p.id = l.profile_id
    where app.can_view_leave(l.profile_id, l.team_id)
      and (p_profile is null or l.profile_id = p_profile)
      and (p_team is null or l.team_id = p_team)
      and (p_status is null or l.status = p_status)
      and (
        (l.kind = 'daily' and l.start_date <= p_to and l.end_date >= p_from)
        or (l.kind = 'hourly' and l.hours_date between p_from and p_to)
      );
    select count(*)::integer into v_count from report_leave;
    select jsonb_build_object(
      'pending', count(*) filter (where status = 'pending'),
      'approved', count(*) filter (where status = 'approved'),
      'rejected', count(*) filter (where status = 'rejected'),
      'daily', count(*) filter (where kind = 'daily' and start_date = end_date),
      'multi_day', count(*) filter (where kind = 'daily' and end_date > start_date),
      'hourly', count(*) filter (where kind = 'hourly')
    ) into v_counts from report_leave;
    select coalesce(jsonb_agg(to_jsonb(page) order by page.start_date desc nulls last, page.hours_date desc nulls last), '[]'::jsonb)
    into v_rows
    from (
      select * from report_leave
      order by start_date desc nulls last, hours_date desc nulls last, id
      offset v_offset limit v_limit
    ) page;
  else
    drop table if exists pg_temp.report_absence;
    create temp table report_absence on commit drop as
    select a.id, a.profile_id, trim(concat(p.first_name, ' ', p.last_name)) as name,
      a.start_date, a.end_date, a.reason,
      trim(concat(rec.first_name, ' ', rec.last_name)) as recorded_by,
      d.explanation, d.status as dispute_status
    from public.absence_records a
    join public.profiles p on p.id = a.profile_id
    join public.profiles rec on rec.id = a.recorded_by
    left join lateral (
      select explanation, status from public.absence_disputes
      where absence_id = a.id
      order by created_at desc
      limit 1
    ) d on true
    where app.can_view_absence(a.profile_id, a.team_id)
      and (p_profile is null or a.profile_id = p_profile)
      and (p_team is null or a.team_id = p_team)
      and a.start_date <= p_to and a.end_date >= p_from;
    select count(*)::integer into v_count from report_absence;
    select '{}'::jsonb into v_counts;
    select coalesce(jsonb_agg(to_jsonb(page) order by page.start_date desc), '[]'::jsonb)
    into v_rows
    from (
      select * from report_absence order by start_date desc, id offset v_offset limit v_limit
    ) page;
  end if;
  return jsonb_build_object('counts', coalesce(v_counts, '{}'::jsonb), 'rows', coalesce(v_rows, '[]'::jsonb), 'total_rows', coalesce(v_count, 0));
end;
$$;

create or replace function public.report_filters()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform app.require_active();
  return jsonb_build_object(
    'teams', coalesce((
      select jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name) order by t.name)
      from public.teams t
      where t.status = 'active' and t.workspace_id = app.current_workspace()
        and (
          app.has_permission('attendance.view.all')
          or app.has_permission('employees.view.all')
          or app.is_team_approver(t.id, auth.uid())
        )
    ), '[]'::jsonb),
    'projects', coalesce((
      select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name) order by p.name)
      from public.projects p
      where p.status = 'active' and app.can_view_project(p.id)
    ), '[]'::jsonb),
    'people', coalesce((
      select jsonb_agg(jsonb_build_object('id', p.id, 'name', trim(concat(p.first_name, ' ', p.last_name))) order by p.last_name)
      from public.profiles p
      where p.status = 'active' and p.workspace_id = app.current_workspace() and app.can_view_employee(p.id)
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.report_export(
  p_kind text,
  p_filters jsonb default '{}'::jsonb,
  p_format text default 'excel',
  p_offset integer default 0,
  p_limit integer default 200,
  p_audit boolean default true
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_temp
as $$
declare
  v_filters jsonb := coalesce(p_filters, '{}'::jsonb);
  v_profile uuid := nullif(v_filters->>'profile_id', '')::uuid;
  v_team uuid := nullif(v_filters->>'team_id', '')::uuid;
  v_project uuid := nullif(v_filters->>'project_id', '')::uuid;
  v_from date := nullif(v_filters->>'from', '')::date;
  v_to date := nullif(v_filters->>'to', '')::date;
  v_status text := nullif(v_filters->>'status', '');
  v_priority text := nullif(v_filters->>'priority', '');
  v_grain text := coalesce(nullif(v_filters->>'grain', ''), 'day');
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_limit integer := least(greatest(coalesce(p_limit, 200), 1), 200);
  v_payload jsonb;
  v_count integer;
  v_rows jsonb;
begin
  perform app.assert_report_export(v_profile, v_team, v_project);
  if p_kind not in (
    'attendance_days', 'attendance_intervals', 'attendance_approvals',
    'leave', 'absence', 'tasks', 'projects', 'sprints', 'milestones'
  ) then
    raise exception 'invalid_kind';
  end if;
  if v_from is null then v_from := app.tehran_today() - 30; end if;
  if v_to is null then v_to := app.tehran_today(); end if;

  if p_kind = 'attendance_days' then
    v_payload := public.attendance_analytics(v_from, v_to, v_profile, v_team, v_grain, v_offset, v_limit);
  elsif p_kind = 'leave' or p_kind = 'absence' then
    v_payload := public.leave_absence_report(p_kind, v_from, v_to, v_profile, v_team, v_status, v_offset, v_limit);
  elsif p_kind = 'attendance_intervals' then
    drop table if exists pg_temp.report_export_rows;
    create temp table report_export_rows on commit drop as
    select trim(concat(p.first_name, ' ', p.last_name)) as name,
      s.id as row_id, s.tehran_date::text as period_start, s.started_at, s.ended_at,
      extract(epoch from (s.ended_at - s.started_at))::bigint as recorded_seconds,
      coalesce(ri.decision, 'pending') as decision, s.approval_mode
    from public.attendance_daily_segments s
    join public.attendance_intervals i on i.id = s.interval_id
    join public.profiles p on p.id = s.profile_id
    left join public.attendance_report_items ri on ri.segment_id = s.id
    where s.profile_id in (select app.attendance_scope(v_profile, v_team))
      and s.tehran_date between v_from and v_to
      and s.superseded_at is null and i.status <> 'void';
    select count(*)::integer into v_count from report_export_rows;
    select coalesce(jsonb_agg(to_jsonb(page)), '[]'::jsonb) into v_rows
    from (select * from report_export_rows order by period_start desc, started_at, row_id offset v_offset limit v_limit) page;
    v_payload := jsonb_build_object('rows', v_rows, 'total_rows', v_count);
  elsif p_kind = 'attendance_approvals' then
    drop table if exists pg_temp.report_export_rows;
    create temp table report_export_rows on commit drop as
    select trim(concat(p.first_name, ' ', p.last_name)) as name,
      ri.id as row_id, r.tehran_date::text as period_start, r.status as report_status,
      ri.decision, ri.decided_at, coalesce(ri.reason, '') as reason
    from public.attendance_report_items ri
    join public.attendance_daily_reports r on r.id = ri.report_id
    join public.profiles p on p.id = r.profile_id
    where r.profile_id in (select app.attendance_scope(v_profile, v_team))
      and r.tehran_date between v_from and v_to
      and (v_status is null or ri.decision = v_status);
    select count(*)::integer into v_count from report_export_rows;
    select coalesce(jsonb_agg(to_jsonb(page)), '[]'::jsonb) into v_rows
    from (select * from report_export_rows order by period_start desc, row_id offset v_offset limit v_limit) page;
    v_payload := jsonb_build_object('rows', v_rows, 'total_rows', v_count);
  elsif p_kind = 'tasks' then
    drop table if exists pg_temp.report_export_rows;
    create temp table report_export_rows on commit drop as
    select t.id as row_id, t.title, coalesce(pr.name, '') as project_name, s.name as status_name, s.category,
      t.priority, trim(concat(p.first_name, ' ', p.last_name)) as assignee,
      t.due_at, t.approval_state, app.task_counts_complete(t.id) as complete
    from public.tasks t
    join public.workflow_statuses s on s.id = t.status_id
    join public.profiles p on p.id = t.primary_assignee_id
    left join public.projects pr on pr.id = t.project_id
    where t.archived_at is null and app.can_view_task(t.id)
      and (v_project is null or t.project_id = v_project)
      and (v_profile is null or t.primary_assignee_id = v_profile)
      and (v_priority is null or t.priority = v_priority)
      and (v_status is null or s.category = v_status or s.key = v_status);
    select count(*)::integer into v_count from report_export_rows;
    select coalesce(jsonb_agg(to_jsonb(page)), '[]'::jsonb) into v_rows
    from (select * from report_export_rows order by title, row_id offset v_offset limit v_limit) page;
    v_payload := jsonb_build_object('rows', v_rows, 'total_rows', v_count);
  elsif p_kind = 'projects' then
    select count(*)::integer into v_count from public.projects p
    where app.can_view_project(p.id) and (v_project is null or p.id = v_project);
    select coalesce(jsonb_agg(jsonb_build_object(
      'name', p.name, 'status', p.status, 'visibility', p.visibility,
      'tasks', (select count(*) from public.tasks t where t.project_id = p.id and t.archived_at is null and app.can_view_task(t.id)),
      'complete', (select count(*) from public.tasks t where t.project_id = p.id and t.archived_at is null and app.can_view_task(t.id) and app.task_counts_complete(t.id))
    ) order by p.name), '[]'::jsonb) into v_rows
    from (
      select * from public.projects p
      where app.can_view_project(p.id) and (v_project is null or p.id = v_project)
      order by p.name, p.id offset v_offset limit v_limit
    ) p;
    v_payload := jsonb_build_object('rows', v_rows, 'total_rows', v_count);
  elsif p_kind = 'sprints' then
    v_payload := public.work_analytics(v_project);
    v_payload := jsonb_build_object(
      'total_rows', jsonb_array_length(coalesce(v_payload->'sprints', '[]'::jsonb)),
      'rows', coalesce((
        select jsonb_agg(item) from (
          select item from jsonb_array_elements(v_payload->'sprints') with ordinality as listed(item, ord)
          order by ord offset v_offset limit v_limit
        ) page
      ), '[]'::jsonb)
    );
  else
    v_payload := public.work_analytics(v_project);
    v_payload := jsonb_build_object(
      'total_rows', jsonb_array_length(coalesce(v_payload->'milestones', '[]'::jsonb)),
      'rows', coalesce((
        select jsonb_agg(item) from (
          select item from jsonb_array_elements(v_payload->'milestones') with ordinality as listed(item, ord)
          order by ord offset v_offset limit v_limit
        ) page
      ), '[]'::jsonb)
    );
  end if;

  if v_offset = 0 and p_audit then
    perform app.audit(
      app.current_workspace(), auth.uid(), 'report.export', 'report', null,
      jsonb_build_object(
        'kind', p_kind, 'format', coalesce(p_format, 'excel'), 'filters', v_filters,
        'count', coalesce((v_payload->>'total_rows')::integer, 0)
      )
    );
  end if;
  return v_payload;
end;
$$;

revoke all on function public.dashboard_summary() from public, anon;
revoke all on function public.attendance_analytics(date, date, uuid, uuid, text, integer, integer) from public, anon;
revoke all on function public.work_analytics(uuid) from public, anon;
revoke all on function public.leave_absence_report(text, date, date, uuid, uuid, text, integer, integer) from public, anon;
revoke all on function public.report_filters() from public, anon;
revoke all on function public.report_export(text, jsonb, text, integer, integer, boolean) from public, anon;
grant execute on function public.dashboard_summary() to authenticated, service_role;
grant execute on function public.attendance_analytics(date, date, uuid, uuid, text, integer, integer) to authenticated, service_role;
grant execute on function public.work_analytics(uuid) to authenticated, service_role;
grant execute on function public.leave_absence_report(text, date, date, uuid, uuid, text, integer, integer) to authenticated, service_role;
grant execute on function public.report_filters() to authenticated, service_role;
grant execute on function public.report_export(text, jsonb, text, integer, integer, boolean) to authenticated, service_role;
