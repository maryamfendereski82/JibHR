CREATE OR REPLACE FUNCTION public.add_checklist_item(p_task uuid, p_title text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_id uuid;
  v_position integer;
begin
  perform app.require_active();
  if not app.can_view_task(p_task) then
    raise exception 'forbidden';
  end if;
  if char_length(trim(coalesce(p_title, ''))) = 0 then
    raise exception 'invalid_name';
  end if;
  select coalesce(max(position), 0) + 1 into v_position
  from public.task_checklist_items where task_id = p_task;
  insert into public.task_checklist_items (task_id, title, position)
  values (p_task, trim(p_title), v_position)
  returning id into v_id;
  insert into public.task_activity_events (workspace_id, task_id, actor_id, action)
  select workspace_id, p_task, auth.uid(), 'checklist.add' from public.tasks where id = p_task;
  return v_id;
end;
$function$
;
