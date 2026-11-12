CREATE OR REPLACE FUNCTION public.transfer_sprint_remainder(p_from uuid, p_to uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_from public.sprints%rowtype;
  v_to public.sprints%rowtype;
  v_task uuid;
  v_count integer := 0;
begin
  if p_from = p_to then
    raise exception 'invalid_status';
  end if;
  select * into v_from from public.sprints where id = p_from;
  select * into v_to from public.sprints where id = p_to;
  if v_from.id is null or v_to.id is null then
    raise exception 'forbidden';
  end if;
  perform app.require_plan_manager(v_from.project_id);
  if v_from.project_id <> v_to.project_id then
    raise exception 'project_mismatch';
  end if;
  if v_to.status not in ('planned', 'active') then
    raise exception 'invalid_status';
  end if;
  perform 1 from public.projects where id = v_from.project_id for update;
  for v_task in
    select t.id
    from public.sprint_tasks link
    join public.tasks t on t.id = link.task_id
    where link.sprint_id = v_from.id
      and link.removed_at is null
      and t.archived_at is null
      and not app.task_counts_complete(t.id)
  loop
    perform public.move_task_to_sprint(v_task, v_to.id);
    v_count := v_count + 1;
  end loop;
  perform app.audit(
    v_from.workspace_id, auth.uid(), 'sprint.transfer', 'sprint', v_from.id,
    jsonb_build_object('to', v_to.id, 'count', v_count)
  );
  return v_count;
end;
$function$
;
