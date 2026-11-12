CREATE OR REPLACE FUNCTION public.project_sprint_counts(p_project uuid)
 RETURNS TABLE(sprint_id uuid, total integer, complete integer, blocked integer)
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
    s.id,
    count(t.id)::integer,
    count(t.id) filter (where app.task_counts_complete(t.id))::integer,
    count(t.id) filter (
      where st.category = 'blocked' and not app.task_counts_complete(t.id)
    )::integer
  from public.sprints s
  left join public.sprint_tasks link
    on link.sprint_id = s.id and link.removed_at is null
  left join public.tasks t
    on t.id = link.task_id
    and t.archived_at is null
    and app.can_view_task(t.id)
  left join public.workflow_statuses st on st.id = t.status_id
  where s.project_id = p_project
  group by s.id;
end;
$function$
;
