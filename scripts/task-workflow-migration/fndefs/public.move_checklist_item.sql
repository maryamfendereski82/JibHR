CREATE OR REPLACE FUNCTION public.move_checklist_item(p_item uuid, p_direction integer)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_task uuid;
  v_position integer;
  v_other uuid;
  v_other_position integer;
begin
  perform app.require_active();
  if p_direction not in (-1, 1) then
    raise exception 'invalid_range';
  end if;
  select task_id, position into v_task, v_position
  from public.task_checklist_items where id = p_item for update;
  if v_task is null or not app.can_view_task(v_task) then
    raise exception 'forbidden';
  end if;
  select id, position into v_other, v_other_position
  from public.task_checklist_items
  where task_id = v_task
    and position = (
      select case when p_direction < 0 then max(position) else min(position) end
      from public.task_checklist_items
      where task_id = v_task
        and case when p_direction < 0 then position < v_position else position > v_position end
    )
  for update;
  if v_other is null then
    return;
  end if;
  update public.task_checklist_items set position = v_other_position where id = p_item;
  update public.task_checklist_items set position = v_position where id = v_other;
  insert into public.task_activity_events (workspace_id, task_id, actor_id, action)
  select workspace_id, v_task, auth.uid(), 'checklist.move' from public.tasks where id = v_task;
end;
$function$
;
