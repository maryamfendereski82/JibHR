-- Edits the existing project and task model. Depth stays one subtask level.
-- Leaving Rejected is a manager action. Approval is still a separate decision.

alter table public.workflow_statuses
  add column is_active boolean not null default true;

alter table public.tasks
  add column priority_rank smallint generated always as (
    case priority
      when 'low' then 1
      when 'medium' then 2
      when 'high' then 3
      when 'critical' then 4
      else 0
    end
  ) stored;

create index tasks_due_open_idx
  on public.tasks (due_at)
  where archived_at is null and due_at is not null;

create index tasks_priority_open_idx
  on public.tasks (priority_rank, updated_at desc)
  where archived_at is null;

create or replace function app.can_edit_project(p_project uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select app.is_active()
    and app.has_permission('projects.edit')
    and (
      app.has_permission('projects.view.all')
      or exists (
        select 1 from public.project_members
        where project_id = p_project
          and profile_id = auth.uid()
          and removed_at is null
          and member_role = 'manager'
      )
    );
$$;

revoke all on function app.can_edit_project(uuid) from public, anon, authenticated;

create or replace function public.create_project(p_name text, p_description text default '')
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_workspace uuid := app.current_workspace();
  v_label text;
begin
  perform app.require_permission('projects.create');
  insert into public.projects (workspace_id, name, description, created_by)
  values (v_workspace, trim(p_name), coalesce(p_description, ''), auth.uid())
  returning id into v_id;
  insert into public.project_members (project_id, profile_id, member_role)
  values (v_id, auth.uid(), 'manager');
  perform app.seed_workflow(v_workspace, v_id);
  foreach v_label in array array['باگ', 'قابلیت', 'طراحی', 'پژوهش', 'بک‌اند', 'فرانت‌اند'] loop
    insert into public.labels (workspace_id, project_id, name)
    values (v_workspace, v_id, v_label);
  end loop;
  perform app.audit(v_workspace, auth.uid(), 'project.create', 'project', v_id, jsonb_build_object('name', trim(p_name)));
  return v_id;
end;
$$;

create or replace function public.update_project(
  p_project uuid,
  p_name text,
  p_description text,
  p_approval boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.require_active();
  if not app.can_edit_project(p_project) then
    raise exception 'forbidden';
  end if;
  if char_length(trim(coalesce(p_name, ''))) = 0 then
    raise exception 'invalid_name';
  end if;
  update public.projects
    set name = trim(p_name),
        description = coalesce(p_description, ''),
        approval_required = p_approval
  where id = p_project and workspace_id = app.current_workspace();
  if not found then
    raise exception 'not_found';
  end if;
  perform app.audit(app.current_workspace(), auth.uid(), 'project.update', 'project', p_project, jsonb_build_object('approval', p_approval));
end;
$$;

create or replace function public.remove_project_member(p_project uuid, p_profile uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role text;
  v_managers integer;
begin
  perform app.require_active();
  if not app.can_edit_project(p_project) then
    raise exception 'forbidden';
  end if;
  select member_role into v_role
  from public.project_members
  where project_id = p_project and profile_id = p_profile and removed_at is null;
  if v_role is null then
    raise exception 'not_found';
  end if;
  if v_role = 'manager' then
    select count(*) into v_managers
    from public.project_members
    where project_id = p_project and member_role = 'manager' and removed_at is null;
    if v_managers <= 1 then
      raise exception 'last_manager';
    end if;
  end if;
  update public.project_members
    set removed_at = clock_timestamp()
  where project_id = p_project and profile_id = p_profile and removed_at is null;
  perform app.audit(app.current_workspace(), auth.uid(), 'project.member_remove', 'project', p_project, jsonb_build_object('profile_id', p_profile));
end;
$$;

create or replace function public.save_label(
  p_project uuid,
  p_label uuid,
  p_name text,
  p_active boolean
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid := p_label;
begin
  perform app.require_active();
  if not app.can_edit_project(p_project) then
    raise exception 'forbidden';
  end if;
  if char_length(trim(coalesce(p_name, ''))) = 0 then
    raise exception 'invalid_name';
  end if;
  if p_label is null then
    insert into public.labels (workspace_id, project_id, name, is_active)
    values (app.current_workspace(), p_project, trim(p_name), p_active)
    returning id into v_id;
  else
    update public.labels
      set name = trim(p_name), is_active = p_active
    where id = p_label and project_id = p_project;
    if not found then
      raise exception 'not_found';
    end if;
  end if;
  return v_id;
end;
$$;

create or replace function public.save_workflow_status(
  p_workflow uuid,
  p_status uuid,
  p_name text,
  p_category text,
  p_position integer,
  p_requires_authority boolean,
  p_active boolean
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_project uuid;
  v_id uuid := p_status;
  v_key text;
begin
  perform app.require_active();
  select project_id into v_project from public.workflows where id = p_workflow;
  if not found then
    raise exception 'not_found';
  end if;
  if v_project is null then
    if not app.has_permission('tasks.view.all') then
      raise exception 'forbidden';
    end if;
  elsif not app.can_edit_project(v_project) then
    raise exception 'forbidden';
  end if;
  if p_category not in (
    'backlog', 'todo', 'in_progress', 'in_review', 'approved', 'done',
    'blocked', 'changes_requested', 'rejected'
  ) then
    raise exception 'invalid_status';
  end if;
  if char_length(trim(coalesce(p_name, ''))) = 0 then
    raise exception 'invalid_name';
  end if;
  if p_status is not null and not p_active then
    select key into v_key from public.workflow_statuses where id = p_status and workflow_id = p_workflow;
    if v_key = 'backlog' then
      raise exception 'status_required';
    end if;
    if exists (select 1 from public.tasks where status_id = p_status and archived_at is null) then
      raise exception 'status_in_use';
    end if;
  end if;
  if p_status is null then
    insert into public.workflow_statuses (workflow_id, key, name, category, position, requires_authority, is_active)
    values (
      p_workflow,
      'custom_' || replace(gen_random_uuid()::text, '-', ''),
      trim(p_name),
      p_category,
      coalesce(p_position, (select coalesce(max(position), 0) + 1 from public.workflow_statuses where workflow_id = p_workflow)),
      p_requires_authority,
      p_active
    )
    returning id into v_id;
  else
    update public.workflow_statuses
      set name = trim(p_name),
          category = p_category,
          position = p_position,
          requires_authority = p_requires_authority,
          is_active = p_active
    where id = p_status and workflow_id = p_workflow;
    if not found then
      raise exception 'not_found';
    end if;
  end if;
  return v_id;
end;
$$;

create or replace function public.set_workflow_transition(p_from uuid, p_to uuid, p_allow boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_workflow uuid;
  v_other uuid;
  v_project uuid;
begin
  perform app.require_active();
  select workflow_id into v_workflow from public.workflow_statuses where id = p_from;
  select workflow_id into v_other from public.workflow_statuses where id = p_to;
  if v_workflow is null or v_workflow is distinct from v_other or p_from = p_to then
    raise exception 'transition_denied';
  end if;
  select project_id into v_project from public.workflows where id = v_workflow;
  if v_project is null then
    if not app.has_permission('tasks.view.all') then
      raise exception 'forbidden';
    end if;
  elsif not app.can_edit_project(v_project) then
    raise exception 'forbidden';
  end if;
  if p_allow then
    insert into public.workflow_transitions (workflow_id, from_status_id, to_status_id)
    values (v_workflow, p_from, p_to)
    on conflict (from_status_id, to_status_id) do nothing;
  else
    delete from public.workflow_transitions
    where from_status_id = p_from and to_status_id = p_to;
  end if;
end;
$$;

create or replace function public.create_task(
  p_title text,
  p_description text,
  p_project uuid,
  p_assignee uuid,
  p_priority text default 'medium',
  p_due timestamptz default null,
  p_approval boolean default null,
  p_reviewer uuid default null,
  p_parent uuid default null,
  p_required boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
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
    perform app.notify(v_workspace, v_assignee, 'task', 'تسک جدید', trim(p_title), 'task', v_id);
  end if;
  return v_id;
end;
$$;

create or replace function public.update_task(
  p_task uuid,
  p_title text,
  p_description text,
  p_assignee uuid,
  p_reviewer uuid,
  p_priority text,
  p_due timestamptz,
  p_approval boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
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
$$;

create or replace function public.remove_task_collaborator(p_task uuid, p_profile uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
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
$$;

create or replace function public.set_task_labels(p_task uuid, p_labels uuid[])
returns void
language plpgsql
security definer
set search_path = ''
as $$
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
$$;

create or replace function public.transition_task(
  p_task uuid,
  p_status uuid,
  p_override_reason text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_task public.tasks%rowtype;
  v_from uuid;
  v_category text;
  v_current text;
  v_authority boolean;
  v_active boolean;
  v_round integer;
begin
  perform app.require_active();
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

  select category into v_current from public.workflow_statuses where id = v_task.status_id;
  if v_current = 'rejected'
     and not (app.has_permission('tasks.manage.project') or app.has_permission('tasks.view.all'))
  then
    raise exception 'rejected_closed';
  end if;

  v_from := v_task.status_id;
  if not exists (
    select 1 from public.workflow_transitions
    where from_status_id = v_from and to_status_id = p_status
  ) then
    raise exception 'transition_denied';
  end if;

  select category, requires_authority, is_active into v_category, v_authority, v_active
  from public.workflow_statuses where id = p_status;
  if not coalesce(v_active, false) then
    raise exception 'status_inactive';
  end if;

  if v_authority
     and v_task.approval_required
     and v_task.approval_state <> 'approved'
     and v_category in ('approved', 'done', 'changes_requested', 'rejected')
  then
    raise exception 'approval_required';
  end if;

  if v_category = 'done' and app.task_children_block_done(p_task) then
    if p_override_reason is null or char_length(trim(p_override_reason)) = 0 then
      raise exception 'subtasks_incomplete';
    end if;
    if not (app.has_permission('tasks.manage.project') or app.has_permission('tasks.view.all')) then
      raise exception 'forbidden';
    end if;
    perform app.audit(v_task.workspace_id, auth.uid(), 'task.override_subtasks', 'task', p_task, jsonb_build_object('reason', trim(p_override_reason)));
    insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)
    values (v_task.workspace_id, p_task, auth.uid(), 'task.override', jsonb_build_object('reason', trim(p_override_reason)));
  end if;

  update public.tasks set status_id = p_status where id = p_task;

  if v_category = 'in_review' and v_task.approval_required then
    select coalesce(max(round_number), 0) + 1 into v_round
    from public.task_review_rounds where task_id = p_task;
    if not exists (
      select 1
      from public.task_review_rounds round
      where round.task_id = p_task
        and not exists (select 1 from public.task_reviews review where review.round_id = round.id)
    ) then
      insert into public.task_review_rounds (task_id, round_number) values (p_task, v_round);
    end if;
    update public.tasks set approval_state = 'pending' where id = p_task;
  end if;

  insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)
  values (v_task.workspace_id, p_task, auth.uid(), 'task.transition', jsonb_build_object('to', p_status));
  if v_category = 'done' and v_task.parent_task_id is not null then
    insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)
    values (v_task.workspace_id, v_task.parent_task_id, auth.uid(), 'task.subtask_done', jsonb_build_object('child', p_task));
  end if;
  perform app.audit(v_task.workspace_id, auth.uid(), 'task.transition', 'task', p_task, jsonb_build_object('status', p_status));
end;
$$;

create or replace function public.add_checklist_item(p_task uuid, p_title text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
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
$$;

create or replace function public.toggle_checklist_item(p_item uuid, p_done boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
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
$$;

create or replace function public.rename_checklist_item(p_item uuid, p_title text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_task uuid;
begin
  perform app.require_active();
  if char_length(trim(coalesce(p_title, ''))) = 0 then
    raise exception 'invalid_name';
  end if;
  select task_id into v_task from public.task_checklist_items where id = p_item;
  if v_task is null or not app.can_view_task(v_task) then
    raise exception 'forbidden';
  end if;
  update public.task_checklist_items set title = trim(p_title) where id = p_item;
  insert into public.task_activity_events (workspace_id, task_id, actor_id, action)
  select workspace_id, v_task, auth.uid(), 'checklist.edit' from public.tasks where id = v_task;
end;
$$;

create or replace function public.delete_checklist_item(p_item uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
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
$$;

create or replace function public.move_checklist_item(p_item uuid, p_direction integer)
returns void
language plpgsql
security definer
set search_path = ''
as $$
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
$$;

revoke all on function public.update_project(uuid, text, text, boolean) from public, anon;
revoke all on function public.remove_project_member(uuid, uuid) from public, anon;
revoke all on function public.save_label(uuid, uuid, text, boolean) from public, anon;
revoke all on function public.save_workflow_status(uuid, uuid, text, text, integer, boolean, boolean) from public, anon;
revoke all on function public.set_workflow_transition(uuid, uuid, boolean) from public, anon;
revoke all on function public.update_task(uuid, text, text, uuid, uuid, text, timestamptz, boolean) from public, anon;
revoke all on function public.remove_task_collaborator(uuid, uuid) from public, anon;
revoke all on function public.set_task_labels(uuid, uuid[]) from public, anon;
revoke all on function public.rename_checklist_item(uuid, text) from public, anon;
revoke all on function public.delete_checklist_item(uuid) from public, anon;
revoke all on function public.move_checklist_item(uuid, integer) from public, anon;

grant execute on function public.update_project(uuid, text, text, boolean) to authenticated, service_role;
grant execute on function public.remove_project_member(uuid, uuid) to authenticated, service_role;
grant execute on function public.save_label(uuid, uuid, text, boolean) to authenticated, service_role;
grant execute on function public.save_workflow_status(uuid, uuid, text, text, integer, boolean, boolean) to authenticated, service_role;
grant execute on function public.set_workflow_transition(uuid, uuid, boolean) to authenticated, service_role;
grant execute on function public.update_task(uuid, text, text, uuid, uuid, text, timestamptz, boolean) to authenticated, service_role;
grant execute on function public.remove_task_collaborator(uuid, uuid) to authenticated, service_role;
grant execute on function public.set_task_labels(uuid, uuid[]) to authenticated, service_role;
grant execute on function public.rename_checklist_item(uuid, text) to authenticated, service_role;
grant execute on function public.delete_checklist_item(uuid) to authenticated, service_role;
grant execute on function public.move_checklist_item(uuid, integer) to authenticated, service_role;
