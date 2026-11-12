-- =============================================================================
-- DRAFT — DO NOT APPLY. Generated; do not edit by hand (see proposal §16).
-- Rollback of docs/task-workflow-migration-draft.sql. Local Supabase only.
-- Policy (proposal §11.2):
--   * restores, only where nothing changed them after the migration:
--     task statuses, status name / position / is_active, added transitions;
--   * restores the exact pre-migration bodies of every changed function
--     (verbatim below, verified by md5 at the end) and their grants;
--   * NEVER deletes history or data written after the migration: rounds,
--     snapshots, historical names, decisions, revision requests, block events,
--     logs — and keeps their immutability triggers;
--   * reports what it kept or could not restore and records the run.
-- =============================================================================
begin;
set local lock_timeout = '5s';
lock table public.tasks, public.workflow_statuses, public.workflow_transitions,
           public.task_review_rounds, public.task_reviews, public.project_members in share row exclusive mode;

-- -----------------------------------------------------------------------------
-- 1. Task statuses: only rows still where the migration put them
-- -----------------------------------------------------------------------------
-- A task is restored only if it is still exactly as the migration left it:
-- same status, and for a formerly "blocked" task the very flag the migration set
-- (same timestamp, no person, same reason). If a person unblocked or re-blocked
-- it, or moved it, it is kept and reported.
create temporary table rollback_tasks on commit drop as
select l.task_id, l.from_status_id, l.to_status_id, l.blocked_set,
       t.status_id = l.to_status_id
         and (not l.blocked_set
              or (t.blocked_at is not distinct from l.blocked_at_set and t.blocked_by is null
                  and t.blocked_reason = 'انتقال خودکار از وضعیت مسدود')) as restorable,
       case
         when t.status_id <> l.to_status_id then 'moved_after_migration'
         when l.blocked_set and t.blocked_at is null then 'unblocked_by_person'
         when l.blocked_set and (t.blocked_at is distinct from l.blocked_at_set or t.blocked_by is not null) then 'flag_changed_by_person'
       end as kept_reason
from public.workflow_status_migration_log l join public.tasks t on t.id = l.task_id;

update public.tasks t set
  status_id = r.from_status_id,
  blocked_at = case when r.blocked_set then null else t.blocked_at end,
  blocked_reason = case when r.blocked_set then null else t.blocked_reason end
from rollback_tasks r where r.task_id = t.id and r.restorable;

-- Only when the rollback really lifts the migration's own flag.
insert into public.task_block_events (task_id, action, reason, status_id, actor_id, actor_name)
select r.task_id, 'unblocked', 'بازگردانی Migration', r.from_status_id, null, null
from rollback_tasks r where r.restorable and r.blocked_set;

insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)
select t.workspace_id, r.task_id, null, 'task.migrated',
       jsonb_build_object('from', r.to_status_id, 'to', r.from_status_id, 'reason', 'rollback_workflow_d1_d7')
from rollback_tasks r join public.tasks t on t.id = r.task_id where r.restorable;

-- -----------------------------------------------------------------------------
-- 2. Statuses: restore "before" only while the row still equals "after"
-- -----------------------------------------------------------------------------
create temporary table rollback_statuses on commit drop as
select c.status_id, c.before, c.after,
       jsonb_build_object('name', s.name, 'position', s.position, 'is_active', s.is_active) = c.after as restorable
from public.workflow_status_changes c join public.workflow_statuses s on s.id = c.status_id;

update public.workflow_statuses s set
  name = r.before ->> 'name',
  position = (r.before ->> 'position')::integer,
  is_active = (r.before ->> 'is_active')::boolean
from rollback_statuses r where r.status_id = s.id and r.restorable;

-- -----------------------------------------------------------------------------
-- 3. Transitions the migration added: removed only while the row still exists
--    with the recorded values; a manager's later change or removal is kept.
-- -----------------------------------------------------------------------------
create temporary table rollback_transitions on commit drop as
select a.transition_id,
       exists (select 1 from public.workflow_transitions x where x.id = a.transition_id and x.workflow_id = a.workflow_id
               and x.from_status_id = a.from_status_id and x.to_status_id = a.to_status_id) as restorable,
       case
         when not exists (select 1 from public.workflow_transitions x where x.id = a.transition_id) then 'removed_after_migration'
         when not exists (select 1 from public.workflow_transitions x where x.id = a.transition_id and x.workflow_id = a.workflow_id
                          and x.from_status_id = a.from_status_id and x.to_status_id = a.to_status_id) then 'changed_after_migration'
       end as kept_reason
from public.workflow_migration_added_transitions a;

delete from public.workflow_transitions x using rollback_transitions r where x.id = r.transition_id and r.restorable;

-- -----------------------------------------------------------------------------
-- 4. Triggers. KEPT (history stays tamper-proof; old code only inserts):
--    task_review_rounds_protect, task_review_rounds_no_delete, task_reviews_immutable,
--    task_revision_requests_immutable, task_revision_requests_check,
--    task_block_events_immutable, task_activity_events_immutable and the five
--    *_no_truncate statement triggers. The privilege revokes on history tables
--    (service_role: SELECT only) are kept as well.
--    DROPPED: the B1 constraint trigger — the restored decide_task(uuid, text, text)
--    records revision decisions without a structured request.
-- -----------------------------------------------------------------------------
drop trigger task_reviews_revision_request on public.task_reviews;

-- -----------------------------------------------------------------------------
-- 5. New RPCs
-- -----------------------------------------------------------------------------
drop function public.project_member_directory(uuid);
drop function public.project_member_open_tasks(uuid, uuid, integer);
drop function public.submit_task_for_review(uuid);
drop function public.review_update_task(uuid, uuid, jsonb);
drop function public.decide_task(uuid, text, uuid, text, text, jsonb, text);
drop function public.set_task_blocked(uuid, text);
drop function public.clear_task_blocked(uuid, text);

-- -----------------------------------------------------------------------------
-- 6. Original function bodies, verbatim
-- -----------------------------------------------------------------------------

-- public.create_task: original definition (pg_get_functiondef before the migration)
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
-- public.update_task: original definition (pg_get_functiondef before the migration)
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
-- public.transition_task: original definition (pg_get_functiondef before the migration)
CREATE OR REPLACE FUNCTION public.transition_task(p_task uuid, p_status uuid, p_override_reason text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_task public.tasks%rowtype;
  v_from uuid;
  v_category text;
  v_current text;
  v_authority boolean;
  v_active boolean;
  v_round integer;
  v_person uuid;
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
    if v_task.reviewer_id is not null then
      if v_task.reviewer_id is distinct from auth.uid() then
        perform app.notify(
          v_task.workspace_id, v_task.reviewer_id, 'task',
          'تسک برای بررسی', 'یک تسک برای بررسی شما فرستاده شد.',
          'task', p_task
        );
      end if;
    elsif v_task.project_id is null then
      perform app.notify_team_approvers(
        v_task.workspace_id, app.primary_team(v_task.primary_assignee_id), 'task',
        'تسک برای بررسی', 'یک تسک برای بررسی فرستاده شد.',
        'task', p_task
      );
    else
      for v_person in
        select profile_id from public.project_members
        where project_id = v_task.project_id
          and removed_at is null
          and member_role in ('manager', 'reviewer')
          and profile_id is distinct from auth.uid()
      loop
        perform app.notify(
          v_task.workspace_id, v_person, 'task',
          'تسک برای بررسی', 'یک تسک برای بررسی فرستاده شد.',
          'task', p_task
        );
      end loop;
    end if;
  end if;

  insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)
  values (v_task.workspace_id, p_task, auth.uid(), 'task.transition', jsonb_build_object('to', p_status));
  if v_category = 'done' and v_task.parent_task_id is not null then
    insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)
    values (v_task.workspace_id, v_task.parent_task_id, auth.uid(), 'task.subtask_done', jsonb_build_object('child', p_task));
  end if;
  perform app.audit(v_task.workspace_id, auth.uid(), 'task.transition', 'task', p_task, jsonb_build_object('status', p_status));
