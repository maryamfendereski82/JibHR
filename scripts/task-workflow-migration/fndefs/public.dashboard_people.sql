CREATE OR REPLACE FUNCTION public.dashboard_people(p_search text DEFAULT ''::text, p_team uuid DEFAULT NULL::uuid, p_sort text DEFAULT 'name'::text, p_desc boolean DEFAULT false, p_offset integer DEFAULT 0, p_limit integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_me uuid := auth.uid();
  v_today date := app.tehran_today();
  v_month_start date;
  v_month_end date;
  v_search text;
  v_sort text := case
    when p_sort in (
      'name', 'position', 'approved_seconds', 'pending_seconds',
      'active_tasks', 'complete_tasks', 'review_tasks', 'open_corrections'
    ) then p_sort
    else 'name'
  end;
  v_desc boolean := coalesce(p_desc, false);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_limit integer := least(greatest(coalesce(p_limit, 30), 1), 100);
  v_rows jsonb;
  v_total integer;
begin
  perform app.require_active();
  if p_team is not null and not (
    app.has_permission('employees.view.all')
    or app.has_permission('attendance.view.all')
    or app.is_team_approver(p_team, v_me)
  ) then
    raise exception 'forbidden';
  end if;
  select b.start_date, b.end_date into v_month_start, v_month_end
  from app.gregorian_to_jalali(v_today) j
  join lateral app.jalali_month_bounds(j.jy, j.jm) b on true;
  v_search := replace(replace(replace(coalesce(p_search, ''), '\', '\\'), '%', '\%'), '_', '\_');

  -- shortcut: name search uses a leading wildcard; add pg_trgm if this page gets slow.
  with listed as (
    select jsonb_build_object(
      'id', p.id,
      'name', trim(concat(p.first_name, ' ', p.last_name)),
      'position', coalesce(pos.title, ''),
      'approved_seconds', coalesce(att.approved_seconds, 0),
      'pending_seconds', coalesce(att.pending_seconds, 0),
      'active_tasks', coalesce(tk.active_tasks, 0),
      'complete_tasks', coalesce(tk.complete_tasks, 0),
      'review_tasks', coalesce(tk.review_tasks, 0),
      'open_corrections', coalesce(cor.total, 0)
    ) as person
    from public.profiles p
    left join public.job_positions pos on pos.id = p.job_position_id
    left join lateral (
      select
        coalesce(sum(extract(epoch from (s.ended_at - s.started_at))) filter (
          where s.approval_mode = 'correction' or ri.decision = 'approved'
        ), 0)::bigint as approved_seconds,
        coalesce(sum(extract(epoch from (s.ended_at - s.started_at))) filter (
          where s.approval_mode = 'report' and coalesce(ri.decision, 'pending') = 'pending'
        ), 0)::bigint as pending_seconds
      from public.attendance_daily_segments s
      join public.attendance_intervals i on i.id = s.interval_id
      left join public.attendance_report_items ri on ri.segment_id = s.id
      where s.profile_id = p.id
        and app.can_view_attendance(p.id)
        and s.tehran_date between v_month_start and v_month_end
        and s.superseded_at is null
        and i.status <> 'void'
    ) att on true
    left join lateral (
      select
        count(*) filter (where not app.task_counts_complete(t.id))::integer as active_tasks,
        count(*) filter (where app.task_counts_complete(t.id))::integer as complete_tasks,
        count(*) filter (where s.category = 'in_review')::integer as review_tasks
      from public.tasks t
      join public.workflow_statuses s on s.id = t.status_id
      where t.primary_assignee_id = p.id and t.archived_at is null and app.can_view_task(t.id)
    ) tk on true
    left join lateral (
      select count(*)::integer as total
      from public.attendance_corrections c
      where c.profile_id = p.id and c.status = 'pending' and app.can_view_attendance(c.profile_id)
    ) cor on true
    where p.id <> v_me and p.status = 'active' and app.can_view_employee(p.id)
      and (v_search = '' or trim(concat(p.first_name, ' ', p.last_name)) ilike '%' || v_search || '%' escape '\')
      and (
        p_team is null
        or exists (
          select 1 from public.team_memberships m
          where m.profile_id = p.id and m.team_id = p_team and m.is_primary and m.left_at is null
        )
      )
  )
  select count(*)::integer,
    coalesce((
      select jsonb_agg(ordered.person order by ordered.ord)
      from (
        select person, row_number() over () as ord
        from (
          select person from listed
          order by
            case when v_sort = 'name' and not v_desc then person->>'name' end asc,
            case when v_sort = 'name' and v_desc then person->>'name' end desc,
            case when v_sort = 'position' and not v_desc then person->>'position' end asc,
            case when v_sort = 'position' and v_desc then person->>'position' end desc,
            case when v_sort = 'approved_seconds' and not v_desc then (person->>'approved_seconds')::bigint end asc,
            case when v_sort = 'approved_seconds' and v_desc then (person->>'approved_seconds')::bigint end desc,
            case when v_sort = 'pending_seconds' and not v_desc then (person->>'pending_seconds')::bigint end asc,
            case when v_sort = 'pending_seconds' and v_desc then (person->>'pending_seconds')::bigint end desc,
            case when v_sort = 'active_tasks' and not v_desc then (person->>'active_tasks')::bigint end asc,
            case when v_sort = 'active_tasks' and v_desc then (person->>'active_tasks')::bigint end desc,
            case when v_sort = 'complete_tasks' and not v_desc then (person->>'complete_tasks')::bigint end asc,
            case when v_sort = 'complete_tasks' and v_desc then (person->>'complete_tasks')::bigint end desc,
            case when v_sort = 'review_tasks' and not v_desc then (person->>'review_tasks')::bigint end asc,
            case when v_sort = 'review_tasks' and v_desc then (person->>'review_tasks')::bigint end desc,
            case when v_sort = 'open_corrections' and not v_desc then (person->>'open_corrections')::bigint end asc,
            case when v_sort = 'open_corrections' and v_desc then (person->>'open_corrections')::bigint end desc,
            person->>'id'
          offset v_offset limit v_limit
        ) page
      ) ordered
    ), '[]'::jsonb)
  into v_total, v_rows
  from listed;

  return jsonb_build_object('total', coalesce(v_total, 0), 'rows', coalesce(v_rows, '[]'::jsonb));
end;
$function$
;
