CREATE OR REPLACE FUNCTION public.remove_task_collaborator(p_task uuid, p_profile uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform app.require_active();
  if not app.can_view_task(p_task) then
    raise exception 'forbidden';
  end if;
  delete from public.task_collaborators
  where task_id = p_task and profile_id = p_profile;
  insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)
  values (app.current_workspace(), p_task, auth.uid(), 'task.collaborator_remove', jsonb_build_object('profile_id', p_profile));
end;
$function$
;
