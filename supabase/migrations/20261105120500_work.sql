-- Project and task writes. Approval is a separate decision from dragging a card:
-- a status flagged requires_authority cannot be entered just to skip a reviewer.

create or replace function app.seed_workflow(p_workspace uuid, p_project uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_workflow uuid;
  v_name text := case when p_project is null then 'شخصی' else 'پیش‌فرض' end;
  v_backlog uuid;
  v_todo uuid;
  v_progress uuid;
  v_review uuid;
  v_approved uuid;
  v_done uuid;
  v_blocked uuid;
  v_changes uuid;
  v_rejected uuid;
begin
  insert into public.workflows (workspace_id, project_id, name)
  values (p_workspace, p_project, v_name)
  returning id into v_workflow;

  insert into public.workflow_statuses (workflow_id, key, name, category, position, requires_authority)
  values
    (v_workflow, 'backlog', 'بک‌لاگ', 'backlog', 1, false),
    (v_workflow, 'todo', 'انجام‌نشده', 'todo', 2, false),
    (v_workflow, 'in_progress', 'در حال انجام', 'in_progress', 3, false),
    (v_workflow, 'in_review', 'در حال بررسی', 'in_review', 4, false),
    (v_workflow, 'approved', 'تأییدشده', 'approved', 5, true),
    (v_workflow, 'done', 'انجام‌شده', 'done', 6, true),
    (v_workflow, 'blocked', 'مسدود', 'blocked', 7, false),
    (v_workflow, 'changes_requested', 'نیاز به اصلاح', 'changes_requested', 8, true),
    (v_workflow, 'rejected', 'ردشده', 'rejected', 9, true);

  select id into v_backlog from public.workflow_statuses where workflow_id = v_workflow and key = 'backlog';
  select id into v_todo from public.workflow_statuses where workflow_id = v_workflow and key = 'todo';
  select id into v_progress from public.workflow_statuses where workflow_id = v_workflow and key = 'in_progress';
  select id into v_review from public.workflow_statuses where workflow_id = v_workflow and key = 'in_review';
  select id into v_approved from public.workflow_statuses where workflow_id = v_workflow and key = 'approved';
  select id into v_done from public.workflow_statuses where workflow_id = v_workflow and key = 'done';
  select id into v_blocked from public.workflow_statuses where workflow_id = v_workflow and key = 'blocked';
  select id into v_changes from public.workflow_statuses where workflow_id = v_workflow and key = 'changes_requested';
  select id into v_rejected from public.workflow_statuses where workflow_id = v_workflow and key = 'rejected';

  insert into public.workflow_transitions (workflow_id, from_status_id, to_status_id)
  values
    (v_workflow, v_backlog, v_todo),
    (v_workflow, v_todo, v_progress),
    (v_workflow, v_progress, v_review),
    (v_workflow, v_progress, v_blocked),
    (v_workflow, v_blocked, v_progress),
    (v_workflow, v_review, v_approved),
    (v_workflow, v_approved, v_done),
    (v_workflow, v_review, v_changes),
    (v_workflow, v_changes, v_progress),
    (v_workflow, v_review, v_rejected);

  return v_workflow;
end;
$$;

create or replace function app.default_reviewer(p_project uuid, p_assignee uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when p_project is null then (
      select a.profile_id
      from public.team_manager_assignments a
      where a.team_id = app.primary_team(p_assignee)
        and a.revoked_at is null
        and a.kind = 'manager'
      order by a.assigned_at
      limit 1
    )
    else (
      select m.profile_id
      from public.project_members m
      where m.project_id = p_project
        and m.removed_at is null
        and m.member_role = 'manager'
      order by m.added_at
      limit 1
    )
  end;
$$;

create or replace function public.create_project(p_name text, p_description text default '')
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_workspace uuid := app.current_workspace();
begin
  perform app.require_permission('projects.create');
  insert into public.projects (workspace_id, name, description, created_by)
  values (v_workspace, trim(p_name), coalesce(p_description, ''), auth.uid())
  returning id into v_id;
  insert into public.project_members (project_id, profile_id, member_role)
  values (v_id, auth.uid(), 'manager');
  perform app.seed_workflow(v_workspace, v_id);
  perform app.audit(v_workspace, auth.uid(), 'project.create', 'project', v_id, jsonb_build_object('name', trim(p_name)));
  return v_id;
end;
$$;

create or replace function public.set_project_visibility(p_project uuid, p_visibility text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.require_permission('projects.edit');
  if p_visibility not in ('project_wide', 'restricted') then
    raise exception 'invalid_visibility';
  end if;
  if not app.can_view_project(p_project) then
    raise exception 'forbidden';
  end if;
  update public.projects
    set visibility = p_visibility
  where id = p_project and workspace_id = app.current_workspace();
  perform app.audit(app.current_workspace(), auth.uid(), 'project.visibility', 'project', p_project, jsonb_build_object('visibility', p_visibility));
end;
$$;

create or replace function public.archive_project(p_project uuid, p_archived boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.require_permission('projects.archive');
  update public.projects
    set status = case when p_archived then 'archived' else 'active' end,
        archived_at = case when p_archived then clock_timestamp() else null end
  where id = p_project and workspace_id = app.current_workspace();
  if not found then
    raise exception 'not_found';
  end if;
  perform app.audit(app.current_workspace(), auth.uid(), 'project.archive', 'project', p_project, jsonb_build_object('archived', p_archived));
end;
$$;

create or replace function public.add_project_member(p_project uuid, p_profile uuid, p_role text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.require_permission('projects.edit');
  if p_role not in ('manager', 'reviewer', 'member') then
    raise exception 'invalid_role';
  end if;
  if not exists (
    select 1 from public.project_members
    where project_id = p_project and profile_id = p_profile and removed_at is null
  ) then
    insert into public.project_members (project_id, profile_id, member_role)
    values (p_project, p_profile, p_role);
  else
    update public.project_members
      set member_role = p_role
    where project_id = p_project and profile_id = p_profile and removed_at is null;
  end if;
  perform app.audit(app.current_workspace(), auth.uid(), 'project.member', 'project', p_project, jsonb_build_object('profile_id', p_profile, 'role', p_role));
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
  perform app.audit(v_workspace, auth.uid(), 'task.create', 'task', v_id, '{}'::jsonb);
  if v_assignee <> auth.uid() then
    perform app.notify(v_workspace, v_assignee, 'task', 'تسک جدید', trim(p_title), 'task', v_id);
  end if;
  return v_id;
end;
$$;

create or replace function public.add_task_collaborator(p_task uuid, p_profile uuid)
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
  if v_project is null then
    raise exception 'personal_task';
  end if;
  if not app.can_view_task(p_task) then
    raise exception 'forbidden';
  end if;
  insert into public.task_collaborators (task_id, profile_id)
  values (p_task, p_profile)
  on conflict do nothing;
  insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)
  values (app.current_workspace(), p_task, auth.uid(), 'task.collaborator', jsonb_build_object('profile_id', p_profile));
end;
$$;

create or replace function app.task_children_block_done(p_task uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.tasks child
    join public.workflow_statuses st on st.id = child.status_id
    where child.parent_task_id = p_task
      and child.is_required
      and child.archived_at is null
      and (
        st.category not in ('done', 'approved')
        or (child.approval_required and child.approval_state <> 'approved')
      )
  );
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
  v_authority boolean;
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

  v_from := v_task.status_id;
  if not exists (
    select 1 from public.workflow_transitions
    where from_status_id = v_from and to_status_id = p_status
  ) then
    raise exception 'transition_denied';
  end if;

  select category, requires_authority into v_category, v_authority
  from public.workflow_statuses where id = p_status;

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
  perform app.audit(v_task.workspace_id, auth.uid(), 'task.transition', 'task', p_task, jsonb_build_object('status', p_status));
end;
$$;

create or replace function public.decide_task(
  p_task uuid,
  p_decision text,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_task public.tasks%rowtype;
  v_round uuid;
  v_status uuid;
  v_eligible boolean := false;
begin
  perform app.require_active();
  if p_decision not in ('approved', 'revision_requested', 'rejected') then
    raise exception 'invalid_decision';
  end if;
  if p_decision <> 'approved' and char_length(trim(coalesce(p_reason, ''))) = 0 then
    raise exception 'reason_required';
  end if;

  select * into v_task from public.tasks where id = p_task for update;
  if not found then
    raise exception 'not_found';
  end if;
  if not v_task.approval_required then
    raise exception 'not_required';
  end if;

  if v_task.reviewer_id is not null then
    v_eligible := v_task.reviewer_id = auth.uid() or app.is_super_admin(auth.uid());
  elsif v_task.project_id is null then
    v_eligible := app.is_team_approver(app.primary_team(v_task.primary_assignee_id), auth.uid())
      or app.is_super_admin(auth.uid());
  else
    v_eligible := app.is_super_admin(auth.uid()) or exists (
      select 1 from public.project_members
      where project_id = v_task.project_id
        and profile_id = auth.uid()
        and removed_at is null
        and member_role in ('manager', 'reviewer')
    );
  end if;
  if not v_eligible then
    raise exception 'forbidden';
  end if;

  select id into v_round
  from public.task_review_rounds
  where task_id = p_task
    and not exists (select 1 from public.task_reviews review where review.round_id = task_review_rounds.id)
  order by round_number desc
  limit 1
  for update;
  if v_round is null then
    if exists (
      select 1
      from public.task_reviews review
      join public.task_review_rounds round on round.id = review.round_id
      where round.task_id = p_task
    ) then
      raise exception 'already_decided';
    end if;
    raise exception 'not_submitted';
  end if;

  begin
    insert into public.task_reviews (round_id, reviewer_id, decision, reason)
    values (v_round, auth.uid(), p_decision, nullif(trim(coalesce(p_reason, '')), ''));
  exception
    when unique_violation then
      raise exception 'already_decided';
  end;

  select id into v_status
  from public.workflow_statuses
  where workflow_id = (select workflow_id from public.workflow_statuses where id = v_task.status_id)
    and key = case p_decision
      when 'approved' then 'approved'
      when 'revision_requested' then 'changes_requested'
      else 'rejected'
    end;

  update public.tasks
    set approval_state = case p_decision
          when 'approved' then 'approved'
          when 'revision_requested' then 'changes_requested'
          else 'rejected'
        end,
        status_id = v_status
  where id = p_task;

  insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)
  values (v_task.workspace_id, p_task, auth.uid(), 'task.review', jsonb_build_object('decision', p_decision));
  perform app.notify(
    v_task.workspace_id, v_task.primary_assignee_id, 'task',
    'نتیجه بررسی تسک', v_task.title, 'task', p_task
  );
  perform app.audit(v_task.workspace_id, auth.uid(), 'task.review', 'task', p_task, jsonb_build_object('decision', p_decision));
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
  select coalesce(max(position), 0) + 1 into v_position
  from public.task_checklist_items where task_id = p_task;
  insert into public.task_checklist_items (task_id, title, position)
  values (p_task, trim(p_title), v_position)
  returning id into v_id;
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
end;
$$;

create or replace function public.create_sprint(
  p_project uuid,
  p_name text,
  p_start date,
  p_end date,
  p_description text default ''
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  perform app.require_permission('tasks.manage.project');
  if p_end < p_start then
    raise exception 'invalid_range';
  end if;
  insert into public.sprints (workspace_id, project_id, name, description, start_date, end_date)
  values (app.current_workspace(), p_project, trim(p_name), coalesce(p_description, ''), p_start, p_end)
  returning id into v_id;
  perform app.audit(app.current_workspace(), auth.uid(), 'sprint.create', 'sprint', v_id, '{}'::jsonb);
  return v_id;
end;
$$;

create or replace function public.move_task_to_sprint(p_task uuid, p_sprint uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_project uuid;
  v_previous uuid;
begin
  perform app.require_permission('tasks.manage.project');
  select project_id into v_project from public.sprints where id = p_sprint;
  if not exists (select 1 from public.tasks where id = p_task and project_id = v_project) then
    raise exception 'project_mismatch';
  end if;
  select sprint_id into v_previous from public.sprint_tasks
  where task_id = p_task and removed_at is null;
  if v_previous is not null then
    update public.sprint_tasks set removed_at = clock_timestamp()
    where task_id = p_task and removed_at is null;
  end if;
  insert into public.sprint_tasks (sprint_id, task_id, carried_from_sprint_id)
  values (p_sprint, p_task, v_previous);
end;
$$;

create or replace function public.create_milestone(p_project uuid, p_title text, p_target date, p_description text default '')
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  perform app.require_permission('tasks.manage.project');
  insert into public.milestones (workspace_id, project_id, title, description, target_date)
  values (app.current_workspace(), p_project, trim(p_title), coalesce(p_description, ''), p_target)
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.link_milestone_task(p_milestone uuid, p_task uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.require_permission('tasks.manage.project');
  insert into public.milestone_tasks (milestone_id, task_id)
  values (p_milestone, p_task)
  on conflict do nothing;
end;
$$;

create or replace function public.milestone_progress(p_milestone uuid)
returns table (total integer, complete integer)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_project uuid;
begin
  perform app.require_active();
  select project_id into v_project from public.milestones where id = p_milestone;
  if not app.can_view_project(v_project) then
    raise exception 'forbidden';
  end if;
  return query
  select
    count(*)::integer,
    count(*) filter (
      where st.category in ('done', 'approved')
        and (t.approval_required = false or t.approval_state = 'approved')
    )::integer
  from public.milestone_tasks mt
  join public.tasks t on t.id = mt.task_id
  join public.workflow_statuses st on st.id = t.status_id
  where mt.milestone_id = p_milestone
    and t.archived_at is null
    and (
      app.has_permission('projects.view.all')
      or exists (
        select 1 from public.project_members m
        where m.project_id = v_project and m.profile_id = auth.uid() and m.removed_at is null
          and m.member_role in ('manager', 'reviewer')
      )
      or app.can_view_task(t.id)
    );
end;
$$;
