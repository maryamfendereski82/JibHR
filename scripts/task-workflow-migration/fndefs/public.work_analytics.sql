CREATE OR REPLACE FUNCTION public.work_analytics(p_project uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$
;
