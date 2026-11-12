CREATE OR REPLACE FUNCTION public.set_sprint_status(p_sprint uuid, p_status text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_project uuid;
  v public.sprints%rowtype;
  v_total integer;
  v_complete integer;
  v_blocked integer;
begin
  if p_status not in ('planned', 'active', 'closed', 'cancelled') then
    raise exception 'invalid_status';
  end if;
  select project_id into v_project from public.sprints where id = p_sprint;
  if v_project is null then
    raise exception 'forbidden';
  end if;
  perform app.require_plan_manager(v_project);
  perform 1 from public.projects where id = v_project for update;
  select * into v from public.sprints where id = p_sprint for update;
  if v.status = p_status then
    return;
  end if;
  if v.status = 'planned' and p_status not in ('active', 'cancelled') then
    raise exception 'invalid_status';
  end if;
  if v.status = 'active' and p_status not in ('closed', 'cancelled') then
    raise exception 'invalid_status';
  end if;
  if v.status in ('closed', 'cancelled') then
    raise exception 'invalid_status';
  end if;
  if p_status = 'active' and exists (
    select 1 from public.sprints
    where project_id = v.project_id and status = 'active' and id <> v.id
  ) then
    raise exception 'already_active';
  end if;
  if p_status = 'closed' and v.summary is null then
    select
      count(t.id)::integer,
      count(t.id) filter (where app.task_counts_complete(t.id))::integer,
      count(t.id) filter (
        where st.category = 'blocked' and not app.task_counts_complete(t.id)
      )::integer
    into v_total, v_complete, v_blocked
    from public.sprint_tasks link
    join public.tasks t on t.id = link.task_id and t.archived_at is null
    join public.workflow_statuses st on st.id = t.status_id
    where link.sprint_id = v.id and link.removed_at is null;
    update public.sprints
      set status = 'closed',
          summary = jsonb_build_object(
            'total', v_total,
            'complete', v_complete,
            'blocked', v_blocked,
            'remaining', v_total - v_complete,
            'percent', case when v_total = 0 then 0 else v_complete * 100 / v_total end
          )
    where id = v.id;
  else
    update public.sprints set status = p_status where id = v.id;
  end if;
  perform app.audit(
    v.workspace_id, auth.uid(), 'sprint.status', 'sprint', v.id,
    jsonb_build_object('status', p_status)
  );
exception
  when unique_violation then
    raise exception 'already_active';
end;
$function$
;
