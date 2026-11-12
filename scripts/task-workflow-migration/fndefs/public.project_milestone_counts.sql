CREATE OR REPLACE FUNCTION public.project_milestone_counts(p_project uuid)
 RETURNS TABLE(milestone_id uuid, total integer, complete integer, blocked integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform app.require_active();
  if not app.can_view_project(p_project) then
    raise exception 'forbidden';
  end if;
  return query
  select
    m.id,
    count(t.id)::integer,
    count(t.id) filter (where app.task_counts_complete(t.id))::integer,
    count(t.id) filter (
      where st.category = 'blocked' and not app.task_counts_complete(t.id)
    )::integer
  from public.milestones m
  left join public.milestone_tasks link on link.milestone_id = m.id
  left join public.tasks t
    on t.id = link.task_id
    and t.archived_at is null
    and app.can_view_task(t.id)
  left join public.workflow_statuses st on st.id = t.status_id
  where m.project_id = p_project
  group by m.id;
end;
$function$
;