end;
$function$
;
-- public.decide_task: original definition (pg_get_functiondef before the migration)
CREATE OR REPLACE FUNCTION public.decide_task(p_task uuid, p_decision text, p_reason text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_task public.tasks%rowtype;
  v_round uuid;
  v_status uuid;
  v_eligible boolean := false;
  v_title text;
  v_person uuid;
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

  v_title := case p_decision
    when 'approved' then 'تسک تأیید شد'
    when 'revision_requested' then 'تسک برای اصلاح برگشت'
    else 'تسک رد شد'
  end;
  if v_task.primary_assignee_id is distinct from auth.uid() then
    perform app.notify(v_task.workspace_id, v_task.primary_assignee_id, 'task', v_title, 'نتیجه بررسی تسک آماده است.', 'task', p_task);
  end if;
  for v_person in
    select profile_id from public.task_collaborators
    where task_id = p_task
      and profile_id is distinct from auth.uid()
      and profile_id is distinct from v_task.primary_assignee_id
  loop
    perform app.notify(v_task.workspace_id, v_person, 'task', v_title, 'نتیجه بررسی تسک آماده است.', 'task', p_task);
  end loop;

  insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)
  values (v_task.workspace_id, p_task, auth.uid(), 'task.review', jsonb_build_object('decision', p_decision));
  perform app.audit(v_task.workspace_id, auth.uid(), 'task.review', 'task', p_task, jsonb_build_object('decision', p_decision));
end;
$function$
;
-- public.add_task_collaborator: original definition (pg_get_functiondef before the migration)
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
-- public.remove_project_member: original definition (pg_get_functiondef before the migration)
CREATE OR REPLACE FUNCTION public.remove_project_member(p_project uuid, p_profile uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_role text;
  v_managers integer;
  v_workspace uuid;
begin
  perform app.require_active();
  if not app.can_edit_project(p_project) then
    raise exception 'forbidden';
  end if;
  select workspace_id into v_workspace from public.projects where id = p_project;
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
  if p_profile is distinct from auth.uid() and v_workspace is not null then
    perform app.notify(
      v_workspace, p_profile, 'project',
      'از پروژه برداشته شدید', 'عضویت شما در یک پروژه پایان یافت.',
      'project', p_project
    );
  end if;
  perform app.audit(app.current_workspace(), auth.uid(), 'project.member_remove', 'project', p_project, jsonb_build_object('profile_id', p_profile));
end;
$function$
;
-- public.save_workflow_status: original definition (pg_get_functiondef before the migration)
CREATE OR REPLACE FUNCTION public.save_workflow_status(p_workflow uuid, p_status uuid, p_name text, p_category text, p_position integer, p_requires_authority boolean, p_active boolean)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$
;
-- public.project_sprint_counts: original definition (pg_get_functiondef before the migration)
drop function public.project_sprint_counts(uuid);
CREATE OR REPLACE FUNCTION public.project_sprint_counts(p_project uuid)
 RETURNS TABLE(sprint_id uuid, total integer, complete integer, blocked integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform app.require_active();
  if not app.can_view_project(p_project) then
    raise exception 'forbidden';
  end if;
  return query
  select
    s.id,
    count(t.id)::integer,
    count(t.id) filter (where app.task_counts_complete(t.id))::integer,
    count(t.id) filter (
      where st.category = 'blocked' and not app.task_counts_complete(t.id)
    )::integer
  from public.sprints s
  left join public.sprint_tasks link
    on link.sprint_id = s.id and link.removed_at is null
  left join public.tasks t
    on t.id = link.task_id
    and t.archived_at is null
    and app.can_view_task(t.id)
  left join public.workflow_statuses st on st.id = t.status_id
  where s.project_id = p_project
  group by s.id;
end;
$function$
;
-- public.project_milestone_counts: original definition (pg_get_functiondef before the migration)
drop function public.project_milestone_counts(uuid);
CREATE OR REPLACE FUNCTION public.project_milestone_counts(p_project uuid)
 RETURNS TABLE(milestone_id uuid, total integer, complete integer, blocked integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform app.require_active();
  if not app.can_view_project(p_project) then
    raise exception 'forbidden';
  end if;
  return query
  select
    m.id,
    count(t.id)::integer,
    count(t.id) filter (where app.task_counts_complete(t.id))::integer,
    count(t.id) filter (
      where st.category = 'blocked' and not app.task_counts_complete(t.id)
    )::integer
  from public.milestones m
  left join public.milestone_tasks link on link.milestone_id = m.id
  left join public.tasks t
    on t.id = link.task_id
    and t.archived_at is null
    and app.can_view_task(t.id)
  left join public.workflow_statuses st on st.id = t.status_id
  where m.project_id = p_project
  group by m.id;
end;
$function$
;
-- public.set_sprint_status: original definition (pg_get_functiondef before the migration)
CREATE OR REPLACE FUNCTION public.set_sprint_status(p_sprint uuid, p_status text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_project uuid;
  v public.sprints%rowtype;
  v_total integer;
  v_complete integer;
  v_blocked integer;
begin
  if p_status not in ('planned', 'active', 'closed', 'cancelled') then
    raise exception 'invalid_status';
  end if;
  select project_id into v_project from public.sprints where id = p_sprint;
  if v_project is null then
    raise exception 'forbidden';
  end if;
  perform app.require_plan_manager(v_project);
  perform 1 from public.projects where id = v_project for update;
  select * into v from public.sprints where id = p_sprint for update;
  if v.status = p_status then
    return;
  end if;
  if v.status = 'planned' and p_status not in ('active', 'cancelled') then
    raise exception 'invalid_status';
  end if;
  if v.status = 'active' and p_status not in ('closed', 'cancelled') then
    raise exception 'invalid_status';
  end if;
  if v.status in ('closed', 'cancelled') then
    raise exception 'invalid_status';
  end if;
  if p_status = 'active' and exists (
    select 1 from public.sprints
    where project_id = v.project_id and status = 'active' and id <> v.id
  ) then
    raise exception 'already_active';
  end if;
  if p_status = 'closed' and v.summary is null then
    select
      count(t.id)::integer,
      count(t.id) filter (where app.task_counts_complete(t.id))::integer,
      count(t.id) filter (
        where st.category = 'blocked' and not app.task_counts_complete(t.id)
      )::integer
    into v_total, v_complete, v_blocked
    from public.sprint_tasks link
    join public.tasks t on t.id = link.task_id and t.archived_at is null
    join public.workflow_statuses st on st.id = t.status_id
    where link.sprint_id = v.id and link.removed_at is null;
    update public.sprints
      set status = 'closed',
          summary = jsonb_build_object(
            'total', v_total,
            'complete', v_complete,
            'blocked', v_blocked,
            'remaining', v_total - v_complete,
            'percent', case when v_total = 0 then 0 else v_complete * 100 / v_total end
          )
    where id = v.id;
  else
    update public.sprints set status = p_status where id = v.id;
  end if;
  perform app.audit(
    v.workspace_id, auth.uid(), 'sprint.status', 'sprint', v.id,
    jsonb_build_object('status', p_status)
  );
exception
  when unique_violation then
    raise exception 'already_active';
end;
$function$
;
-- public.work_analytics: original definition (pg_get_functiondef before the migration)
CREATE OR REPLACE FUNCTION public.work_analytics(p_project uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform app.require_active();
  if p_project is not null and not app.can_view_project(p_project) then
    raise exception 'forbidden';
  end if;
  return jsonb_build_object(
    'by_status', coalesce((
      select jsonb_agg(jsonb_build_object('name', name, 'category', category, 'total', total) order by position)
      from (
        select s.name, s.category, s.position, count(*)::integer as total
        from public.tasks t
        join public.workflow_statuses s on s.id = t.status_id
        where t.archived_at is null and app.can_view_task(t.id)
          and (p_project is null or t.project_id = p_project)
        group by s.name, s.category, s.position
      ) buckets
    ), '[]'::jsonb),
    'by_priority', coalesce((
      select jsonb_agg(jsonb_build_object('priority', priority, 'total', total) order by priority)
      from (
        select t.priority, count(*)::integer as total
        from public.tasks t
        where t.archived_at is null and app.can_view_task(t.id)
          and (p_project is null or t.project_id = p_project)
        group by t.priority
      ) buckets
    ), '[]'::jsonb),
    'by_assignee', coalesce((
      select jsonb_agg(jsonb_build_object('name', name, 'total', total) order by total desc)
      from (
        select trim(concat(p.first_name, ' ', p.last_name)) as name, count(*)::integer as total
        from public.tasks t
        join public.profiles p on p.id = t.primary_assignee_id
        where t.archived_at is null and app.can_view_task(t.id)
          and (p_project is null or t.project_id = p_project)
        group by p.first_name, p.last_name
      ) buckets
    ), '[]'::jsonb),
    'complete', (
      select count(*) from public.tasks t
      where t.archived_at is null and app.can_view_task(t.id) and app.task_counts_complete(t.id)
        and (p_project is null or t.project_id = p_project)
    ),
    'remaining', (
      select count(*) from public.tasks t
      where t.archived_at is null and app.can_view_task(t.id) and not app.task_counts_complete(t.id)
        and (p_project is null or t.project_id = p_project)
    ),
    'awaiting', (
      select count(*) from public.tasks t
      join public.workflow_statuses s on s.id = t.status_id
      where t.archived_at is null and app.can_view_task(t.id)
        and t.approval_required and t.approval_state = 'pending' and s.category = 'in_review'
        and (p_project is null or t.project_id = p_project)
    ),
    'revision', (
      select count(*) from public.tasks t
      join public.workflow_statuses s on s.id = t.status_id
      where t.archived_at is null and app.can_view_task(t.id)
        and (s.category = 'changes_requested' or t.approval_state = 'changes_requested')
        and (p_project is null or t.project_id = p_project)
    ),
    'blocked', (
      select count(*) from public.tasks t
      join public.workflow_statuses s on s.id = t.status_id
      where t.archived_at is null and app.can_view_task(t.id) and s.category = 'blocked'
        and not app.task_counts_complete(t.id)
        and (p_project is null or t.project_id = p_project)
    ),
    'overdue', (
      select count(*) from public.tasks t
      where t.archived_at is null and app.can_view_task(t.id)
        and t.due_at < clock_timestamp() and not app.task_counts_complete(t.id)
        and (p_project is null or t.project_id = p_project)
    ),
    'sprints', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', s.id, 'project_id', s.project_id, 'name', s.name, 'status', s.status,
        'start_date', s.start_date, 'end_date', s.end_date,
        'total', coalesce(c.total, 0), 'complete', coalesce(c.complete, 0),
        'remaining', greatest(coalesce(c.total, 0) - coalesce(c.complete, 0), 0),
        'percent', case when coalesce(c.total, 0) = 0 then 0 else (c.complete * 100 / c.total) end,
        'summary', s.summary
      ) order by s.start_date desc, s.id)
      from public.sprints s
      left join lateral (
        select count(t.id)::integer as total,
          count(t.id) filter (where app.task_counts_complete(t.id))::integer as complete
        from public.sprint_tasks link
        join public.tasks t on t.id = link.task_id and t.archived_at is null and app.can_view_task(t.id)
        where link.sprint_id = s.id and link.removed_at is null
      ) c on true
      where app.can_view_project(s.project_id) and (p_project is null or s.project_id = p_project)
    ), '[]'::jsonb),
    'milestones', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', m.id, 'project_id', m.project_id, 'title', m.title, 'status', m.status,
        'target_date', m.target_date,
        'total', coalesce(c.total, 0), 'complete', coalesce(c.complete, 0),
        'remaining', greatest(coalesce(c.total, 0) - coalesce(c.complete, 0), 0),
        'percent', case when coalesce(c.total, 0) = 0 then 0 else (c.complete * 100 / c.total) end
      ) order by m.target_date, m.id)
      from public.milestones m
      left join lateral (
        select count(t.id)::integer as total,
          count(t.id) filter (where app.task_counts_complete(t.id))::integer as complete
        from public.milestone_tasks mt
        join public.tasks t on t.id = mt.task_id and t.archived_at is null and app.can_view_task(t.id)
        where mt.milestone_id = m.id
      ) c on true
      where app.can_view_project(m.project_id) and (p_project is null or m.project_id = p_project)
    ), '[]'::jsonb)
  );
