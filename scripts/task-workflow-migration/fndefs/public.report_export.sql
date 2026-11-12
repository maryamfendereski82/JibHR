CREATE OR REPLACE FUNCTION public.report_export(p_kind text, p_filters jsonb DEFAULT '{}'::jsonb, p_format text DEFAULT 'excel'::text, p_offset integer DEFAULT 0, p_limit integer DEFAULT 200, p_audit boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_temp'
AS $function$
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
$function$
;
