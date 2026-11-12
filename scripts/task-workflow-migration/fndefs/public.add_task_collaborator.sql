CREATE OR REPLACE FUNCTION public.add_task_collaborator(p_task uuid, p_profile uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_project uuid;
  v_workspace uuid;
  v_inserted integer;
begin
  perform app.require_active();
  select project_id, workspace_id into v_project, v_workspace
  from public.tasks where id = p_task;
  if v_project is null then
    raise exception 'personal_task';
  end if;
  if not app.can_view_task(p_task) then
    raise exception 'forbidden';
  end if;
  insert into public.task_collaborators (task_id, profile_id)
  values (p_task, p_profile)
  on conflict do nothing;
  get diagnostics v_inserted = row_count;
  if v_inserted > 0 and p_profile is distinct from auth.uid() then
    perform app.notify(v_workspace, p_profile, 'task', 'همکار تسک شدید', 'به یک تسک به‌عنوان همکار اضافه شدید.', 'task', p_task);
  end if;
  insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)
  values (app.current_workspace(), p_task, auth.uid(), 'task.collaborator', jsonb_build_object('profile_id', p_profile));
end;
$function$
;
