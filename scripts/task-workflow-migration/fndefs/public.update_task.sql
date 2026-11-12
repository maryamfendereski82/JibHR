CREATE OR REPLACE FUNCTION public.update_task(p_task uuid, p_title text, p_description text, p_assignee uuid, p_reviewer uuid, p_priority text, p_due timestamp with time zone, p_approval boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_task public.tasks%rowtype;
  v_state text;
begin
  perform app.require_active();
  if p_priority not in ('low', 'medium', 'high', 'critical') then
    raise exception 'invalid_priority';
  end if;
  if char_length(trim(coalesce(p_title, ''))) = 0 then
    raise exception 'invalid_name';
  end if;
  select * into v_task from public.tasks where id = p_task for update;
  if not found or not app.can_view_task(p_task) then
    raise exception 'forbidden';
  end if;
  if v_task.primary_assignee_id <> auth.uid()
     and not app.has_permission('tasks.manage.project')
     and not app.is_team_approver(app.primary_team(v_task.primary_assignee_id), auth.uid())
  then
    raise exception 'forbidden';
  end if;

  v_state := v_task.approval_state;
  if p_approval and not v_task.approval_required then
    v_state := case when v_task.approval_state = 'approved' then 'approved' else 'pending' end;
  elsif not p_approval and v_task.approval_required and v_task.approval_state = 'pending' then
    v_state := 'not_required';
  end if;

  if v_task.title is distinct from trim(p_title) or v_task.description is distinct from coalesce(p_description, '') then
    insert into public.task_activity_events (workspace_id, task_id, actor_id, action)
    values (v_task.workspace_id, p_task, auth.uid(), 'task.update');
  end if;
  if v_task.primary_assignee_id is distinct from p_assignee then
    insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)
    values (v_task.workspace_id, p_task, auth.uid(), 'task.assign', jsonb_build_object('assignee', p_assignee));
    if p_assignee is distinct from auth.uid() then
      perform app.notify(v_task.workspace_id, p_assignee, 'task', 'مسئول تسک عوض شد', 'مسئولیت یک تسک به شما سپرده شد.', 'task', p_task);
    end if;
  end if;
  if v_task.priority is distinct from p_priority then
    insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)
    values (v_task.workspace_id, p_task, auth.uid(), 'task.priority', jsonb_build_object('priority', p_priority));
  end if;
  if v_task.due_at is distinct from p_due then
    insert into public.task_activity_events (workspace_id, task_id, actor_id, action)
    values (v_task.workspace_id, p_task, auth.uid(), 'task.due');
  end if;
  if v_task.reviewer_id is distinct from p_reviewer or v_task.approval_required is distinct from p_approval then
    insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)
    values (v_task.workspace_id, p_task, auth.uid(), 'task.approval', jsonb_build_object('required', p_approval));
  end if;

  update public.tasks
    set title = trim(p_title),
        description = coalesce(p_description, ''),
        primary_assignee_id = p_assignee,
        reviewer_id = p_reviewer,
        priority = p_priority,
        due_at = p_due,
        approval_required = p_approval,
        approval_state = v_state
  where id = p_task;
end;
$function$
;
