CREATE OR REPLACE FUNCTION public.set_task_labels(p_task uuid, p_labels uuid[])
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_project uuid;
begin
  perform app.require_active();
  select project_id into v_project from public.tasks where id = p_task;
  if v_project is null or not app.can_view_task(p_task) then
    raise exception 'forbidden';
  end if;
  if exists (
    select 1
    from unnest(coalesce(p_labels, '{}'::uuid[])) as picked(label_id)
    where not exists (
      select 1 from public.labels
      where id = picked.label_id and project_id = v_project and is_active
    )
  ) then
    raise exception 'invalid_label';
  end if;
  delete from public.task_labels
  where task_id = p_task
    and label_id <> all (coalesce(p_labels, '{}'::uuid[]));
  insert into public.task_labels (task_id, label_id)
  select p_task, picked.label_id
  from unnest(coalesce(p_labels, '{}'::uuid[])) as picked(label_id)
  on conflict do nothing;
  insert into public.task_activity_events (workspace_id, task_id, actor_id, action)
  values (app.current_workspace(), p_task, auth.uid(), 'task.labels');
end;
$function$
;
