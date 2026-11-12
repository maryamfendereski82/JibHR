CREATE OR REPLACE FUNCTION public.set_milestone_status(p_milestone uuid, p_status text, p_reason text DEFAULT ''::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v public.milestones%rowtype;
  v_open integer;
begin
  if p_status not in ('upcoming', 'in_progress', 'reached', 'cancelled') then
    raise exception 'invalid_status';
  end if;
  select * into v from public.milestones where id = p_milestone for update;
  if v.id is null then
    raise exception 'forbidden';
  end if;
  perform app.require_plan_manager(v.project_id);
  if p_status = 'reached' then
    select count(*)::integer into v_open
    from public.milestone_tasks mt
    join public.tasks t on t.id = mt.task_id
    where mt.milestone_id = v.id
      and t.archived_at is null
      and not app.task_counts_complete(t.id);
    if v_open > 0 and char_length(trim(coalesce(p_reason, ''))) = 0 then
      raise exception 'tasks_incomplete';
    end if;
    if v_open > 0 then
      perform app.audit(
        v.workspace_id, auth.uid(), 'milestone.override', 'milestone', v.id,
        jsonb_build_object('reason', trim(p_reason), 'open_tasks', v_open)
      );
    end if;
  end if;
  update public.milestones set status = p_status where id = v.id;
  perform app.audit(
    v.workspace_id, auth.uid(), 'milestone.status', 'milestone', v.id,
    jsonb_build_object('status', p_status)
  );
end;
$function$
;