end;
$function$
;
-- app.seed_workflow: original definition (pg_get_functiondef before the migration)
CREATE OR REPLACE FUNCTION app.seed_workflow(p_workspace uuid, p_project uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$
;
-- public.remove_task_collaborator: original definition (pg_get_functiondef before the migration)
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
-- app.task_visible_directly: original definition (pg_get_functiondef before the migration)
CREATE OR REPLACE FUNCTION app.task_visible_directly(p_project uuid, p_assignee uuid, p_task uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_visibility text;
begin
  if p_project is null then
    return p_assignee = auth.uid()
      or app.is_team_approver(app.primary_team(p_assignee), auth.uid())
      or app.has_permission('tasks.view.all');
  end if;

  select visibility into v_visibility from public.projects where id = p_project;
  if app.has_permission('projects.view.all') then
    return true;
  end if;
  if v_visibility = 'project_wide' then
    return exists (
      select 1 from public.project_members
      where project_id = p_project and profile_id = auth.uid() and removed_at is null
    );
  end if;
  return p_assignee = auth.uid()
    or exists (
      select 1 from public.task_collaborators
      where task_id = p_task and profile_id = auth.uid()
    )
    or exists (
      select 1 from public.project_members
      where project_id = p_project
        and profile_id = auth.uid()
        and removed_at is null
        and member_role in ('manager', 'reviewer')
    );
end;
$function$
;
-- public.set_task_labels: original definition (pg_get_functiondef before the migration)
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
-- public.add_checklist_item: original definition (pg_get_functiondef before the migration)
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
-- public.toggle_checklist_item: original definition (pg_get_functiondef before the migration)
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
-- public.rename_checklist_item: original definition (pg_get_functiondef before the migration)
CREATE OR REPLACE FUNCTION public.rename_checklist_item(p_item uuid, p_title text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$
;
-- public.delete_checklist_item: original definition (pg_get_functiondef before the migration)
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
-- public.move_checklist_item: original definition (pg_get_functiondef before the migration)
CREATE OR REPLACE FUNCTION public.move_checklist_item(p_item uuid, p_direction integer)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$
;
-- public.transfer_sprint_remainder: original definition (pg_get_functiondef before the migration)
CREATE OR REPLACE FUNCTION public.transfer_sprint_remainder(p_from uuid, p_to uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_from public.sprints%rowtype;
  v_to public.sprints%rowtype;
  v_task uuid;
  v_count integer := 0;
begin
  if p_from = p_to then
    raise exception 'invalid_status';
  end if;
  select * into v_from from public.sprints where id = p_from;
  select * into v_to from public.sprints where id = p_to;
  if v_from.id is null or v_to.id is null then
    raise exception 'forbidden';
  end if;
  perform app.require_plan_manager(v_from.project_id);
  if v_from.project_id <> v_to.project_id then
    raise exception 'project_mismatch';
  end if;
  if v_to.status not in ('planned', 'active') then
    raise exception 'invalid_status';
  end if;
  perform 1 from public.projects where id = v_from.project_id for update;
  for v_task in
    select t.id
    from public.sprint_tasks link
    join public.tasks t on t.id = link.task_id
    where link.sprint_id = v_from.id
      and link.removed_at is null
      and t.archived_at is null
      and not app.task_counts_complete(t.id)
  loop
    perform public.move_task_to_sprint(v_task, v_to.id);
    v_count := v_count + 1;
  end loop;
  perform app.audit(
    v_from.workspace_id, auth.uid(), 'sprint.transfer', 'sprint', v_from.id,
    jsonb_build_object('to', v_to.id, 'count', v_count)
  );
  return v_count;
end;
$function$
;
-- public.set_milestone_status: original definition (pg_get_functiondef before the migration)
CREATE OR REPLACE FUNCTION public.set_milestone_status(p_milestone uuid, p_status text, p_reason text DEFAULT ''::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v public.milestones%rowtype;
  v_open integer;
begin
  if p_status not in ('upcoming', 'in_progress', 'reached', 'cancelled') then
    raise exception 'invalid_status';
  end if;
  select * into v from public.milestones where id = p_milestone for update;
  if v.id is null then
    raise exception 'forbidden';
  end if;
  perform app.require_plan_manager(v.project_id);
  if p_status = 'reached' then
    select count(*)::integer into v_open
    from public.milestone_tasks mt
    join public.tasks t on t.id = mt.task_id
    where mt.milestone_id = v.id
      and t.archived_at is null
      and not app.task_counts_complete(t.id);
    if v_open > 0 and char_length(trim(coalesce(p_reason, ''))) = 0 then
      raise exception 'tasks_incomplete';
    end if;
    if v_open > 0 then
      perform app.audit(
        v.workspace_id, auth.uid(), 'milestone.override', 'milestone', v.id,
        jsonb_build_object('reason', trim(p_reason), 'open_tasks', v_open)
      );
    end if;
  end if;
  update public.milestones set status = p_status where id = v.id;
  perform app.audit(
    v.workspace_id, auth.uid(), 'milestone.status', 'milestone', v.id,
    jsonb_build_object('status', p_status)
  );
end;
$function$
;
-- app.dashboard_summary_v1: original definition (pg_get_functiondef before the migration)
CREATE OR REPLACE FUNCTION app.dashboard_summary_v1()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_me uuid := auth.uid();
  v_today date := app.tehran_today();
  v_week date := app.week_start(v_today);
  v_month_start date;
  v_month_end date;
  v_show_team boolean;
  v_today_row record;
  v_week_approved bigint;
  v_month_approved bigint;
  v_team jsonb;
  v_projects jsonb;
begin
  perform app.require_active();
  select b.start_date, b.end_date into v_month_start, v_month_end
  from app.gregorian_to_jalali(v_today) j
  join lateral app.jalali_month_bounds(j.jy, j.jm) b on true;

  select * into v_today_row from public.attendance_totals(v_me, v_today, v_today);
  select approved_seconds into v_week_approved from public.attendance_totals(v_me, v_week, v_week + 6);
  select approved_seconds into v_month_approved from public.attendance_totals(v_me, v_month_start, v_month_end);

  v_show_team := app.has_permission('employees.view.team')
    or app.has_permission('employees.view.all')
    or app.has_permission('attendance.view.team')
    or app.has_permission('attendance.view.all');

  if v_show_team then
    select jsonb_build_object(
      'employees', (
        select count(*) from public.profiles p
        where p.id <> v_me and p.status = 'active' and app.can_view_employee(p.id)
      ),
      'open_intervals', (
        select count(distinct i.profile_id) from public.attendance_intervals i
        where i.status = 'open' and i.profile_id <> v_me and app.can_view_attendance(i.profile_id)
      ),
      'pending_reports', (
        select count(distinct r.profile_id) from public.attendance_daily_reports r
        where r.status in ('pending', 'partially_approved', 'needs_revision')
          and app.can_view_attendance(r.profile_id)
      ),
      'pending_corrections', (
        select count(*) from public.attendance_corrections c
        where c.status = 'pending' and app.can_approve_team(c.team_id, 'attendance.approve')
      ),
      'pending_leave', (
        select count(*) from public.leave_requests l
        where l.status = 'pending' and app.can_approve_team(l.team_id, 'leave.approve')
      ),
      'pending_disputes', (
        select count(*) from public.absence_disputes d
        join public.absence_records a on a.id = d.absence_id
        where d.status = 'pending'
          and (
            app.has_permission('absence.record.all')
            or (app.has_permission('absence.record.team') and app.is_team_approver(a.team_id, v_me))
          )
      ),
      'active_tasks', (
        select count(*) from public.tasks t
        where t.archived_at is null and app.can_view_task(t.id)
          and app.can_view_employee(t.primary_assignee_id)
          and not app.task_counts_complete(t.id)
      ),
      'review_tasks', (
        select count(*) from public.tasks t
        join public.workflow_statuses s on s.id = t.status_id
        where t.archived_at is null and s.category = 'in_review' and app.can_view_task(t.id)
          and app.can_view_employee(t.primary_assignee_id)
      ),
      'overdue_tasks', (
        select count(*) from public.tasks t
        where t.archived_at is null and t.due_at < clock_timestamp()
          and app.can_view_task(t.id) and app.can_view_employee(t.primary_assignee_id)
          and not app.task_counts_complete(t.id)
      ),
      'complete_tasks', (
        select count(*) from public.tasks t
        where t.archived_at is null and app.can_view_task(t.id)
          and app.can_view_employee(t.primary_assignee_id)
          and app.task_counts_complete(t.id)
      ),
      'people', '[]'::jsonb
    ) into v_team;
  end if;

  if exists (select 1 from public.projects p where app.can_view_project(p.id))
     or app.has_permission('projects.view.all') then
    select jsonb_build_object(
      'active', (select count(*) from public.projects p where p.status = 'active' and app.can_view_project(p.id)),
      'archived', (select count(*) from public.projects p where p.status = 'archived' and app.can_view_project(p.id)),
      'tasks', (select count(*) from public.tasks t where t.archived_at is null and t.project_id is not null and app.can_view_task(t.id)),
      'awaiting_review', (
        select count(*) from public.tasks t
        join public.workflow_statuses s on s.id = t.status_id
        where t.archived_at is null and t.project_id is not null and s.category = 'in_review' and app.can_view_task(t.id)
      ),
      'overdue', (
        select count(*) from public.tasks t
        where t.archived_at is null and t.project_id is not null and t.due_at < clock_timestamp()
          and app.can_view_task(t.id) and not app.task_counts_complete(t.id)
      ),
      'complete', (
        select count(*) from public.tasks t
        where t.archived_at is null and t.project_id is not null and app.can_view_task(t.id) and app.task_counts_complete(t.id)
      ),
      'active_sprints', (
        select count(*) from public.sprints s where s.status = 'active' and app.can_view_project(s.project_id)
      ),
      'upcoming_milestones', (
        select count(*) from public.milestones m
        where m.status in ('upcoming', 'in_progress') and app.can_view_project(m.project_id)
      ),
      'reached_milestones', (
        select count(*) from public.milestones m
        where m.status = 'reached' and app.can_view_project(m.project_id)
      )
    ) into v_projects;
  end if;

  return jsonb_build_object(
    'personal', jsonb_build_object(
      'open', exists (select 1 from public.attendance_intervals i where i.profile_id = v_me and i.status = 'open'),
      'incomplete', (select count(*) from public.attendance_intervals i where i.profile_id = v_me and i.status = 'incomplete'),
      'recorded_seconds', coalesce(v_today_row.recorded_seconds, 0),
      'pending_seconds', coalesce(v_today_row.pending_seconds, 0),
      'approved_seconds', coalesce(v_today_row.approved_seconds, 0),
      'rejected_seconds', coalesce(v_today_row.rejected_seconds, 0),
      'week_approved_seconds', coalesce(v_week_approved, 0),
      'month_approved_seconds', coalesce(v_month_approved, 0),
      'personal_tasks', (
        select count(*) from public.tasks t
        where t.primary_assignee_id = v_me and t.project_id is null and t.archived_at is null
          and not app.task_counts_complete(t.id)
      ),
      'project_tasks', (
        select count(*) from public.tasks t
        where t.primary_assignee_id = v_me and t.project_id is not null and t.archived_at is null
          and app.can_view_task(t.id) and not app.task_counts_complete(t.id)
      ),
      'awaiting_review', (
        select count(*) from public.tasks t
        join public.workflow_statuses s on s.id = t.status_id
        where t.primary_assignee_id = v_me and t.archived_at is null and s.category = 'in_review' and app.can_view_task(t.id)
      ),
      'needs_revision', (
        select count(*) from public.tasks t
        join public.workflow_statuses s on s.id = t.status_id
        where t.primary_assignee_id = v_me and t.archived_at is null and app.can_view_task(t.id)
          and (s.category = 'changes_requested' or t.approval_state = 'changes_requested')
      ),
      'leave_pending', (select count(*) from public.leave_requests l where l.profile_id = v_me and l.status = 'pending'),
      'unread', (select count(*) from public.notifications n where n.recipient_id = v_me and n.read_at is null),
      'statuses', coalesce((
        select jsonb_agg(jsonb_build_object('name', s.name, 'category', s.category, 'total', counted.total) order by s.position)
        from (
          select t.status_id, count(*)::integer as total
          from public.tasks t
          where t.primary_assignee_id = v_me and t.archived_at is null and app.can_view_task(t.id)
          group by t.status_id
        ) counted
        join public.workflow_statuses s on s.id = counted.status_id
      ), '[]'::jsonb)
    ),
    'team', v_team,
    'projects', v_projects,
    'queues', jsonb_build_object(
      'attendance', (
        select count(*) from public.attendance_daily_reports r
        where r.status in ('pending', 'partially_approved', 'needs_revision')
          and app.can_approve_team(r.team_id, 'attendance.approve')
      ),
      'corrections', (
        select count(*) from public.attendance_corrections c
        where c.status = 'pending' and app.can_approve_team(c.team_id, 'attendance.approve')
      ),
      'leave', (
        select count(*) from public.leave_requests l
        where l.status = 'pending' and app.can_approve_team(l.team_id, 'leave.approve')
      ),
      'disputes', (
        select count(*) from public.absence_disputes d
        join public.absence_records a on a.id = d.absence_id
        where d.status = 'pending'
          and (
            app.has_permission('absence.record.all')
            or (app.has_permission('absence.record.team') and app.is_team_approver(a.team_id, v_me))
          )
      ),
      'task_reviews', (
        select count(*) from public.tasks t
        join public.workflow_statuses s on s.id = t.status_id
        where t.archived_at is null and s.category = 'in_review' and t.approval_required and t.approval_state = 'pending'
          and (
            t.reviewer_id = v_me
            or app.is_super_admin(v_me)
            or (t.reviewer_id is null and t.project_id is null and app.is_team_approver(app.primary_team(t.primary_assignee_id), v_me))
            or (t.reviewer_id is null and t.project_id is not null and exists (
              select 1 from public.project_members m
              where m.project_id = t.project_id and m.profile_id = v_me and m.removed_at is null
                and m.member_role in ('manager', 'reviewer')
            ))
          )
      )
    )
  );
end;
$function$
;
-- public.dashboard_projects: original definition (pg_get_functiondef before the migration)
CREATE OR REPLACE FUNCTION public.dashboard_projects()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform app.require_active();
  if not (exists (select 1 from public.projects p where app.can_view_project(p.id))
          or app.has_permission('projects.view.all')) then
    return null;
  end if;
  return jsonb_build_object(
    'active', (select count(*) from public.projects p where p.status = 'active' and app.can_view_project(p.id)),
    'archived', (select count(*) from public.projects p where p.status = 'archived' and app.can_view_project(p.id)),
    'tasks', (select count(*) from public.tasks t where t.archived_at is null and t.project_id is not null and app.can_view_task(t.id)),
    'awaiting_review', (
      select count(*) from public.tasks t
      join public.workflow_statuses s on s.id = t.status_id
      where t.archived_at is null and t.project_id is not null and s.category = 'in_review' and app.can_view_task(t.id)
    ),
    'overdue', (
      select count(*) from public.tasks t
      where t.archived_at is null and t.project_id is not null and t.due_at < clock_timestamp()
        and app.can_view_task(t.id) and not app.task_counts_complete(t.id)
    ),
    'complete', (
      select count(*) from public.tasks t
      where t.archived_at is null and t.project_id is not null and app.can_view_task(t.id) and app.task_counts_complete(t.id)
    ),
    'active_sprints', (
      select count(*) from public.sprints s where s.status = 'active' and app.can_view_project(s.project_id)
    ),
    'upcoming_milestones', (
      select count(*) from public.milestones m
      where m.status in ('upcoming', 'in_progress') and app.can_view_project(m.project_id)
    ),
    'reached_milestones', (
      select count(*) from public.milestones m
      where m.status = 'reached' and app.can_view_project(m.project_id)
    )
  );
end;
$function$
;
-- public.dashboard_team: original definition (pg_get_functiondef before the migration)
CREATE OR REPLACE FUNCTION public.dashboard_team()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_me uuid := auth.uid();
  v_attendance uuid[];
  v_employees uuid[];
  v_att_approve record;
  v_leave_approve record;
  v_abs_all boolean;
  v_abs_team boolean;
  v_teams uuid[];
begin
  perform app.require_active();
  if not (app.has_permission('employees.view.team')
       or app.has_permission('employees.view.all')
       or app.has_permission('attendance.view.team')
       or app.has_permission('attendance.view.all')) then
    return null;
  end if;

  v_attendance := array(select app.dash_attendance_profiles());
  v_employees := array(select app.dash_employee_profiles());
  select * into v_att_approve from app.dash_approval_scope('attendance.approve');
  select * into v_leave_approve from app.dash_approval_scope('leave.approve');
  v_abs_all := app.has_permission('absence.record.all');
  v_abs_team := app.has_permission('absence.record.team');
  v_teams := app.dash_approver_teams();

  return jsonb_build_object(
    'employees', (
      select count(*) from public.profiles p
      where p.id <> v_me and p.status = 'active' and p.id in (select unnest(v_employees))
    ),
    'open_intervals', (
      select count(distinct i.profile_id) from public.attendance_intervals i
      where i.status = 'open' and i.profile_id <> v_me and i.profile_id in (select unnest(v_attendance))
    ),
    'pending_reports', (
      select count(distinct r.profile_id) from public.attendance_daily_reports r
      where r.status in ('pending', 'partially_approved', 'needs_revision')
        and r.profile_id in (select unnest(v_attendance))
    ),
    'pending_corrections', (
      select count(*) from public.attendance_corrections c
      where c.status = 'pending' and (v_att_approve.all_teams or c.team_id = any(v_att_approve.teams))
    ),
    'pending_leave', (
      select count(*) from public.leave_requests l
      where l.status = 'pending' and (v_leave_approve.all_teams or l.team_id = any(v_leave_approve.teams))
    ),
    'pending_disputes', (
      select count(*) from public.absence_disputes d
      join public.absence_records a on a.id = d.absence_id
      where d.status = 'pending'
        and (v_abs_all or (v_abs_team and a.team_id = any(v_teams)))
    ),
    'active_tasks', (
      select count(*) from public.tasks t
      where t.archived_at is null and app.can_view_task(t.id)
        and t.primary_assignee_id in (select unnest(v_employees))
        and not app.task_counts_complete(t.id)
    ),
    'review_tasks', (
      select count(*) from public.tasks t
      join public.workflow_statuses s on s.id = t.status_id
      where t.archived_at is null and s.category = 'in_review' and app.can_view_task(t.id)
        and t.primary_assignee_id in (select unnest(v_employees))
    ),
    'overdue_tasks', (
      select count(*) from public.tasks t
      where t.archived_at is null and t.due_at < clock_timestamp()
        and app.can_view_task(t.id) and t.primary_assignee_id in (select unnest(v_employees))
        and not app.task_counts_complete(t.id)
    ),
    'complete_tasks', (
      select count(*) from public.tasks t
      where t.archived_at is null and app.can_view_task(t.id)
        and t.primary_assignee_id in (select unnest(v_employees))
        and app.task_counts_complete(t.id)
    ),
    'people', '[]'::jsonb
  );
end;
$function$
;
-- public.dashboard_people: original definition (pg_get_functiondef before the migration)
CREATE OR REPLACE FUNCTION public.dashboard_people(p_search text DEFAULT ''::text, p_team uuid DEFAULT NULL::uuid, p_sort text DEFAULT 'name'::text, p_desc boolean DEFAULT false, p_offset integer DEFAULT 0, p_limit integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_me uuid := auth.uid();
  v_today date := app.tehran_today();
  v_month_start date;
  v_month_end date;
  v_search text;
  v_sort text := case
    when p_sort in (
      'name', 'position', 'approved_seconds', 'pending_seconds',
      'active_tasks', 'complete_tasks', 'review_tasks', 'open_corrections'
    ) then p_sort
    else 'name'
  end;
  v_desc boolean := coalesce(p_desc, false);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_limit integer := least(greatest(coalesce(p_limit, 30), 1), 100);
  v_rows jsonb;
  v_total integer;
begin
  perform app.require_active();
  if p_team is not null and not (
    app.has_permission('employees.view.all')
    or app.has_permission('attendance.view.all')
    or app.is_team_approver(p_team, v_me)
  ) then
    raise exception 'forbidden';
  end if;
  select b.start_date, b.end_date into v_month_start, v_month_end
  from app.gregorian_to_jalali(v_today) j
  join lateral app.jalali_month_bounds(j.jy, j.jm) b on true;
  v_search := replace(replace(replace(coalesce(p_search, ''), '\', '\\'), '%', '\%'), '_', '\_');

  -- shortcut: name search uses a leading wildcard; add pg_trgm if this page gets slow.
  with listed as (
    select jsonb_build_object(
      'id', p.id,
      'name', trim(concat(p.first_name, ' ', p.last_name)),
      'position', coalesce(pos.title, ''),
      'approved_seconds', coalesce(att.approved_seconds, 0),
      'pending_seconds', coalesce(att.pending_seconds, 0),
      'active_tasks', coalesce(tk.active_tasks, 0),
      'complete_tasks', coalesce(tk.complete_tasks, 0),
      'review_tasks', coalesce(tk.review_tasks, 0),
      'open_corrections', coalesce(cor.total, 0)
    ) as person
    from public.profiles p
    left join public.job_positions pos on pos.id = p.job_position_id
    left join lateral (
      select
        coalesce(sum(extract(epoch from (s.ended_at - s.started_at))) filter (
          where s.approval_mode = 'correction' or ri.decision = 'approved'
        ), 0)::bigint as approved_seconds,
        coalesce(sum(extract(epoch from (s.ended_at - s.started_at))) filter (
          where s.approval_mode = 'report' and coalesce(ri.decision, 'pending') = 'pending'
        ), 0)::bigint as pending_seconds
      from public.attendance_daily_segments s
      join public.attendance_intervals i on i.id = s.interval_id
      left join public.attendance_report_items ri on ri.segment_id = s.id
      where s.profile_id = p.id
        and app.can_view_attendance(p.id)
        and s.tehran_date between v_month_start and v_month_end
        and s.superseded_at is null
        and i.status <> 'void'
    ) att on true
    left join lateral (
      select
        count(*) filter (where not app.task_counts_complete(t.id))::integer as active_tasks,
        count(*) filter (where app.task_counts_complete(t.id))::integer as complete_tasks,
        count(*) filter (where s.category = 'in_review')::integer as review_tasks
      from public.tasks t
      join public.workflow_statuses s on s.id = t.status_id
      where t.primary_assignee_id = p.id and t.archived_at is null and app.can_view_task(t.id)
    ) tk on true
    left join lateral (
      select count(*)::integer as total
      from public.attendance_corrections c
      where c.profile_id = p.id and c.status = 'pending' and app.can_view_attendance(c.profile_id)
    ) cor on true
    where p.id <> v_me and p.status = 'active' and app.can_view_employee(p.id)
      and (v_search = '' or trim(concat(p.first_name, ' ', p.last_name)) ilike '%' || v_search || '%' escape '\')
      and (
        p_team is null
        or exists (
          select 1 from public.team_memberships m
          where m.profile_id = p.id and m.team_id = p_team and m.is_primary and m.left_at is null
        )
      )
  )
  select count(*)::integer,
    coalesce((
      select jsonb_agg(ordered.person order by ordered.ord)
      from (
        select person, row_number() over () as ord
        from (
          select person from listed
          order by
            case when v_sort = 'name' and not v_desc then person->>'name' end asc,
            case when v_sort = 'name' and v_desc then person->>'name' end desc,
            case when v_sort = 'position' and not v_desc then person->>'position' end asc,
            case when v_sort = 'position' and v_desc then person->>'position' end desc,
            case when v_sort = 'approved_seconds' and not v_desc then (person->>'approved_seconds')::bigint end asc,
            case when v_sort = 'approved_seconds' and v_desc then (person->>'approved_seconds')::bigint end desc,
            case when v_sort = 'pending_seconds' and not v_desc then (person->>'pending_seconds')::bigint end asc,
            case when v_sort = 'pending_seconds' and v_desc then (person->>'pending_seconds')::bigint end desc,
            case when v_sort = 'active_tasks' and not v_desc then (person->>'active_tasks')::bigint end asc,
            case when v_sort = 'active_tasks' and v_desc then (person->>'active_tasks')::bigint end desc,
            case when v_sort = 'complete_tasks' and not v_desc then (person->>'complete_tasks')::bigint end asc,
            case when v_sort = 'complete_tasks' and v_desc then (person->>'complete_tasks')::bigint end desc,
            case when v_sort = 'review_tasks' and not v_desc then (person->>'review_tasks')::bigint end asc,
            case when v_sort = 'review_tasks' and v_desc then (person->>'review_tasks')::bigint end desc,
            case when v_sort = 'open_corrections' and not v_desc then (person->>'open_corrections')::bigint end asc,
            case when v_sort = 'open_corrections' and v_desc then (person->>'open_corrections')::bigint end desc,
            person->>'id'
          offset v_offset limit v_limit
        ) page
      ) ordered
    ), '[]'::jsonb)
  into v_total, v_rows
  from listed;

  return jsonb_build_object('total', coalesce(v_total, 0), 'rows', coalesce(v_rows, '[]'::jsonb));
end;
$function$
;
-- public.dashboard_personal: original definition (pg_get_functiondef before the migration)
CREATE OR REPLACE FUNCTION public.dashboard_personal()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_me uuid := auth.uid();
  v_today date := app.tehran_today();
  v_week date := app.week_start(v_today);
  v_month_start date;
  v_month_end date;
  v_today_row record;
  v_week_approved bigint;
  v_month_approved bigint;
begin
  perform app.require_active();
  select b.start_date, b.end_date into v_month_start, v_month_end
  from app.gregorian_to_jalali(v_today) j
  join lateral app.jalali_month_bounds(j.jy, j.jm) b on true;

  select * into v_today_row from public.attendance_totals(v_me, v_today, v_today);
  select approved_seconds into v_week_approved from public.attendance_totals(v_me, v_week, v_week + 6);
  select approved_seconds into v_month_approved from public.attendance_totals(v_me, v_month_start, v_month_end);

  return jsonb_build_object(
    'open', exists (select 1 from public.attendance_intervals i where i.profile_id = v_me and i.status = 'open'),
    'incomplete', (select count(*) from public.attendance_intervals i where i.profile_id = v_me and i.status = 'incomplete'),
    'recorded_seconds', coalesce(v_today_row.recorded_seconds, 0),
    'pending_seconds', coalesce(v_today_row.pending_seconds, 0),
    'approved_seconds', coalesce(v_today_row.approved_seconds, 0),
    'rejected_seconds', coalesce(v_today_row.rejected_seconds, 0),
    'week_approved_seconds', coalesce(v_week_approved, 0),
    'month_approved_seconds', coalesce(v_month_approved, 0),
    'personal_tasks', (
      select count(*) from public.tasks t
      where t.primary_assignee_id = v_me and t.project_id is null and t.archived_at is null
        and not app.task_counts_complete(t.id)
    ),
    'project_tasks', (
      select count(*) from public.tasks t
      where t.primary_assignee_id = v_me and t.project_id is not null and t.archived_at is null
        and app.can_view_task(t.id) and not app.task_counts_complete(t.id)
    ),
    'awaiting_review', (
      select count(*) from public.tasks t
      join public.workflow_statuses s on s.id = t.status_id
      where t.primary_assignee_id = v_me and t.archived_at is null and s.category = 'in_review' and app.can_view_task(t.id)
    ),
    'needs_revision', (
      select count(*) from public.tasks t
      join public.workflow_statuses s on s.id = t.status_id
      where t.primary_assignee_id = v_me and t.archived_at is null and app.can_view_task(t.id)
        and (s.category = 'changes_requested' or t.approval_state = 'changes_requested')
    ),
    'leave_pending', (select count(*) from public.leave_requests l where l.profile_id = v_me and l.status = 'pending'),
    'unread', (select count(*) from public.notifications n where n.recipient_id = v_me and n.read_at is null),
    'statuses', coalesce((
      select jsonb_agg(jsonb_build_object('name', s.name, 'category', s.category, 'total', counted.total) order by s.position)
      from (
        select t.status_id, count(*)::integer as total
        from public.tasks t
        where t.primary_assignee_id = v_me and t.archived_at is null and app.can_view_task(t.id)
        group by t.status_id
      ) counted
      join public.workflow_statuses s on s.id = counted.status_id
    ), '[]'::jsonb)
  );
end;
$function$
;

revoke all on function public.create_task(text, text, uuid, uuid, text, timestamptz, boolean, uuid, uuid, boolean) from public, anon;
grant execute on function public.create_task(text, text, uuid, uuid, text, timestamptz, boolean, uuid, uuid, boolean) to authenticated, service_role;
revoke all on function public.update_task(uuid, text, text, uuid, uuid, text, timestamptz, boolean) from public, anon;
grant execute on function public.update_task(uuid, text, text, uuid, uuid, text, timestamptz, boolean) to authenticated, service_role;
revoke all on function public.transition_task(uuid, uuid, text) from public, anon;
grant execute on function public.transition_task(uuid, uuid, text) to authenticated, service_role;
revoke all on function public.decide_task(uuid, text, text) from public, anon;
grant execute on function public.decide_task(uuid, text, text) to authenticated, service_role;
revoke all on function public.add_task_collaborator(uuid, uuid) from public, anon;
grant execute on function public.add_task_collaborator(uuid, uuid) to authenticated, service_role;
revoke all on function public.remove_project_member(uuid, uuid) from public, anon;
grant execute on function public.remove_project_member(uuid, uuid) to authenticated, service_role;
revoke all on function public.save_workflow_status(uuid, uuid, text, text, integer, boolean, boolean) from public, anon;
grant execute on function public.save_workflow_status(uuid, uuid, text, text, integer, boolean, boolean) to authenticated, service_role;
revoke all on function public.project_sprint_counts(uuid) from public, anon;
grant execute on function public.project_sprint_counts(uuid) to authenticated, service_role;
revoke all on function public.project_milestone_counts(uuid) from public, anon;
grant execute on function public.project_milestone_counts(uuid) to authenticated, service_role;
revoke all on function public.set_sprint_status(uuid, text) from public, anon;
grant execute on function public.set_sprint_status(uuid, text) to authenticated, service_role;
revoke all on function public.work_analytics(uuid) from public, anon;
grant execute on function public.work_analytics(uuid) to authenticated, service_role;
revoke all on function app.seed_workflow(uuid, uuid) from public, anon, authenticated;
grant execute on function app.seed_workflow(uuid, uuid) to service_role;
revoke all on function public.remove_task_collaborator(uuid, uuid) from public, anon;
grant execute on function public.remove_task_collaborator(uuid, uuid) to authenticated, service_role;
revoke all on function app.task_visible_directly(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function app.task_visible_directly(uuid, uuid, uuid) to service_role;
revoke all on function public.set_task_labels(uuid, uuid[]) from public, anon;
grant execute on function public.set_task_labels(uuid, uuid[]) to authenticated, service_role;
revoke all on function public.add_checklist_item(uuid, text) from public, anon;
grant execute on function public.add_checklist_item(uuid, text) to authenticated, service_role;
revoke all on function public.toggle_checklist_item(uuid, boolean) from public, anon;
grant execute on function public.toggle_checklist_item(uuid, boolean) to authenticated, service_role;
revoke all on function public.rename_checklist_item(uuid, text) from public, anon;
grant execute on function public.rename_checklist_item(uuid, text) to authenticated, service_role;
revoke all on function public.delete_checklist_item(uuid) from public, anon;
grant execute on function public.delete_checklist_item(uuid) to authenticated, service_role;
revoke all on function public.move_checklist_item(uuid, integer) from public, anon;
grant execute on function public.move_checklist_item(uuid, integer) to authenticated, service_role;
revoke all on function public.transfer_sprint_remainder(uuid, uuid) from public, anon;
grant execute on function public.transfer_sprint_remainder(uuid, uuid) to authenticated, service_role;
revoke all on function public.set_milestone_status(uuid, text, text) from public, anon;
grant execute on function public.set_milestone_status(uuid, text, text) to authenticated, service_role;
revoke all on function app.dashboard_summary_v1() from public, anon, authenticated, service_role;
revoke all on function public.dashboard_projects() from public, anon;
grant execute on function public.dashboard_projects() to authenticated, service_role;
revoke all on function public.dashboard_team() from public, anon;
grant execute on function public.dashboard_team() to authenticated, service_role;
revoke all on function public.dashboard_people(text, uuid, text, boolean, integer, integer) from public, anon;
grant execute on function public.dashboard_people(text, uuid, text, boolean, integer, integer) to authenticated, service_role;
revoke all on function public.dashboard_personal() from public, anon;
grant execute on function public.dashboard_personal() to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 7. Internal helpers no restored body uses. KEPT because kept triggers use them:
--    app.protect_review_round(), app.reject_change(), app.check_revision_request().
-- -----------------------------------------------------------------------------
drop function app.require_revision_request();
drop function app.apply_review_changes(public.tasks, uuid, jsonb);
drop function app.open_tasks_of_member(uuid, uuid, integer);
drop function app.open_round(uuid);
drop function app.workflow_status(uuid, text);
drop function app.can_decide_task(public.tasks);
drop function app.can_act_on_task(public.tasks);
drop function app.task_snapshot(uuid);
drop function app.personal_assign_scope(uuid);
drop function app.require_active_profile(uuid, text);
drop function app.require_active_member(uuid, uuid, text);
drop function app.task_is_open(uuid);
drop function app.task_is_unresolved(uuid);
drop function app.person_json(uuid);
drop function app.person_label(uuid);

-- -----------------------------------------------------------------------------
-- 8. Kept on purpose (proposal §11.2), with RLS and grants unchanged:
--    tasks.blocked_at / blocked_reason / blocked_by (+ check), task_block_events,
--    task_review_rounds.submitted_by / submitted_by_source / submitted_by_name /
--    snapshot / snapshot_version / snapshot_status (+ checks; defaults fit old inserts),
--    task_reviews.reviewer_name / reviewer_name_source (+ check; defaults fit old inserts),
--    task_revision_requests, workflow_status_migration_log / report, workflow_status_changes,
--    workflow_migration_added_transitions, workflow_rollback_runs.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- 9. Proof: every restored body is byte-identical to the pre-migration one
-- -----------------------------------------------------------------------------
do $proof$
declare v_bad text;
begin
  with expected (schema_name, function_name, body_md5) as (values
    ('public', 'create_task', '61b7c206f55778c4b86467f98b64005f'),
    ('public', 'update_task', 'bea102bb34638d7dc9b51873860339c6'),
    ('public', 'transition_task', 'f39ea3a5a2b0a2396a68b75568350113'),
    ('public', 'decide_task', '361d753b144fca1ab46602186649aa87'),
    ('public', 'add_task_collaborator', 'd09e5c80e943b9202d1df02ce1caa44a'),
    ('public', 'remove_project_member', '339b9890a97d8a17a3e2f5782a250899'),
    ('public', 'save_workflow_status', '16d5d97977af03f8fd701171fc230ba8'),
    ('public', 'project_sprint_counts', '0714c2cf6826f9d02064f0eb02b02ef9'),
    ('public', 'project_milestone_counts', 'a6e740247f37ed45c74b575907c4d91b'),
    ('public', 'set_sprint_status', 'b647ab8ba5d26eeb39ce53cf539f95c2'),
    ('public', 'work_analytics', 'e8375a48a390cf4dd6e5befaa625cea0'),
    ('app', 'seed_workflow', '1fa235585321248eda1ea06620734071'),
    ('public', 'remove_task_collaborator', '32b8d4465b37e51378e26e87ed72f8d3'),
    ('app', 'task_visible_directly', 'a9c15d2ad4293dbeb30e550dd14727e6'),
    ('public', 'set_task_labels', 'fcc748914be29dfd3a20b064c3364976'),
    ('public', 'add_checklist_item', '881435920f230fcb2cfbd29ee00df124'),
    ('public', 'toggle_checklist_item', '1ab9acb4261ec9d959e7b5de0f33ca57'),
    ('public', 'rename_checklist_item', '6653d4a66df817128f912db5f34bfe41'),
    ('public', 'delete_checklist_item', 'beb0f3d756f21677be36794672f71579'),
    ('public', 'move_checklist_item', 'd916c8fb9f147193a3abaf33e9247460'),
    ('public', 'transfer_sprint_remainder', 'af4c2391b516c4547b21e3c99dcf16ec'),
    ('public', 'set_milestone_status', '0869f8baecf2d56bee5104b4bb9597ab'),
    ('app', 'dashboard_summary_v1', '5d393fdcba9ea87e8e5e0162871636d3'),
    ('public', 'dashboard_projects', '35b599d1e37f942625b7d5ddc8512d6e'),
    ('public', 'dashboard_team', 'e1a538ee4d1c104aa544d0d2900d8623'),
    ('public', 'dashboard_people', 'b038a59d1b7a47d31566e724d496ccf1'),
    ('public', 'dashboard_personal', '4bf02fe2035090357734cdfa7d3db579')
  )
  select string_agg(e.schema_name || '.' || e.function_name, ', ') into v_bad
  from expected e
  left join pg_namespace n on n.nspname = e.schema_name
  left join pg_proc p on p.pronamespace = n.oid and p.proname = e.function_name
  where p.oid is null or md5(p.prosrc) <> e.body_md5
     or (select count(*) from pg_proc p2 where p2.pronamespace = n.oid and p2.proname = e.function_name) <> 1;
  if v_bad is not null then raise exception 'rollback_body_mismatch: %', v_bad; end if;
  if has_function_privilege('anon', 'public.decide_task(uuid, text, text)', 'execute') then
    raise exception 'rollback_acl_mismatch';
  end if;
end;
$proof$;

-- -----------------------------------------------------------------------------
-- 10. Report: restored and kept, separately; then record the run
-- -----------------------------------------------------------------------------
\echo '== Restored =='
select 'task' as object, task_id::text as id, from_status_id::text as detail from rollback_tasks where restorable
union all select 'status', status_id::text, before::text from rollback_statuses where restorable
union all select 'transition_removed', transition_id::text, null from rollback_transitions where restorable
order by 1, 2;

\echo '== Kept (changed after the migration; left as people set it) =='
select 'task' as object, task_id::text as id, kept_reason as reason from rollback_tasks where not restorable
union all select 'status', status_id::text, 'changed_after_migration' from rollback_statuses where not restorable
union all select 'transition', transition_id::text, kept_reason from rollback_transitions where not restorable
union all select 'blocked_flag', id::text, 'set by a person' from public.tasks where blocked_at is not null
order by 1, 2;

\echo '== Kept by policy (history) =='
select (select count(*) from public.task_review_rounds where snapshot_status = 'captured') as captured_snapshots,
       (select count(*) from public.task_revision_requests) as revision_requests,
       (select count(*) from public.task_block_events) as block_events;

insert into public.workflow_rollback_runs (restored, kept)
select (select count(*) from rollback_tasks where restorable), jsonb_build_object(
  'tasks_kept', (select count(*) from rollback_tasks where not restorable),
  'statuses_kept', (select count(*) from rollback_statuses where not restorable),
  'transitions_restored', (select count(*) from rollback_transitions where restorable),
  'transitions_kept', (select count(*) from rollback_transitions where not restorable),
  'blocked_flags_kept', (select count(*) from public.tasks where blocked_at is not null),
  'captured_snapshots', (select count(*) from public.task_review_rounds where snapshot_status = 'captured'),
  'revision_requests', (select count(*) from public.task_revision_requests),
  'block_events', (select count(*) from public.task_block_events));

commit;
-- Afterwards: the pre-migration scripts/test-db.ps1 must pass unchanged (proposal §14 R-tests).
