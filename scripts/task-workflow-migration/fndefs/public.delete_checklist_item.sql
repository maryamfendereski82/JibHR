CREATE OR REPLACE FUNCTION public.delete_checklist_item(p_item uuid)
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
  delete from public.task_checklist_items where id = p_item;
  insert into public.task_activity_events (workspace_id, task_id, actor_id, action)
  select workspace_id, v_task, auth.uid(), 'checklist.delete' from public.tasks where id = v_task;
end;
$function$
;
