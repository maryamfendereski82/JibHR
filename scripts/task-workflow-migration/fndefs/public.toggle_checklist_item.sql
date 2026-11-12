CREATE OR REPLACE FUNCTION public.toggle_checklist_item(p_item uuid, p_done boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_task uuid;
begin
  perform app.require_active();
  select task_id into v_task from public.task_checklist_items where id = p_item;
  if v_task is null or not app.can_view_task(v_task) then
    raise exception 'forbidden';
  end if;
  update public.task_checklist_items set is_done = p_done where id = p_item;
  insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)
  select workspace_id, v_task, auth.uid(), 'checklist.toggle', jsonb_build_object('done', p_done)
  from public.tasks where id = v_task;
end;
$function$
;
