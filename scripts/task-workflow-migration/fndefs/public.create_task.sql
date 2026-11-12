CREATE OR REPLACE FUNCTION public.create_task(p_title text, p_description text, p_project uuid, p_assignee uuid, p_priority text DEFAULT 'medium'::text, p_due timestamp with time zone DEFAULT NULL::timestamp with time zone, p_approval boolean DEFAULT NULL::boolean, p_reviewer uuid DEFAULT NULL::uuid, p_parent uuid DEFAULT NULL::uuid, p_required boolean DEFAULT false)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_workspace uuid := app.current_workspace();
  v_assignee uuid := coalesce(p_assignee, auth.uid());
  v_workflow uuid;
  v_status uuid;
  v_approval boolean;
  v_id uuid;
  v_parent_project uuid;
begin
  perform app.require_active();
  if p_priority not in ('low', 'medium', 'high', 'critical') then
    raise exception 'invalid_priority';
  end if;

  if p_project is null then
    if v_assignee = auth.uid() then
      perform app.require_permission('tasks.create.personal');
    elsif not (
      app.is_team_approver(app.primary_team(v_assignee), auth.uid())
      or app.has_permission('tasks.view.all')
    ) then
      raise exception 'forbidden';
    end if;
    select id into v_workflow from public.workflows
    where workspace_id = v_workspace and project_id is null;
    v_approval := coalesce(p_approval, false);
  else
    perform app.require_permission('tasks.create.project');
    if not (
      app.has_permission('projects.view.all')
      or exists (
        select 1 from public.project_members
        where project_id = p_project and profile_id = auth.uid() and removed_at is null
          and member_role = 'manager'
      )
    ) then
      raise exception 'forbidden';
    end if;
    select id into v_workflow from public.workflows where project_id = p_project;
    select approval_required into v_approval from public.projects where id = p_project;
    if p_approval is not null and (
      app.has_permission('projects.view.all')
      or exists (
        select 1 from public.project_members
        where project_id = p_project and profile_id = auth.uid() and removed_at is null
          and member_role = 'manager'
      )
    ) then
      v_approval := p_approval;
    end if;
  end if;

  if p_parent is not null then
    select project_id into v_parent_project from public.tasks where id = p_parent;
    if v_parent_project is distinct from p_project then
      raise exception 'parent_project_mismatch';
    end if;
    if exists (
      select 1 from public.tasks where id = p_parent and parent_task_id is not null
    ) then
      raise exception 'nesting_limit';
    end if;
  end if;

  select id into v_status from public.workflow_statuses
  where workflow_id = v_workflow and key = 'backlog';
  if v_status is null then
    raise exception 'workflow_missing';
  end if;

  insert into public.tasks (
    workspace_id, project_id, parent_task_id, title, description,
    primary_assignee_id, reviewer_id, status_id, priority, due_at,
    approval_required, approval_state, is_required, created_by
  ) values (
    v_workspace, p_project, p_parent, trim(p_title), coalesce(p_description, ''),
    v_assignee, p_reviewer,
    v_status, p_priority, p_due,
    v_approval, case when v_approval then 'pending' else 'not_required' end,
    p_parent is not null and p_required, auth.uid()
  ) returning id into v_id;

  insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)
  values (v_workspace, v_id, auth.uid(), 'task.create', jsonb_build_object('assignee', v_assignee));
  if p_parent is not null then
    insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)
    values (v_workspace, p_parent, auth.uid(), 'task.subtask', jsonb_build_object('child', v_id));
  end if;
  perform app.audit(v_workspace, auth.uid(), 'task.create', 'task', v_id, '{}'::jsonb);
  if v_assignee <> auth.uid() then
    perform app.notify(v_workspace, v_assignee, 'task', 'تسک جدید', 'یک تسک به شما سپرده شد.', 'task', v_id);
  end if;
  return v_id;
end;
$function$
;
