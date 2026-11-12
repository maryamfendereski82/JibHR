CREATE OR REPLACE FUNCTION public.dashboard_personal()
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
$function$
;
