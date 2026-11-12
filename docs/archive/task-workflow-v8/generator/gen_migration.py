"""Generates docs/task-workflow-migration-draft.sql from the live function dumps."""
from common import (DOCS, SCRATCH, WF_SELECT, PINNED_STATE_SELECT, EXPECTED_PINNED_STATE, DEFAULT_WORKFLOWS, EXCLUDED_TASKS, EXPECTED_PLAN, EXPECTED_INTEGRITY, INTEGRITY_SELECT,
                    NEW_TRANSITIONS, PLAN_SELECT, RETIRED, dump, patch, q, values)

parts: list[str] = []
add = parts.append
CHANGED: list[str] = []   # existing functions whose body changes (for the doc and the rollback)
NEW_PUBLIC: list[str] = []
NEW_INTERNAL: list[str] = []

add("""-- =============================================================================
-- DRAFT — DO NOT APPLY. Generated; do not edit by hand (see proposal §16).
-- Not in supabase/migrations on purpose. Local Supabase only, after approval.
-- Task review cycle, versions, blocked flag, membership integrity
-- (D1–D7, B1–B3, personal-task rule of proposal §8.3).
-- Existing functions are the exact pg_get_functiondef bodies of the local
-- database with reviewed, minimal edits (proposal §13 lists every edit).
-- One transaction. Retired statuses are deactivated, never deleted.
-- =============================================================================
begin;
set local lock_timeout = '5s';

-- Precondition (proposal §11.1): the API (PostgREST) is stopped for the
-- migration window, so no RPC call can start, or be in flight, with an old
-- function body. The checks below enforce what SQL can enforce.
do $iso$
begin
  -- The guard must read the data as it is after the locks below, statement by statement.
  if current_setting('transaction_isolation') <> 'read committed' then
    raise exception 'migration_isolation' using detail = current_setting('transaction_isolation');
  end if;
end;
$iso$;

-- EXCLUSIVE: blocks every writer and every row lock (SELECT ... FOR UPDATE /
-- FOR SHARE) until commit; plain reads continue. A transaction that already
-- holds any such lock makes this statement wait (lock_timeout aborts the run),
-- so when the guard runs, every earlier write is committed and no new one can
-- start until the migration commits: the guard stays valid to the end.
lock table public.tasks, public.task_review_rounds, public.task_reviews, public.task_collaborators,
           public.project_members, public.workflow_statuses, public.workflow_transitions, public.workflows,
           public.task_labels, public.task_checklist_items, public.task_activity_events in exclusive mode;
-- profiles and projects: no writes during the window (status / name changes would
-- invalidate the integrity and pinned checks); reads continue.
lock table public.profiles, public.projects in share row exclusive mode;

do $sessions$
declare v_other jsonb;
begin
  -- No other client session may hold an open transaction: it could have read
  -- the pre-migration state, or be inside an old function body.
  select jsonb_agg(jsonb_build_object('pid', pid, 'user', usename, 'app', application_name, 'state', state, 'since', xact_start))
  into v_other
  from pg_stat_activity
  where datname = current_database() and pid <> pg_backend_pid()
    and backend_type = 'client backend' and xact_start is not null;
  if v_other is not null then
    raise exception 'concurrent_transactions' using detail = v_other::text;
  end if;
  if exists (select 1 from pg_prepared_xacts where database = current_database()) then
    raise exception 'concurrent_transactions' using detail = 'prepared transactions exist';
  end if;
end;
$sessions$;
""")

# ----------------------------------------------------------------------------- 0. plan + guard
add(f"""
-- -----------------------------------------------------------------------------
-- 0. Plan (same SQL as docs/task-workflow-premigration-report.sql) and guard
-- -----------------------------------------------------------------------------
create temporary table migration_wf on commit drop as
{WF_SELECT.strip()};

create temporary table migration_plan on commit drop as
{PLAN_SELECT.strip()};

create temporary table migration_integrity on commit drop as
{INTEGRITY_SELECT.strip()};

do $guard$
declare
  v_diff jsonb;
begin
  -- (a) exactly the reviewed workflows exist, all of them default (same classification as the plan)
  with expected (workflow_id) as (values
    {values([(w,) for w in DEFAULT_WORKFLOWS])}
  ), actual as (
    select workflow_id::text from migration_wf where is_default
  )
  select jsonb_agg(x) into v_diff from (
    (select workflow_id as x from actual except select workflow_id from expected)
    union all (select workflow_id from expected except select workflow_id from actual)) d;
  if v_diff is not null then raise exception 'premigration_mismatch' using detail = 'workflows: ' || v_diff::text; end if;
  if exists (select 1 from migration_wf where not is_default) then
    raise exception 'premigration_mismatch' using detail = 'custom workflow present: decide its mapping explicitly';
  end if;
  if exists (select 1 from migration_plan where decision = 'custom_workflow') then
    raise exception 'premigration_mismatch' using detail = 'custom workflow with retired statuses';
  end if;

  -- (b) the plan, row by row: task identity, source and target status, decision
  with expected (task_id, from_key, to_key, decision) as (values
    {values(EXPECTED_PLAN)}
  ), actual as (
    select task_id::text, from_key, to_key, decision from migration_plan where decision <> 'keep'
  )
  select jsonb_agg(to_jsonb(d)) into v_diff from (
    (select * from actual except select * from expected)
    union all (select * from expected except select * from actual)) d;
  if v_diff is not null then raise exception 'premigration_mismatch' using detail = 'plan: ' || v_diff::text; end if;
  if exists (select 1 from migration_plan where decision like 'ambiguous%') then
    raise exception 'premigration_mismatch' using detail = 'ambiguous rows need an explicit decision';
  end if;

  -- (c) every pinned task (2 excluded + 2 moved) is exactly in its reviewed state
  with expected (task_id, title, personal, status_key, approval_state, approval_required, assignee, created_by, reviewer, project_id, project_name, workflow_id, status_id, workspace_id, not_archived) as (values
    {values(EXPECTED_PINNED_STATE)}
  ), actual as (
{PINNED_STATE_SELECT.strip()}
  )
  select jsonb_agg(to_jsonb(d)) into v_diff from (
    (select * from actual except select * from expected)
    union all (select * from expected except select * from actual)) d;
  if v_diff is not null then raise exception 'premigration_mismatch' using detail = 'pinned tasks: ' || v_diff::text; end if;

  -- (d) integrity findings: exactly the reviewed rows (reviewers/collaborators/inactive: none)
  with expected (kind, task_id) as (values
    {values(EXPECTED_INTEGRITY)}
  )
  select jsonb_agg(to_jsonb(d)) into v_diff from (
    (select kind, task_id::text from migration_integrity except select * from expected)
    union all (select * from expected except select kind, task_id::text from migration_integrity)) d;
  if v_diff is not null then raise exception 'premigration_mismatch' using detail = 'integrity: ' || v_diff::text; end if;
end;
$guard$;
""")

# ----------------------------------------------------------------------------- 1. bookkeeping
add("""
-- -----------------------------------------------------------------------------
-- 1. Bookkeeping (kept; basis of the rollback). Owner only: no client grants.
-- -----------------------------------------------------------------------------
create table public.workflow_status_migration_log (
  id bigint generated always as identity primary key,
  task_id uuid not null references public.tasks (id),
  from_status_id uuid not null references public.workflow_statuses (id),
  to_status_id uuid not null references public.workflow_statuses (id),
  blocked_set boolean not null default false,
  blocked_at_set timestamptz,                 -- the exact flag the migration set (rollback checks it is untouched)
  migrated_at timestamptz not null default clock_timestamp()
);
create table public.workflow_status_migration_report (
  id bigint generated always as identity primary key,
  kind text not null,
  task_id uuid references public.tasks (id),
  workflow_id uuid references public.workflows (id),
  detail jsonb not null default '{}'::jsonb,
  reported_at timestamptz not null default clock_timestamp()
);
-- Full before/after state of every status the migration edits; the rollback
-- restores a status only while it still equals "after".
create table public.workflow_status_changes (
  status_id uuid primary key references public.workflow_statuses (id),
  before jsonb not null,
  after jsonb not null
);
-- No foreign key: a manager may delete the row later; the rollback then keeps that choice.
create table public.workflow_migration_added_transitions (
  transition_id uuid primary key,
  workflow_id uuid not null,
  from_status_id uuid not null,
  to_status_id uuid not null
);
create table public.workflow_rollback_runs (
  id bigint generated always as identity primary key,
  run_at timestamptz not null default clock_timestamp(),
  run_by text not null default current_user,
  restored integer not null default 0,
  kept jsonb not null default '{}'::jsonb
);
""")

# ----------------------------------------------------------------------------- 2. schema
add("""
-- -----------------------------------------------------------------------------
-- 2. Columns and tables
-- -----------------------------------------------------------------------------
alter table public.tasks
  add column blocked_at timestamptz,
  add column blocked_reason text,
  add column blocked_by uuid references public.profiles (id),
  add constraint tasks_blocked_consistent check (
    (blocked_at is null and blocked_reason is null and blocked_by is null)
    or (blocked_at is not null and char_length(trim(coalesce(blocked_reason, ''))) > 0)
  );

create table public.task_block_events (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references public.tasks (id),
  action text not null check (action in ('blocked', 'unblocked')),
  reason text,
  status_id uuid not null references public.workflow_statuses (id),
  actor_id uuid references public.profiles (id),            -- null only for migration rows
  actor_name text,                                          -- name at that moment; null when unknown
  created_at timestamptz not null default clock_timestamp(),
  check (action = 'unblocked' or char_length(trim(coalesce(reason, ''))) > 0)
);
create index task_block_events_task_idx on public.task_block_events (task_id, created_at);

-- A round is a version (round_number = vN). Defaults keep the pre-migration
-- code (and the rolled-back code) compatible: it inserts only task_id and round_number.
alter table public.task_review_rounds
  add column submitted_by uuid references public.profiles (id),
  add column submitted_by_source text not null default 'unavailable'
    check (submitted_by_source in ('submission', 'activity_event', 'unavailable')),
  add column submitted_by_name text,                        -- only captured at submission
  add column snapshot jsonb,
  add column snapshot_version smallint,
  add column snapshot_status text not null default 'unavailable'
    check (snapshot_status in ('captured', 'unavailable')),
  add constraint task_review_rounds_snapshot_shape check (
    (snapshot_status = 'captured' and snapshot is not null and snapshot_version = 1 and submitted_by_name is not null)
    or (snapshot_status = 'unavailable' and snapshot is null and snapshot_version is null)),
  add constraint task_review_rounds_id_task_key unique (id, task_id);

alter table public.task_reviews
  add column reviewer_name text,                            -- only captured at decision time
  add column reviewer_name_source text not null default 'unavailable'
    check (reviewer_name_source in ('decision', 'unavailable')),
  add constraint task_reviews_name_shape check (
    (reviewer_name_source = 'decision' and reviewer_name is not null)
    or (reviewer_name_source = 'unavailable' and reviewer_name is null)),
  add constraint task_reviews_id_round_key unique (id, round_id);

create table public.task_revision_requests (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references public.tasks (id),
  round_id uuid not null,
  review_id uuid not null unique,
  what_to_change text not null check (char_length(trim(what_to_change)) between 1 and 4000),
  reason text not null check (char_length(trim(reason)) between 1 and 4000),
  created_by uuid not null references public.profiles (id),
  created_by_name text,
  name_source text not null check (name_source in ('decision', 'unavailable')),
  origin text not null check (origin in ('decision', 'legacy_two_part', 'legacy_free_text')),
  created_at timestamptz not null default clock_timestamp(),
  -- the round belongs to the task, the review belongs to the round
  foreign key (round_id, task_id) references public.task_review_rounds (id, task_id),
  foreign key (review_id, round_id) references public.task_reviews (id, round_id),
  check ((name_source = 'decision') = (created_by_name is not null))
);
create index task_revision_requests_task_idx on public.task_revision_requests (task_id, created_at);
""")

# ----------------------------------------------------------------------------- 3. helpers
helpers = []
helpers.append(("app.person_label(uuid)", """
-- Name at this moment, for historical columns. First and last name only.
create function app.person_label(p_profile uuid)
returns text language sql stable security invoker set search_path = '' as $$
  select nullif(trim(concat_ws(' ', p.first_name, p.last_name)), '') from public.profiles p where p.id = p_profile;
$$;"""))
helpers.append(("app.person_json(uuid)", """
create function app.person_json(p_profile uuid)
returns jsonb language sql stable security invoker set search_path = '' as $$
  select jsonb_build_object('id', p.id, 'first_name', p.first_name, 'last_name', p.last_name)
  from public.profiles p where p.id = p_profile;
$$;"""))
helpers.append(("app.require_active_member(uuid, uuid, text)", """
-- D5. Share-locks the membership row so a concurrent remove_project_member
-- (FOR UPDATE on the same row) waits or fails (proposal §13 C8).
create function app.require_active_member(p_project uuid, p_profile uuid, p_error text)
returns void language plpgsql security invoker set search_path = '' as $$
begin
  if p_profile is null then return; end if;
  perform 1 from public.project_members m join public.profiles p on p.id = m.profile_id
  where m.project_id = p_project and m.profile_id = p_profile and m.removed_at is null and p.status = 'active'
  for share of m;
  if not found then raise exception '%', p_error; end if;
end;
$$;"""))
helpers.append(("app.require_active_profile(uuid, text)", """
create function app.require_active_profile(p_profile uuid, p_error text)
returns void language plpgsql security invoker set search_path = '' as $$
begin
  if p_profile is null then return; end if;
  if not exists (select 1 from public.profiles where id = p_profile and status = 'active'
                 and workspace_id = app.current_workspace()) then
    raise exception '%', p_error;
  end if;
end;
$$;"""))
helpers.append(("app.personal_assign_scope(uuid)", """
-- Personal tasks: the scope create_task already uses (no new permission).
create function app.personal_assign_scope(p_assignee uuid)
returns text language sql stable security invoker set search_path = '' as $$
  select case
    when p_assignee = auth.uid() then 'self'
    when app.is_team_approver(app.primary_team(p_assignee), auth.uid()) then 'team_approver'
    when app.has_permission('tasks.view.all') then 'view_all'
  end;
$$;"""))
helpers.append(("app.task_snapshot(uuid)", """
-- The real content of a version at submission time.
create function app.task_snapshot(p_task uuid)
returns jsonb language sql stable security invoker set search_path = '' as $$
  select jsonb_build_object(
    'title', t.title, 'description', t.description, 'priority', t.priority, 'due_at', t.due_at,
    'approval_required', t.approval_required, 'project_id', t.project_id, 'parent_task_id', t.parent_task_id,
    'assignee', app.person_json(t.primary_assignee_id), 'reviewer', app.person_json(t.reviewer_id),
    'submitted_by', app.person_json(auth.uid()),
    'labels', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name) order by l.name, l.id)
                        from public.task_labels tl join public.labels l on l.id = tl.label_id where tl.task_id = t.id), '[]'::jsonb),
    'collaborators', coalesce((select jsonb_agg(app.person_json(c.profile_id) order by c.profile_id)
                               from public.task_collaborators c where c.task_id = t.id), '[]'::jsonb),
    'checklist', coalesce((select jsonb_agg(jsonb_build_object('title', i.title, 'done', i.is_done) order by i.position, i.id)
                           from public.task_checklist_items i where i.task_id = t.id), '[]'::jsonb),
    'subtasks', jsonb_build_object(
      'total', (select count(*) from public.tasks c where c.parent_task_id = t.id and c.archived_at is null),
      'required_open', (select count(*) from public.tasks c where c.parent_task_id = t.id and c.is_required
                          and c.archived_at is null and not app.task_counts_complete(c.id))))
  from public.tasks t where t.id = p_task;
$$;"""))
helpers.append(("app.can_act_on_task(public.tasks)", """
-- Who may move a task today (same test as transition_task / update_task).
create function app.can_act_on_task(p_task public.tasks)
returns boolean language sql stable security invoker set search_path = '' as $$
  select p_task.primary_assignee_id = auth.uid() or app.has_permission('tasks.manage.project')
      or app.is_team_approver(app.primary_team(p_task.primary_assignee_id), auth.uid());
$$;"""))
helpers.append(("app.can_decide_task(public.tasks)", """
-- decide_task eligibility. Unchanged, except that a named reviewer of a
-- project task must still be an active member of that project.
create function app.can_decide_task(p_task public.tasks)
returns boolean language sql stable security invoker set search_path = '' as $$
  select case
    when p_task.reviewer_id is not null then
      (p_task.reviewer_id = auth.uid() and (p_task.project_id is null or exists (
        select 1 from public.project_members m
        where m.project_id = p_task.project_id and m.profile_id = auth.uid() and m.removed_at is null)))
      or app.is_super_admin(auth.uid())
    when p_task.project_id is null then app.is_team_approver(app.primary_team(p_task.primary_assignee_id), auth.uid()) or app.is_super_admin(auth.uid())
    else app.is_super_admin(auth.uid()) or exists (select 1 from public.project_members m
      where m.project_id = p_task.project_id and m.profile_id = auth.uid() and m.removed_at is null and m.member_role in ('manager', 'reviewer'))
  end;
$$;"""))
helpers.append(("app.workflow_status(uuid, text)", """
-- First active status of a category in the workflow of a status; null if none.
create function app.workflow_status(p_any_status uuid, p_category text)
returns uuid language sql stable security invoker set search_path = '' as $$
  select s.id from public.workflow_statuses s
  where s.workflow_id = (select workflow_id from public.workflow_statuses where id = p_any_status)
    and s.category = p_category and s.is_active
  order by s.position, s.id limit 1;
$$;"""))
helpers.append(("app.open_round(uuid)", """
-- The undecided round of a task, locked. Callers hold the task row lock.
create function app.open_round(p_task uuid)
returns uuid language sql volatile security invoker set search_path = '' as $$
  select r.id from public.task_review_rounds r
  where r.task_id = p_task and not exists (select 1 from public.task_reviews v where v.round_id = r.id)
  order by r.round_number desc limit 1
  for update;
$$;"""))
# Created before every SQL-language function that calls them: a LANGUAGE sql
# body is validated at CREATE time (check_function_bodies), so the callee must exist.
helpers.append(("app.task_is_unresolved(uuid)", """
-- Unresolved work (proposal §7.6): not archived, not completed, and not Final
-- Rejected. A blocked task IS unresolved: it keeps its status and returns to the
-- same column when the flag is cleared. Used where pending work must still count
-- although it is not open for work right now: member removal (B3), the blocked
-- counts, carrying a sprint's remainder over, reaching a milestone.
create function app.task_is_unresolved(p_task uuid)
returns boolean language sql stable security invoker set search_path = '' as $$
  select exists (
    select 1 from public.tasks t join public.workflow_statuses s on s.id = t.status_id
    where t.id = p_task and t.archived_at is null and s.category <> 'rejected'
  ) and not app.task_counts_complete(p_task);
$$;"""))
helpers.append(("app.task_is_open(uuid)", """
-- Open for work (proposal §7.6, v8): unresolved and not blocked. False for an
-- archived, completed, Final Rejected or blocked task. Neither Final Rejected nor
-- blocked is a success: app.task_counts_complete keeps returning false for them.
-- Not used alone for member removal (that is app.task_is_unresolved).
create function app.task_is_open(p_task uuid)
returns boolean language sql stable security invoker set search_path = '' as $$
  select app.task_is_unresolved(p_task)
     and exists (select 1 from public.tasks t where t.id = p_task and t.blocked_at is null);
$$;"""))
helpers.append(("app.open_tasks_of_member(uuid, uuid, integer)", """
-- B3: unresolved tasks of a project in which the member is assignee, named
-- reviewer or collaborator, with the roles; only titles the caller may see.
-- Blocked tasks count (they are still pending work); Final Rejected ones do not.
create function app.open_tasks_of_member(p_project uuid, p_profile uuid, p_limit integer)
returns jsonb language sql stable security invoker set search_path = '' as $$
  with open_tasks as (
    select t.id, t.title, s.name as status, app.can_view_task(t.id) as visible,
      array_remove(array[
        case when t.primary_assignee_id = p_profile then 'assignee' end,
        case when t.reviewer_id = p_profile then 'reviewer' end,
        case when exists (select 1 from public.task_collaborators c where c.task_id = t.id and c.profile_id = p_profile) then 'collaborator' end
      ], null) as roles
    from public.tasks t join public.workflow_statuses s on s.id = t.status_id
    where t.project_id = p_project and t.archived_at is null and app.task_is_unresolved(t.id)
      and (t.primary_assignee_id = p_profile or t.reviewer_id = p_profile
           or exists (select 1 from public.task_collaborators c where c.task_id = t.id and c.profile_id = p_profile)))
  select jsonb_build_object(
    'total', (select count(*) from open_tasks),
    'hidden', (select count(*) from open_tasks where not visible),
    'by_role', jsonb_build_object(
      'assignee', (select count(*) from open_tasks where 'assignee' = any (roles)),
      'reviewer', (select count(*) from open_tasks where 'reviewer' = any (roles)),
      'collaborator', (select count(*) from open_tasks where 'collaborator' = any (roles))),
    'tasks', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'title', x.title, 'status', x.status, 'roles', to_jsonb(x.roles))
                                        order by x.title, x.id)
                       from (select * from open_tasks where visible order by title, id limit p_limit) x), '[]'::jsonb));
$$;"""))
helpers.append(("app.apply_review_changes(public.tasks, uuid, jsonb)", """
-- Reviewer edits before a decision. Called only by review_update_task and
-- decide_task, which hold the task and round locks. Never touches the status.
create function app.apply_review_changes(p_task public.tasks, p_round uuid, p_changes jsonb)
returns void language plpgsql security invoker set search_path = '' as $$
declare
  v_key text;
  v_people boolean := app.has_permission('tasks.manage.project') or app.is_super_admin(auth.uid()) or exists (
    select 1 from public.project_members m where m.project_id = p_task.project_id and m.profile_id = auth.uid()
      and m.removed_at is null and m.member_role = 'manager');
  v_item text;
  v_old_collaborators jsonb := (select coalesce(jsonb_agg(profile_id order by profile_id), '[]'::jsonb)
                                from public.task_collaborators where task_id = p_task.id);
begin
  if p_changes is null or p_changes = '{}'::jsonb then return; end if;
  if jsonb_typeof(p_changes) <> 'object' then raise exception 'invalid_changes'; end if;
  for v_key in select jsonb_object_keys(p_changes) loop
    if v_key not in ('title', 'description', 'priority', 'due_at', 'labels', 'assignee_id', 'collaborator_ids') then
      raise exception 'field_forbidden';
    end if;
    if v_key in ('assignee_id', 'collaborator_ids') and not v_people then raise exception 'field_forbidden'; end if;
    if v_key in ('labels', 'collaborator_ids') and p_task.project_id is null then raise exception 'field_forbidden'; end if;
  end loop;
  if p_changes ? 'priority' and (p_changes ->> 'priority') not in ('low', 'medium', 'high', 'critical') then raise exception 'invalid_priority'; end if;
  if p_changes ? 'title' and char_length(trim(coalesce(p_changes ->> 'title', ''))) = 0 then raise exception 'invalid_name'; end if;
  if p_changes ? 'assignee_id' then
    if p_task.project_id is null then
      if app.personal_assign_scope((p_changes ->> 'assignee_id')::uuid) is null then raise exception 'assignee_out_of_scope'; end if;
      perform app.require_active_profile((p_changes ->> 'assignee_id')::uuid, 'assignee_inactive');
    else
      perform app.require_active_member(p_task.project_id, (p_changes ->> 'assignee_id')::uuid, 'assignee_not_member');
    end if;
  end if;
  if p_changes ? 'labels' then
    for v_item in select jsonb_array_elements_text(p_changes -> 'labels') loop
      if not exists (select 1 from public.labels l where l.id = v_item::uuid and l.project_id = p_task.project_id and l.is_active) then
        raise exception 'invalid_label';
      end if;
    end loop;
  end if;
  if p_changes ? 'collaborator_ids' then
    for v_item in select jsonb_array_elements_text(p_changes -> 'collaborator_ids') loop
      perform app.require_active_member(p_task.project_id, v_item::uuid, 'collaborator_not_member');
    end loop;
  end if;

  insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)
  select p_task.workspace_id, p_task.id, auth.uid(), 'task.review_edit',
         jsonb_build_object('field', f.key, 'from', f.old_value, 'to', f.new_value, 'context', 'review', 'round_id', p_round)
  from (values
    ('title', to_jsonb(p_task.title), p_changes -> 'title'),
    ('description', to_jsonb(p_task.description), p_changes -> 'description'),
    ('priority', to_jsonb(p_task.priority), p_changes -> 'priority'),
    ('due_at', to_jsonb(p_task.due_at), p_changes -> 'due_at'),
    ('assignee_id', to_jsonb(p_task.primary_assignee_id), p_changes -> 'assignee_id'),
    ('labels', (select coalesce(jsonb_agg(label_id order by label_id), '[]'::jsonb) from public.task_labels where task_id = p_task.id), p_changes -> 'labels'),
    ('collaborator_ids', (select coalesce(jsonb_agg(profile_id order by profile_id), '[]'::jsonb) from public.task_collaborators where task_id = p_task.id), p_changes -> 'collaborator_ids')
  ) as f(key, old_value, new_value)
  where p_changes ? f.key and f.old_value is distinct from f.new_value;

  update public.tasks set
    title = case when p_changes ? 'title' then trim(p_changes ->> 'title') else title end,
    description = case when p_changes ? 'description' then coalesce(p_changes ->> 'description', '') else description end,
    priority = case when p_changes ? 'priority' then p_changes ->> 'priority' else priority end,
    due_at = case when p_changes ? 'due_at' then (p_changes ->> 'due_at')::timestamptz else due_at end,
    primary_assignee_id = case when p_changes ? 'assignee_id' then (p_changes ->> 'assignee_id')::uuid else primary_assignee_id end
  where id = p_task.id;

  if p_changes ? 'labels' then
    delete from public.task_labels where task_id = p_task.id
      and label_id not in (select x::uuid from jsonb_array_elements_text(p_changes -> 'labels') x);
    insert into public.task_labels (task_id, label_id)
    select p_task.id, x::uuid from jsonb_array_elements_text(p_changes -> 'labels') x on conflict do nothing;
  end if;
  if p_changes ? 'collaborator_ids' then
    delete from public.task_collaborators where task_id = p_task.id
      and profile_id not in (select x::uuid from jsonb_array_elements_text(p_changes -> 'collaborator_ids') x);
    insert into public.task_collaborators (task_id, profile_id)
    select p_task.id, x::uuid from jsonb_array_elements_text(p_changes -> 'collaborator_ids') x on conflict do nothing;
    if v_old_collaborators is distinct from (select coalesce(jsonb_agg(profile_id order by profile_id), '[]'::jsonb)
                                              from public.task_collaborators where task_id = p_task.id) then
      perform app.audit(p_task.workspace_id, auth.uid(), 'task.collaborator_set', 'task', p_task.id, jsonb_build_object(
        'from', v_old_collaborators, 'to', p_changes -> 'collaborator_ids', 'context', 'review', 'round_id', p_round));
    end if;
  end if;
end;
$$;"""))
helpers.append(("app.protect_review_round()", """
create function app.protect_review_round()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
  if (new.id, new.task_id, new.round_number, new.opened_at, new.submitted_by, new.submitted_by_source, new.submitted_by_name,
      new.snapshot, new.snapshot_version, new.snapshot_status)
     is distinct from
     (old.id, old.task_id, old.round_number, old.opened_at, old.submitted_by, old.submitted_by_source, old.submitted_by_name,
      old.snapshot, old.snapshot_version, old.snapshot_status) then
    raise exception 'round_immutable';
  end if;
  return new;
end;
$$;"""))
helpers.append(("app.reject_change()", """
create function app.reject_change()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
  raise exception 'immutable_row';
end;
$$;"""))
helpers.append(("app.require_revision_request()", """
-- B1 at the data level: a revision decision has exactly one structured request at commit.
create function app.require_revision_request()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
  if new.decision = 'revision_requested' and not exists (select 1 from public.task_revision_requests where review_id = new.id) then
    raise exception 'revision_request_missing';
  end if;
  return null;
end;
$$;"""))
helpers.append(("app.check_revision_request()", """
-- A revision request may only point at a revision_requested decision.
create function app.check_revision_request()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
  if not exists (select 1 from public.task_reviews v where v.id = new.review_id and v.round_id = new.round_id
                 and v.decision = 'revision_requested') then
    raise exception 'revision_request_mismatch';
  end if;
  return new;
end;
$$;"""))

add("""
-- -----------------------------------------------------------------------------
-- 3. Internal helpers. SECURITY INVOKER: they run with the rights of the
--    SECURITY DEFINER RPC that calls them; EXECUTE is revoked from every client
--    role in §11, so only those RPCs (owner postgres) can call them.
-- -----------------------------------------------------------------------------""")
for name, body in helpers:
    NEW_INTERNAL.append(name)
    add(body)

# ----------------------------------------------------------------------------- 4. history backfill
add("""
-- -----------------------------------------------------------------------------
-- 4. Legacy history (before the immutability triggers exist).
--    Snapshots of old rounds cannot be rebuilt from a reliable source: they stay
--    snapshot_status = 'unavailable'. The submitter id is taken from the
--    transition event when one exists (source 'activity_event'); no current
--    profile name is written as a historical name.
-- -----------------------------------------------------------------------------
update public.task_review_rounds round
  set submitted_by = src.actor_id, submitted_by_source = 'activity_event'
from (
  select r.id, (
    select ev.actor_id from public.task_activity_events ev
    join public.workflow_statuses s on s.id = (ev.metadata ->> 'to')::uuid
    where ev.task_id = r.task_id and ev.action = 'task.transition' and s.category = 'in_review'
      and ev.actor_id is not null and ev.created_at <= r.opened_at + interval '1 second'
    order by ev.created_at desc limit 1) as actor_id
  from public.task_review_rounds r) src
where src.id = round.id and src.actor_id is not null;

-- Interim two-part reasons and free-text legacy reasons (none in the reviewed data).
insert into public.task_revision_requests
  (task_id, round_id, review_id, what_to_change, reason, created_by, created_by_name, name_source, origin, created_at)
select round.task_id, round.id, review.id,
  case when review.reason like 'اصلاح موردنیاز:%' and position(E'\\nعلت:' in review.reason) > 0
       then trim(substring(review.reason from char_length('اصلاح موردنیاز:') + 1
                           for position(E'\\nعلت:' in review.reason) - char_length('اصلاح موردنیاز:') - 1))
       else trim(review.reason) end,
  case when review.reason like 'اصلاح موردنیاز:%' and position(E'\\nعلت:' in review.reason) > 0
       then trim(substring(review.reason from position(E'\\nعلت:' in review.reason) + char_length(E'\\nعلت:')))
       else 'ثبت‌شده پیش از تفکیک فیلدها' end,
  review.reviewer_id, null, 'unavailable',
  case when review.reason like 'اصلاح موردنیاز:%' and position(E'\\nعلت:' in review.reason) > 0 then 'legacy_two_part' else 'legacy_free_text' end,
  review.created_at
from public.task_reviews review join public.task_review_rounds round on round.id = review.round_id
where review.decision = 'revision_requested';
""")

# ----------------------------------------------------------------------------- 5. report + moves
add(f"""
-- -----------------------------------------------------------------------------
-- 5. Report (never changed) and deterministic moves
-- -----------------------------------------------------------------------------
insert into public.workflow_status_migration_report (kind, task_id, detail)
select decision, task_id, jsonb_build_object('from_key', from_key) from migration_plan where decision not in ('move', 'keep');
insert into public.workflow_status_migration_report (kind, task_id)
select kind, task_id from migration_integrity;

create temporary table moves on commit drop as
select p.task_id, p.from_status_id, p.blocked_set,
       case when p.blocked_set then clock_timestamp() end as blocked_at_set,
       (select st.id from public.workflow_statuses st where st.workflow_id = p.workflow_id and st.key = p.to_key) as to_status_id
from migration_plan p where p.decision = 'move';

insert into public.workflow_status_migration_log (task_id, from_status_id, to_status_id, blocked_set, blocked_at_set)
select task_id, from_status_id, to_status_id, blocked_set, blocked_at_set from moves;

update public.tasks t set status_id = m.to_status_id,
  blocked_at = case when m.blocked_set then m.blocked_at_set else t.blocked_at end,
  blocked_reason = case when m.blocked_set then 'انتقال خودکار از وضعیت مسدود' else t.blocked_reason end
from moves m where m.task_id = t.id;

insert into public.task_block_events (task_id, action, reason, status_id, actor_id, actor_name)
select task_id, 'blocked', 'انتقال خودکار از وضعیت مسدود', to_status_id, null, null from moves where blocked_set;

insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)
select t.workspace_id, m.task_id, null, 'task.migrated', jsonb_build_object('from', m.from_status_id, 'to', m.to_status_id, 'reason', 'workflow_d1_d7')
from moves m join public.tasks t on t.id = m.task_id;

-- -----------------------------------------------------------------------------
-- 6. Default workflows only: rename, reorder, retire, add transitions
-- -----------------------------------------------------------------------------
create temporary table default_status on commit drop as
select s.* from public.workflow_statuses s
where s.workflow_id in (select workflow_id::uuid from (values {', '.join('(' + q(w) + ')' for w in DEFAULT_WORKFLOWS)}) v(workflow_id));

insert into public.workflow_status_changes (status_id, before, after)
select s.id,
  jsonb_build_object('name', s.name, 'position', s.position, 'is_active', s.is_active),
  jsonb_build_object(
    'name', case s.key when 'backlog' then 'در صف انجام' when 'rejected' then 'رد نهایی' else s.name end,
    'position', case s.key when 'backlog' then 1 when 'in_review' then 2 when 'done' then 3 when 'rejected' then 4 else s.position + 100 end,
    'is_active', s.key not in {RETIRED!r})
from default_status s;

update public.workflow_statuses s set
  name = c.after ->> 'name',
  position = (c.after ->> 'position')::integer,
  is_active = (c.after ->> 'is_active')::boolean
from public.workflow_status_changes c where c.status_id = s.id;

with wanted (from_key, to_key) as (values
    {values(NEW_TRANSITIONS)}
),
inserted as (
  insert into public.workflow_transitions (workflow_id, from_status_id, to_status_id)
  select f.workflow_id, f.id, t.id
  from wanted w
  join default_status f on f.key = w.from_key
  join default_status t on t.key = w.to_key and t.workflow_id = f.workflow_id
  on conflict (from_status_id, to_status_id) do nothing
  returning id, workflow_id, from_status_id, to_status_id)
insert into public.workflow_migration_added_transitions (transition_id, workflow_id, from_status_id, to_status_id)
select id, workflow_id, from_status_id, to_status_id from inserted;
""")

# ----------------------------------------------------------------------------- 7. new RPCs
rpcs = []
rpcs.append(("public.project_member_directory(uuid)", """
-- D4. Restricted directory of the project's active members. profiles RLS unchanged.
create function public.project_member_directory(p_project uuid)
returns table (profile_id uuid, first_name text, last_name text, team_name text, member_role text, is_self boolean)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform app.require_active();
  if not exists (select 1 from public.projects pr where pr.id = p_project and pr.workspace_id = app.current_workspace())
     or not (app.has_permission('projects.view.all') or exists (
       select 1 from public.project_members m where m.project_id = p_project and m.profile_id = auth.uid() and m.removed_at is null)) then
    raise exception 'forbidden';
  end if;
  return query
    select p.id, p.first_name, p.last_name, tm.name, m.member_role, p.id = auth.uid()
    from public.project_members m join public.profiles p on p.id = m.profile_id
    left join public.teams tm on tm.id = app.primary_team(p.id)
    where m.project_id = p_project and m.removed_at is null and p.status = 'active'
    order by p.first_name, p.last_name, p.id;
end;
$$;"""))
rpcs.append(("public.project_member_open_tasks(uuid, uuid, integer)", """
-- B3. Full, paged list of unresolved tasks (blocked included, Final Rejected
-- not) that stop a member's removal, with roles.
create function public.project_member_open_tasks(p_project uuid, p_profile uuid, p_page integer default 0)
returns table (task_id uuid, title text, status_name text, roles text[], total bigint)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform app.require_active();
  if not app.can_edit_project(p_project) then raise exception 'forbidden'; end if;
  return query
    select t.id, t.title, s.name,
      array_remove(array[
        case when t.primary_assignee_id = p_profile then 'assignee' end,
        case when t.reviewer_id = p_profile then 'reviewer' end,
        case when exists (select 1 from public.task_collaborators c where c.task_id = t.id and c.profile_id = p_profile) then 'collaborator' end
      ], null),
      count(*) over ()
    from public.tasks t join public.workflow_statuses s on s.id = t.status_id
    where t.project_id = p_project and t.archived_at is null and app.task_is_unresolved(t.id) and app.can_view_task(t.id)
      and (t.primary_assignee_id = p_profile or t.reviewer_id = p_profile
           or exists (select 1 from public.task_collaborators c where c.task_id = t.id and c.profile_id = p_profile))
    order by t.title, t.id limit 50 offset greatest(coalesce(p_page, 0), 0) * 50;
end;
$$;"""))

# submission keeps the review notifications that transition_task sent before (B2 moved them here)
notify_block = dump('public.transition_task')
start = notify_block.index("    if v_task.reviewer_id is not null then\n      if v_task.reviewer_id is distinct from auth.uid() then")
end = notify_block.index("    end if;\n  end if;\n\n  insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)\n  values (v_task.workspace_id, p_task, auth.uid(), 'task.transition'")
REVIEW_NOTIFY = notify_block[start:end] + "    end if;\n"
rpcs.append(("public.submit_task_for_review(uuid)", f"""
-- B2. The only way into review. Creates version vN with its real snapshot.
create function public.submit_task_for_review(p_task uuid)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_task public.tasks%rowtype;
  v_category text;
  v_review uuid;
  v_round integer;
  v_person uuid;
begin
  perform app.require_active();
  select * into v_task from public.tasks where id = p_task for update;
  if not found or not app.can_view_task(p_task) or not app.can_act_on_task(v_task) then raise exception 'forbidden'; end if;
  if v_task.archived_at is not null then raise exception 'archived'; end if;
  if not v_task.approval_required then raise exception 'not_required'; end if;
  if v_task.blocked_at is not null then raise exception 'task_blocked'; end if;
  select category into v_category from public.workflow_statuses where id = v_task.status_id;
  if v_category <> 'backlog' then raise exception 'invalid_state'; end if;
  if app.open_round(p_task) is not null then raise exception 'already_submitted'; end if;
  v_review := app.workflow_status(v_task.status_id, 'in_review');
  if v_review is null then raise exception 'workflow_incomplete'; end if;

  select coalesce(max(round_number), 0) + 1 into v_round from public.task_review_rounds where task_id = p_task;
  insert into public.task_review_rounds
    (task_id, round_number, submitted_by, submitted_by_source, submitted_by_name, snapshot, snapshot_version, snapshot_status)
  values (p_task, v_round, auth.uid(), 'submission', coalesce(app.person_label(auth.uid()), '—'), app.task_snapshot(p_task), 1, 'captured');
  update public.tasks set status_id = v_review, approval_state = 'pending' where id = p_task;

{REVIEW_NOTIFY.replace(chr(10) + '    ', chr(10) + '  ').removeprefix('  ')}
  insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)
  values (v_task.workspace_id, p_task, auth.uid(), 'task.submit', jsonb_build_object('version', v_round, 'to', v_review));
  perform app.audit(v_task.workspace_id, auth.uid(), 'task.submit', 'task', p_task, jsonb_build_object('version', v_round));
  return v_round;
end;
$$;"""))
rpcs.append(("public.review_update_task(uuid, uuid, jsonb)", """
create function public.review_update_task(p_task uuid, p_round uuid, p_changes jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_task public.tasks%rowtype;
  v_open uuid;
begin
  perform app.require_active();
  if p_round is null then raise exception 'round_required'; end if;
  select * into v_task from public.tasks where id = p_task for update;
  if not found or not app.can_view_task(p_task) or not app.can_decide_task(v_task) then raise exception 'forbidden'; end if;
  if (select category from public.workflow_statuses where id = v_task.status_id) <> 'in_review'
     or not v_task.approval_required or v_task.approval_state <> 'pending' then
    raise exception 'invalid_state';
  end if;
  -- A blocked task waits: the same round continues after clear_task_blocked.
  if v_task.blocked_at is not null then raise exception 'task_blocked'; end if;
  v_open := app.open_round(p_task);
  if v_open is null then raise exception 'not_submitted'; end if;
  if p_round <> v_open then raise exception 'stale_round'; end if;
  perform app.apply_review_changes(v_task, v_open, p_changes);
end;
$$;"""))

old_decide = dump('public.decide_task')
dn_start = old_decide.index("  v_title := case p_decision")
dn_end = old_decide.index("  insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)\n  values (v_task.workspace_id, p_task, auth.uid(), 'task.review'")
DECIDE_NOTIFY = old_decide[dn_start:dn_end]
rpcs.append(("public.decide_task(uuid, text, uuid, text, text, jsonb, text)", f"""
-- Replaces decide_task(uuid, text, text) (dropped below). p_round is required.
-- p_override_reason: approving a parent whose required subtasks are not
-- complete; managers only; separate from the review reason.
create function public.decide_task(
  p_task uuid, p_decision text, p_round uuid,
  p_reason text default null, p_what text default null, p_changes jsonb default null,
  p_override_reason text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_task public.tasks%rowtype;
  v_round uuid;
  v_review uuid;
  v_status uuid;
  v_name text := app.person_label(auth.uid());
  v_title text;
  v_person uuid;
begin
  perform app.require_active();
  if p_decision not in ('approved', 'revision_requested', 'rejected') then raise exception 'invalid_decision'; end if;
  if p_round is null then raise exception 'round_required'; end if;
  if p_decision <> 'approved' and char_length(trim(coalesce(p_reason, ''))) = 0 then raise exception 'reason_required'; end if;
  if p_decision = 'revision_requested' and char_length(trim(coalesce(p_what, ''))) = 0 then raise exception 'what_required'; end if;

  -- (1) serialise every review action on this task
  select * into v_task from public.tasks where id = p_task for update;
  if not found then raise exception 'not_found'; end if;
  if not app.can_view_task(p_task) or not app.can_decide_task(v_task) then raise exception 'forbidden'; end if;
  if not v_task.approval_required then raise exception 'not_required'; end if;

  -- (2) re-validate under the lock: the round the reviewer saw is the open one
  v_round := app.open_round(p_task);
  if v_round is null then
    if exists (select 1 from public.task_review_rounds where id = p_round and task_id = p_task) then
      raise exception 'stale_round';
    end if;
    raise exception 'not_submitted';
  end if;
  if p_round <> v_round then raise exception 'stale_round'; end if;
  if (select category from public.workflow_statuses where id = v_task.status_id) <> 'in_review'
     or v_task.approval_state <> 'pending' then
    raise exception 'invalid_state';
  end if;
  -- A blocked task waits: the same round continues after clear_task_blocked.
  if v_task.blocked_at is not null then raise exception 'task_blocked'; end if;
  -- Approving completes the task: the same required-subtask rule as transition_task to done.
  -- Required children are share-locked first, so a concurrent reopen of a child
  -- (transition_task / decide_task lock the child FOR UPDATE) is serialised and
  -- the check below reads committed child states.
  if p_decision = 'approved' then
    perform 1 from public.tasks where parent_task_id = p_task and is_required and archived_at is null for share;
  end if;
  if p_decision = 'approved' and app.task_children_block_done(p_task) then
    if p_override_reason is null or char_length(trim(p_override_reason)) = 0 then
      raise exception 'subtasks_incomplete';
    end if;
    -- Safe default (proposal §7.5): tasks.manage.project or super admin; tasks.view.all alone is not enough.
    if not (app.has_permission('tasks.manage.project') or app.is_super_admin(auth.uid())) then
      raise exception 'forbidden';
    end if;
  end if;
  v_status := app.workflow_status(v_task.status_id,
    case p_decision when 'approved' then 'done' when 'revision_requested' then 'backlog' else 'rejected' end);
  if v_status is null then raise exception 'workflow_incomplete'; end if;

  perform app.apply_review_changes(v_task, v_round, p_changes);

  -- (3) unique round_id: the first valid decision wins; the loser rolls back entirely
  begin
    insert into public.task_reviews (round_id, reviewer_id, decision, reason, reviewer_name, reviewer_name_source)
    values (v_round, auth.uid(), p_decision, nullif(trim(coalesce(p_reason, '')), ''), coalesce(v_name, '—'), 'decision')
    returning id into v_review;
  exception when unique_violation then
    raise exception 'already_decided';
  end;

  if p_decision = 'revision_requested' then
    insert into public.task_revision_requests
      (task_id, round_id, review_id, what_to_change, reason, created_by, created_by_name, name_source, origin)
    values (p_task, v_round, v_review, trim(p_what), trim(p_reason), auth.uid(), coalesce(v_name, '—'), 'decision', 'decision');
  end if;

  -- Override recorded exactly as on the transition_task path (audit + activity).
  if p_decision = 'approved' and app.task_children_block_done(p_task) then
    perform app.audit(v_task.workspace_id, auth.uid(), 'task.override_subtasks', 'task', p_task, jsonb_build_object('reason', trim(p_override_reason)));
    insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)
    values (v_task.workspace_id, p_task, auth.uid(), 'task.override', jsonb_build_object('reason', trim(p_override_reason)));
  end if;

  update public.tasks set
    approval_state = case p_decision when 'approved' then 'approved' when 'revision_requested' then 'changes_requested' else 'rejected' end,
    status_id = v_status
  where id = p_task;

  if p_decision = 'approved' and v_task.parent_task_id is not null then
    insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)
    values (v_task.workspace_id, v_task.parent_task_id, auth.uid(), 'task.subtask_done', jsonb_build_object('child', p_task));
  end if;

{DECIDE_NOTIFY}  insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)
  values (v_task.workspace_id, p_task, auth.uid(), 'task.review', jsonb_build_object('decision', p_decision, 'round_id', v_round));
  perform app.audit(v_task.workspace_id, auth.uid(), 'task.review', 'task', p_task, jsonb_build_object('decision', p_decision, 'round_id', v_round));
end;
$$;"""))
rpcs.append(("public.set_task_blocked(uuid, text)", """
-- D2. A flag: the status never changes.
create function public.set_task_blocked(p_task uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_task public.tasks%rowtype;
begin
  perform app.require_active();
  if char_length(trim(coalesce(p_reason, ''))) = 0 then raise exception 'reason_required'; end if;
  select * into v_task from public.tasks where id = p_task for update;
  if not found or not app.can_view_task(p_task) or not app.can_act_on_task(v_task) then raise exception 'forbidden'; end if;
  if (select category from public.workflow_statuses where id = v_task.status_id) in ('in_review', 'done', 'approved', 'rejected') then
    raise exception 'invalid_state';
  end if;
  if v_task.blocked_at is not null then raise exception 'already_blocked'; end if;
  update public.tasks set blocked_at = clock_timestamp(), blocked_reason = trim(p_reason), blocked_by = auth.uid() where id = p_task;
  insert into public.task_block_events (task_id, action, reason, status_id, actor_id, actor_name)
  values (p_task, 'blocked', trim(p_reason), v_task.status_id, auth.uid(), app.person_label(auth.uid()));
end;
$$;"""))
rpcs.append(("public.clear_task_blocked(uuid, text)", """
create function public.clear_task_blocked(p_task uuid, p_note text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare v_task public.tasks%rowtype;
begin
  perform app.require_active();
  select * into v_task from public.tasks where id = p_task for update;
  if not found or not app.can_view_task(p_task) or not app.can_act_on_task(v_task) then raise exception 'forbidden'; end if;
  if v_task.blocked_at is null then raise exception 'not_blocked'; end if;
  -- Blocking never changed the status: the task is back in the same column.
  -- Rounds, version numbers, approval state and history are not touched.
  update public.tasks set blocked_at = null, blocked_reason = null, blocked_by = null where id = p_task;
  insert into public.task_block_events (task_id, action, reason, status_id, actor_id, actor_name)
  values (p_task, 'unblocked', nullif(trim(coalesce(p_note, '')), ''), v_task.status_id, auth.uid(), app.person_label(auth.uid()));
end;
$$;"""))

add("""
-- -----------------------------------------------------------------------------
-- 7. New RPCs (SECURITY DEFINER; EXECUTE for authenticated only, §11)
-- -----------------------------------------------------------------------------
drop function public.decide_task(uuid, text, text);""")
for name, body in rpcs:
    NEW_PUBLIC.append(name)
    add(body)

# ----------------------------------------------------------------------------- 8. existing functions
add("""
-- -----------------------------------------------------------------------------
-- 8. Existing functions: current bodies with the reviewed edits only
-- -----------------------------------------------------------------------------""")

def existing(name: str, edits: list[tuple], drop_first: str | None = None):
    """Dump + exact patches. An edit (old, new, n) must match exactly n times.
    drop_first: the old signature, when the return type changes (CREATE OR
    REPLACE cannot change it); nothing depends on these functions (pg_depend)."""
    text = dump(name)
    for edit in edits:
        old, new = edit[0], edit[1]
        expected = edit[2] if len(edit) > 2 else 1
        found = text.count(old)
        if found != expected:
            raise SystemExit(f'{name}: expected {expected} matches, found {found}:\n{old[:200]}')
        text = text.replace(old, new)
    CHANGED.append(name)
    add('\n' + (f'drop function {drop_first};\n' if drop_first else '') + text)

existing('public.create_task', [
    ("""    select project_id into v_parent_project from public.tasks where id = p_parent;""",
     """    -- Share-lock the parent: a subtask cannot appear while the parent is being completed.
    select project_id into v_parent_project from public.tasks where id = p_parent for share;"""),
    ("""    select id into v_workflow from public.workflows
    where workspace_id = v_workspace and project_id is null;
    v_approval := coalesce(p_approval, false);""",
     """    perform app.require_active_profile(v_assignee, 'assignee_inactive');
    perform app.require_active_profile(p_reviewer, 'reviewer_inactive');
    select id into v_workflow from public.workflows
    where workspace_id = v_workspace and project_id is null;
    v_approval := coalesce(p_approval, false);"""),
    ("""    select id into v_workflow from public.workflows where project_id = p_project;
    select approval_required into v_approval from public.projects where id = p_project;""",
     """    perform app.require_active_member(p_project, v_assignee, 'assignee_not_member');
    perform app.require_active_member(p_project, p_reviewer, 'reviewer_not_member');
    select id into v_workflow from public.workflows where project_id = p_project;
    select approval_required into v_approval from public.projects where id = p_project;"""),
    ("""  values (v_workspace, v_id, auth.uid(), 'task.create', jsonb_build_object('assignee', v_assignee));""",
     """  values (v_workspace, v_id, auth.uid(), 'task.create',
          jsonb_build_object('assignee', v_assignee, 'on_behalf', v_assignee <> auth.uid(), 'created_by', auth.uid()));"""),
    ("""  perform app.audit(v_workspace, auth.uid(), 'task.create', 'task', v_id, '{}'::jsonb);""",
     """  perform app.audit(v_workspace, auth.uid(), 'task.create', 'task', v_id, '{}'::jsonb);
  if v_assignee <> auth.uid() then
    -- Created on behalf of someone else: who, for whom, under which scope.
    perform app.audit(v_workspace, auth.uid(), 'task.create_for', 'task', v_id, jsonb_build_object(
      'assignee', v_assignee, 'created_by', auth.uid(), 'project', p_project,
      'scope', case when p_project is null then app.personal_assign_scope(v_assignee) else 'project' end));
  end if;"""),
])

existing('public.update_task', [
    ("""  v_state := v_task.approval_state;""",
     """  -- The approval policy cannot change while a version waits for a decision.
  if p_approval is distinct from v_task.approval_required and app.open_round(p_task) is not null then
    raise exception 'invalid_state';
  end if;
  if v_task.primary_assignee_id is distinct from p_assignee then
    if v_task.project_id is null then
      if app.personal_assign_scope(p_assignee) is null then
        raise exception 'assignee_out_of_scope';
      end if;
      perform app.require_active_profile(p_assignee, 'assignee_inactive');
      perform app.audit(v_task.workspace_id, auth.uid(), 'task.reassign_for', 'task', p_task, jsonb_build_object(
        'from', v_task.primary_assignee_id, 'to', p_assignee, 'scope', app.personal_assign_scope(p_assignee)));
    else
      perform app.require_active_member(v_task.project_id, p_assignee, 'assignee_not_member');
      perform app.audit(v_task.workspace_id, auth.uid(), 'task.reassign', 'task', p_task, jsonb_build_object(
        'from', v_task.primary_assignee_id, 'to', p_assignee));
    end if;
  end if;
  if v_task.reviewer_id is distinct from p_reviewer then
    if v_task.project_id is null then
      perform app.require_active_profile(p_reviewer, 'reviewer_inactive');
    else
      perform app.require_active_member(v_task.project_id, p_reviewer, 'reviewer_not_member');
    end if;
    perform app.audit(v_task.workspace_id, auth.uid(), 'task.reviewer_change', 'task', p_task, jsonb_build_object(
      'from', v_task.reviewer_id, 'to', p_reviewer));
  end if;

  v_state := v_task.approval_state;"""),
])

tt = dump('public.transition_task')
cut_start = tt.index("  if v_category = 'in_review' and v_task.approval_required then")
cut_end = tt.index("  insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)\n  values (v_task.workspace_id, p_task, auth.uid(), 'task.transition'")
existing('public.transition_task', [
    ("""  if v_category = 'done' and app.task_children_block_done(p_task) then""",
     """  -- Serialise with a concurrent reopen of a required child (see decide_task).
  if v_category = 'done' then
    perform 1 from public.tasks where parent_task_id = p_task and is_required and archived_at is null for share;
  end if;
  if v_category = 'done' and app.task_children_block_done(p_task) then"""),
    ("""    if not (app.has_permission('tasks.manage.project') or app.has_permission('tasks.view.all')) then
      raise exception 'forbidden';
    end if;
    perform app.audit(v_task.workspace_id, auth.uid(), 'task.override_subtasks'""",
     """    -- Safe default (proposal §7.5): tasks.manage.project or super admin; tasks.view.all alone is not enough.
    if not (app.has_permission('tasks.manage.project') or app.is_super_admin(auth.uid())) then
      raise exception 'forbidden';
    end if;
    perform app.audit(v_task.workspace_id, auth.uid(), 'task.override_subtasks'"""),
    (tt[cut_start:cut_end], "  -- Entering review is submit_task_for_review only (B2); its round and notifications moved there.\n\n"),
    ("""  v_from := v_task.status_id;""",
     """  -- Leaving review is a reviewer decision only (decide_task).
  if v_current = 'in_review' then
    raise exception 'use_decide';
  end if;

  v_from := v_task.status_id;"""),
    ("""  if not coalesce(v_active, false) then
    raise exception 'status_inactive';
  end if;""",
     """  if not coalesce(v_active, false) then
    raise exception 'status_inactive';
  end if;
  if v_category = 'in_review' then
    raise exception 'use_submit';
  end if;
  -- Final Rejected leaves only through reopening, and only to backlog.
  if v_current = 'rejected' and v_category <> 'backlog' then
    raise exception 'reopen_backlog_only';
  end if;
  if v_task.blocked_at is not null and v_category in ('done', 'approved') then
    raise exception 'task_blocked';
  end if;"""),
    ("""  v_round integer;
  v_person uuid;
""", ""),
    ("""  update public.tasks set status_id = p_status where id = p_task;""",
     """  update public.tasks set status_id = p_status where id = p_task;
  -- Reopening a Final Rejected task (proposal §7.7): a new cycle ("not sent yet",
  -- not "rejected"), recorded as its own event and audit entry. Earlier rounds,
  -- decisions and versions stay as they are; the next submission is vN+1.
  if v_current = 'rejected' then
    if v_task.approval_required then
      update public.tasks set approval_state = 'pending' where id = p_task;
    end if;
    insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)
    values (v_task.workspace_id, p_task, auth.uid(), 'task.reopen', jsonb_build_object('from', v_from, 'to', p_status));
    perform app.audit(v_task.workspace_id, auth.uid(), 'task.reopen', 'task', p_task, jsonb_build_object('from', v_from, 'to', p_status));
  end if;"""),
])

existing('public.add_task_collaborator', [
    ("""  v_inserted integer;
begin""", """  v_inserted integer;
  v_assignee uuid;
begin"""),
    ("""  select project_id, workspace_id into v_project, v_workspace
  from public.tasks where id = p_task;""",
     """  -- Lock the task row: serialised with submit / review / decide (snapshot).
  select project_id, workspace_id, primary_assignee_id into v_project, v_workspace, v_assignee
  from public.tasks where id = p_task for update;"""),
    ("""  if not app.can_view_task(p_task) then
    raise exception 'forbidden';
  end if;""",
     """  if not app.can_view_task(p_task) then
    raise exception 'forbidden';
  end if;
  -- Who may add (proposal §8.6): the task's assignee, a manager member of the
  -- project, tasks.manage.project, or super admin. projects.view.all or being
  -- the creator is not enough. Personal tasks never have collaborators (above).
  if not (
    v_assignee = auth.uid()
    or app.has_permission('tasks.manage.project')
    or app.is_super_admin(auth.uid())
    or exists (select 1 from public.project_members m where m.project_id = v_project and m.profile_id = auth.uid()
               and m.removed_at is null and m.member_role = 'manager')
  ) then
    raise exception 'forbidden';
  end if;
  perform app.require_active_member(v_project, p_profile, 'collaborator_not_member');"""),
    ("""  get diagnostics v_inserted = row_count;
  if v_inserted > 0 and p_profile is distinct from auth.uid() then""",
     """  get diagnostics v_inserted = row_count;
  -- Already a collaborator: nothing changed, so no notification, event or audit.
  if v_inserted = 0 then
    return;
  end if;
  if p_profile is distinct from auth.uid() then"""),
    ("""  values (app.current_workspace(), p_task, auth.uid(), 'task.collaborator', jsonb_build_object('profile_id', p_profile));""",
     """  values (app.current_workspace(), p_task, auth.uid(), 'task.collaborator', jsonb_build_object('profile_id', p_profile));
  perform app.audit(v_workspace, auth.uid(), 'task.collaborator_add', 'task', p_task, jsonb_build_object('profile_id', p_profile));"""),
])

existing('public.remove_project_member', [
    ("""  v_workspace uuid;
begin""", """  v_workspace uuid;
  v_blocking jsonb;
begin"""),
    ("""  where project_id = p_project and profile_id = p_profile and removed_at is null;
  if v_role is null then
    raise exception 'not_found';
  end if;""",
     """  where project_id = p_project and profile_id = p_profile and removed_at is null
  for update;
  if v_role is null then
    raise exception 'not_found';
  end if;
  -- B3: a member who holds open tasks stays until they are reassigned.
  v_blocking := app.open_tasks_of_member(p_project, p_profile, 50);
  if (v_blocking ->> 'total')::integer > 0 then
    raise exception 'member_has_open_tasks' using detail = v_blocking::text;
  end if;"""),
])

existing('public.remove_task_collaborator', [
    ("""begin
  perform app.require_active();
  if not app.can_view_task(p_task) then
    raise exception 'forbidden';
  end if;
  delete from public.task_collaborators
  where task_id = p_task and profile_id = p_profile;
  insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)
  values (app.current_workspace(), p_task, auth.uid(), 'task.collaborator_remove', jsonb_build_object('profile_id', p_profile));
end;""",
     """declare
  v_project uuid;
  v_workspace uuid;
  v_deleted integer;
begin
  perform app.require_active();
  -- Lock the task row: serialised with submit / review / decide (snapshot).
  select project_id, workspace_id into v_project, v_workspace from public.tasks where id = p_task for update;
  if not found or not app.can_view_task(p_task) then
    raise exception 'forbidden';
  end if;
  -- Who may remove a collaborator (proposal §8.6): the collaborator themself,
  -- tasks.manage.project, a manager member of the task's project, or super admin.
  if not (
    p_profile = auth.uid()
    or app.has_permission('tasks.manage.project')
    or app.is_super_admin(auth.uid())
    or exists (select 1 from public.project_members m where m.project_id = v_project and m.profile_id = auth.uid()
               and m.removed_at is null and m.member_role = 'manager')
  ) then
    raise exception 'forbidden';
  end if;
  delete from public.task_collaborators
  where task_id = p_task and profile_id = p_profile;
  get diagnostics v_deleted = row_count;
  -- Nothing removed: no event, no audit.
  if v_deleted = 0 then
    return;
  end if;
  insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)
  values (v_workspace, p_task, auth.uid(), 'task.collaborator_remove', jsonb_build_object('profile_id', p_profile));
  perform app.audit(v_workspace, auth.uid(), 'task.collaborator_remove', 'task', p_task, jsonb_build_object('profile_id', p_profile));
end;"""),
])

# 3. Every writer of task content locks the task row first (task, then item),
# the same order as submit / review_update / decide: snapshots are serialised.
TASK_LOCK_BY_TASK = """  perform app.require_active();
  -- Lock the task row first: serialised with submit / review / decide (snapshot).
  perform 1 from public.tasks where id = p_task for update;"""
TASK_LOCK_BY_ITEM = """  perform app.require_active();
  -- Lock the task row first (task, then item): serialised with submit / review / decide (snapshot).
  perform 1 from public.tasks where id = (select task_id from public.task_checklist_items where id = p_item) for update;"""
existing('public.set_task_labels', [("""  perform app.require_active();""", TASK_LOCK_BY_TASK)])
existing('public.add_checklist_item', [("""  perform app.require_active();""", TASK_LOCK_BY_TASK)])
existing('public.toggle_checklist_item', [("""  perform app.require_active();""", TASK_LOCK_BY_ITEM)])
existing('public.rename_checklist_item', [("""  perform app.require_active();""", TASK_LOCK_BY_ITEM)])
existing('public.delete_checklist_item', [("""  perform app.require_active();""", TASK_LOCK_BY_ITEM)])
existing('public.move_checklist_item', [("""  perform app.require_active();""", TASK_LOCK_BY_ITEM)])

# Tightening, APPROVED in review v5 (proposal §8.5): in a restricted project the
# collaborator path counts only while the collaborator is an active member, so a
# removed member keeps no access through old collaborator rows.
existing('app.task_visible_directly', [
    ("""    or exists (
      select 1 from public.task_collaborators
      where task_id = p_task and profile_id = auth.uid()
    )""",
     """    or exists (
      select 1 from public.task_collaborators c
      join public.project_members m on m.project_id = p_project and m.profile_id = c.profile_id and m.removed_at is null
      where c.task_id = p_task and c.profile_id = auth.uid()
    )"""),
])

existing('public.save_workflow_status', [
    ("""  v_key text;
begin""", """  v_key text;
  v_current public.workflow_statuses%rowtype;
begin"""),
    ("""  if char_length(trim(coalesce(p_name, ''))) = 0 then
    raise exception 'invalid_name';
  end if;""",
     """  if char_length(trim(coalesce(p_name, ''))) = 0 then
    raise exception 'invalid_name';
  end if;
  if p_status is not null then
    select * into v_current from public.workflow_statuses where id = p_status and workflow_id = p_workflow for update;
    if not found then
      raise exception 'not_found';
    end if;
  end if;
  -- D7: retired categories can be neither created, assigned, nor re-activated.
  if p_category in ('todo', 'in_progress', 'blocked', 'changes_requested', 'approved')
     and (p_status is null or v_current.category is distinct from p_category or (p_active and not v_current.is_active)) then
    raise exception 'category_retired';
  end if;
  -- Every workflow keeps the backlog status and an active status of each
  -- category the review cycle needs.
  if p_status is not null then
    if v_current.key = 'backlog' and p_category <> 'backlog' then
      raise exception 'status_required';
    end if;
    if v_current.is_active and v_current.category in ('backlog', 'in_review', 'done', 'rejected')
       and (not p_active or p_category <> v_current.category)
       and not exists (select 1 from public.workflow_statuses
                       where workflow_id = p_workflow and category = v_current.category and is_active and id <> p_status) then
      raise exception 'status_required';
    end if;
  end if;"""),
])

add("""
-- New projects get the final workflow (proposal §3.1, §3.3).
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
  v_review uuid;
  v_done uuid;
  v_rejected uuid;
begin
  insert into public.workflows (workspace_id, project_id, name)
  values (p_workspace, p_project, v_name)
  returning id into v_workflow;

  insert into public.workflow_statuses (workflow_id, key, name, category, position, requires_authority)
  values
    (v_workflow, 'backlog', 'در صف انجام', 'backlog', 1, false),
    (v_workflow, 'in_review', 'در حال بررسی', 'in_review', 2, false),
    (v_workflow, 'done', 'انجام‌شده', 'done', 3, true),
    (v_workflow, 'rejected', 'رد نهایی', 'rejected', 4, true);

  select id into v_backlog from public.workflow_statuses where workflow_id = v_workflow and key = 'backlog';
  select id into v_review from public.workflow_statuses where workflow_id = v_workflow and key = 'in_review';
  select id into v_done from public.workflow_statuses where workflow_id = v_workflow and key = 'done';
  select id into v_rejected from public.workflow_statuses where workflow_id = v_workflow and key = 'rejected';

  insert into public.workflow_transitions (workflow_id, from_status_id, to_status_id)
  values
    (v_workflow, v_backlog, v_review),
    (v_workflow, v_review, v_done),
    (v_workflow, v_review, v_backlog),
    (v_workflow, v_review, v_rejected),
    (v_workflow, v_backlog, v_done),
    (v_workflow, v_rejected, v_backlog);

  return v_workflow;
end;
$function$
;""")
CHANGED.append('app.seed_workflow')

BLOCKED_ST = "where st.category = 'blocked' and not app.task_counts_complete(t.id)"
# Blocked = the flag on unresolved work (task_is_open is false for a blocked task by definition).
BLOCKED_ST_NEW = "where (st.category = 'blocked' or t.blocked_at is not null) and app.task_is_unresolved(t.id)"
# Final Rejected and Blocked are their own groups in sprint / milestone stats (not remaining):
# remaining = total - complete - rejected - blocked. The groups are disjoint (a
# blocked task is unresolved, so never complete nor rejected).
existing('public.project_sprint_counts', [
    (BLOCKED_ST, BLOCKED_ST_NEW),
    ("RETURNS TABLE(sprint_id uuid, total integer, complete integer, blocked integer)",
     "RETURNS TABLE(sprint_id uuid, total integer, complete integer, blocked integer, rejected integer)"),
    ("""    )::integer
  from public.sprints s""", """    )::integer,
    count(t.id) filter (where st.category = 'rejected')::integer
  from public.sprints s"""),
], drop_first='public.project_sprint_counts(uuid)')
existing('public.project_milestone_counts', [
    (BLOCKED_ST, BLOCKED_ST_NEW),
    ("RETURNS TABLE(milestone_id uuid, total integer, complete integer, blocked integer)",
     "RETURNS TABLE(milestone_id uuid, total integer, complete integer, blocked integer, rejected integer)"),
    ("""    )::integer
  from public.milestones m""", """    )::integer,
    count(t.id) filter (where st.category = 'rejected')::integer
  from public.milestones m"""),
], drop_first='public.project_milestone_counts(uuid)')
existing('public.set_sprint_status', [
    (BLOCKED_ST, BLOCKED_ST_NEW),
    ("""  v_blocked integer;
begin""", """  v_blocked integer;
  v_rejected integer;
begin"""),
    ("""      )::integer
    into v_total, v_complete, v_blocked""", """      )::integer,
      count(t.id) filter (where st.category = 'rejected')::integer
    into v_total, v_complete, v_blocked, v_rejected"""),
    ("""            'remaining', v_total - v_complete,""", """            'rejected', v_rejected,
            'remaining', v_total - v_complete - v_rejected - v_blocked,"""),
])
# Pending work moves on / holds a milestone: unresolved tasks, blocked included
# (a blocked task returns to its column when cleared; leaving it in a closed
# sprint would strand it). Final Rejected is neither carried over nor holds a milestone.
existing('public.transfer_sprint_remainder', [("not app.task_counts_complete(t.id)", "app.task_is_unresolved(t.id)")])
existing('public.set_milestone_status', [("not app.task_counts_complete(t.id)", "app.task_is_unresolved(t.id)")])
# Overdue / active / remaining counts: open for work only (no Final Rejected, no blocked).
existing('app.dashboard_summary_v1', [("not app.task_counts_complete(t.id)", "app.task_is_open(t.id)", 5)])
existing('public.dashboard_projects', [("not app.task_counts_complete(t.id)", "app.task_is_open(t.id)")])
existing('public.dashboard_team', [("not app.task_counts_complete(t.id)", "app.task_is_open(t.id)", 2)])
existing('public.dashboard_people', [("not app.task_counts_complete(t.id)", "app.task_is_open(t.id)")])
existing('public.dashboard_personal', [
    ("not app.task_counts_complete(t.id)", "app.task_is_open(t.id)", 2),
    # Home: the "رد شده" group (Final Rejected + blocked) of my tasks, counted separately.
    ("""    'awaiting_review', (""", """    'rejected_tasks', (
      select count(*) from public.tasks t
      join public.workflow_statuses s on s.id = t.status_id
      where t.primary_assignee_id = v_me and t.archived_at is null and app.can_view_task(t.id) and s.category = 'rejected'
    ),
    'blocked_tasks', (
      select count(*) from public.tasks t
      where t.primary_assignee_id = v_me and t.blocked_at is not null and app.can_view_task(t.id)
        and app.task_is_unresolved(t.id)
    ),
    'awaiting_review', ("""),
])
SPRINT_ROW_COUNTS = """          count(t.id) filter (where app.task_counts_complete(t.id))::integer as complete
        from public."""
existing('public.work_analytics', [
    # blocked: the flag on unresolved work, reported on its own
    ("""where t.archived_at is null and app.can_view_task(t.id) and s.category = 'blocked'
        and not app.task_counts_complete(t.id)""",
     """where t.archived_at is null and app.can_view_task(t.id) and (s.category = 'blocked' or t.blocked_at is not null)
        and app.task_is_unresolved(t.id)"""),
    # remaining / overdue: open for work only
    ("not app.task_counts_complete(t.id)", "app.task_is_open(t.id)", 2),
    # Final Rejected reported on its own
    ("""    'remaining', (""", """    'rejected', (
      select count(*) from public.tasks t
      join public.workflow_statuses s on s.id = t.status_id
      where t.archived_at is null and app.can_view_task(t.id) and s.category = 'rejected'
        and (p_project is null or t.project_id = p_project)
    ),
    'remaining', ("""),
    # per sprint / milestone rows (also the sprint and milestone report exports):
    # rejected and blocked separately, remaining without them
    (SPRINT_ROW_COUNTS, """          count(t.id) filter (where app.task_counts_complete(t.id))::integer as complete,
          count(t.id) filter (where exists (select 1 from public.workflow_statuses st
                                            where st.id = t.status_id and st.category = 'rejected'))::integer as rejected,
          count(t.id) filter (where t.blocked_at is not null and app.task_is_unresolved(t.id))::integer as blocked
        from public.""", 2),
    ("""        'remaining', greatest(coalesce(c.total, 0) - coalesce(c.complete, 0), 0),""",
     """        'rejected', coalesce(c.rejected, 0), 'blocked', coalesce(c.blocked, 0),
        'remaining', greatest(coalesce(c.total, 0) - coalesce(c.complete, 0) - coalesce(c.rejected, 0) - coalesce(c.blocked, 0), 0),""", 2),
])

# ----------------------------------------------------------------------------- 9. triggers
add("""
-- -----------------------------------------------------------------------------
-- 9. Immutability. Applies to every role (postgres here is not a superuser);
--    only superuser replica mode bypasses it, allowed solely in local QA cleanup.
-- -----------------------------------------------------------------------------
create trigger task_review_rounds_protect before update on public.task_review_rounds for each row execute function app.protect_review_round();
create trigger task_review_rounds_no_delete before delete on public.task_review_rounds for each row execute function app.reject_change();
create trigger task_reviews_immutable before update or delete on public.task_reviews for each row execute function app.reject_change();
create trigger task_revision_requests_immutable before update or delete on public.task_revision_requests for each row execute function app.reject_change();
create trigger task_revision_requests_check before insert on public.task_revision_requests for each row execute function app.check_revision_request();
create trigger task_block_events_immutable before update or delete on public.task_block_events for each row execute function app.reject_change();
create trigger task_activity_events_immutable before update or delete on public.task_activity_events for each row execute function app.reject_change();
-- TRUNCATE skips row triggers: a statement trigger stops it for every role,
-- the owner included (only superuser replica mode bypasses, local QA cleanup only).
create trigger task_review_rounds_no_truncate before truncate on public.task_review_rounds for each statement execute function app.reject_change();
create trigger task_reviews_no_truncate before truncate on public.task_reviews for each statement execute function app.reject_change();
create trigger task_revision_requests_no_truncate before truncate on public.task_revision_requests for each statement execute function app.reject_change();
create trigger task_block_events_no_truncate before truncate on public.task_block_events for each statement execute function app.reject_change();
create trigger task_activity_events_no_truncate before truncate on public.task_activity_events for each statement execute function app.reject_change();
create constraint trigger task_reviews_revision_request after insert on public.task_reviews
  deferrable initially deferred for each row execute function app.require_revision_request();
""")

# ----------------------------------------------------------------------------- 10. RLS
add("""
-- -----------------------------------------------------------------------------
-- 10. RLS of new tables: read = can see the task; writes only through RPCs
-- -----------------------------------------------------------------------------
alter table public.task_revision_requests enable row level security;
alter table public.task_block_events enable row level security;
create policy revision_requests_select on public.task_revision_requests for select to authenticated using (app.can_view_task(task_id));
create policy block_events_select on public.task_block_events for select to authenticated using (app.can_view_task(task_id));
alter table public.workflow_status_migration_log enable row level security;
alter table public.workflow_status_migration_report enable row level security;
alter table public.workflow_status_changes enable row level security;
alter table public.workflow_migration_added_transitions enable row level security;
alter table public.workflow_rollback_runs enable row level security;
-- task_review_rounds / task_reviews keep their policies (rounds_select, reviews_select = can_view_task).
-- profiles_select and app.task_visible_directly are not changed.
""")

# ----------------------------------------------------------------------------- 11. privileges
NEW_TABLES = ['public.task_block_events', 'public.task_revision_requests']
BOOK_TABLES = ['public.workflow_status_migration_log', 'public.workflow_status_migration_report', 'public.workflow_status_changes',
               'public.workflow_migration_added_transitions', 'public.workflow_rollback_runs']
priv = ["""
-- -----------------------------------------------------------------------------
-- 11. Privileges. Real defaults of this database (pg_default_acl): new objects in
--     schema public get EXECUTE / ALL for anon and authenticated, and functions in
--     schema app get EXECUTE for PUBLIC. Nothing here relies on defaults:
--     every grant is revoked, then granted explicitly.
-- -----------------------------------------------------------------------------"""]
# History tables: read only for clients and service_role (no INSERT/UPDATE/DELETE,
# no TRUNCATE, no TRIGGER, no REFERENCES). Writes happen only inside the RPCs
# (owner postgres). Existing history tables lose TRUNCATE and TRIGGER for
# service_role (they had ALL); row triggers already stop UPDATE/DELETE.
for t in NEW_TABLES:
    priv.append(f"revoke all on table {t} from public, anon, authenticated, service_role;")
    priv.append(f"grant select on table {t} to authenticated, service_role;")
# Existing history tables: service_role had ALL. It needs none of the write
# rights (no Edge Function writes them; the RPCs run as the owner): it keeps SELECT.
for t in ['public.task_review_rounds', 'public.task_reviews', 'public.task_activity_events']:
    priv.append(f"revoke insert, update, delete, truncate, trigger, references on table {t} from public, anon, authenticated, service_role;")
for t in BOOK_TABLES:
    priv.append(f"revoke all on table {t} from public, anon, authenticated, service_role;")
for s in ['public.workflow_status_migration_log_id_seq', 'public.workflow_status_migration_report_id_seq', 'public.workflow_rollback_runs_id_seq']:
    priv.append(f"revoke all on sequence {s} from public, anon, authenticated, service_role;")
for f in NEW_INTERNAL:
    priv.append(f"revoke all on function {f} from public, anon, authenticated, service_role;")
for f in NEW_PUBLIC:
    priv.append(f"revoke all on function {f} from public, anon;")
    priv.append(f"grant execute on function {f} to authenticated, service_role;")
SIGS = {
    'public.create_task': 'public.create_task(text, text, uuid, uuid, text, timestamptz, boolean, uuid, uuid, boolean)',
    'public.update_task': 'public.update_task(uuid, text, text, uuid, uuid, text, timestamptz, boolean)',
    'public.transition_task': 'public.transition_task(uuid, uuid, text)',
    'public.add_task_collaborator': 'public.add_task_collaborator(uuid, uuid)',
    'public.remove_project_member': 'public.remove_project_member(uuid, uuid)',
    'public.save_workflow_status': 'public.save_workflow_status(uuid, uuid, text, text, integer, boolean, boolean)',
    'public.project_sprint_counts': 'public.project_sprint_counts(uuid)',
    'public.project_milestone_counts': 'public.project_milestone_counts(uuid)',
    'public.set_sprint_status': 'public.set_sprint_status(uuid, text)',
    'public.work_analytics': 'public.work_analytics(uuid)',
    'app.seed_workflow': 'app.seed_workflow(uuid, uuid)',
    'public.remove_task_collaborator': 'public.remove_task_collaborator(uuid, uuid)',
    'app.task_visible_directly': 'app.task_visible_directly(uuid, uuid, uuid)',
    'public.set_task_labels': 'public.set_task_labels(uuid, uuid[])',
    'public.add_checklist_item': 'public.add_checklist_item(uuid, text)',
    'public.toggle_checklist_item': 'public.toggle_checklist_item(uuid, boolean)',
    'public.rename_checklist_item': 'public.rename_checklist_item(uuid, text)',
    'public.delete_checklist_item': 'public.delete_checklist_item(uuid)',
    'public.move_checklist_item': 'public.move_checklist_item(uuid, integer)',
    'public.transfer_sprint_remainder': 'public.transfer_sprint_remainder(uuid, uuid)',
    'public.set_milestone_status': 'public.set_milestone_status(uuid, text, text)',
    'app.dashboard_summary_v1': 'app.dashboard_summary_v1()',
    'public.dashboard_projects': 'public.dashboard_projects()',
    'public.dashboard_team': 'public.dashboard_team()',
    'public.dashboard_people': 'public.dashboard_people(text, uuid, text, boolean, integer, integer)',
    'public.dashboard_personal': 'public.dashboard_personal()',
}
for sig in ['public.project_sprint_counts(uuid)', 'public.project_milestone_counts(uuid)']:
    priv.append(f"grant execute on function {sig} to authenticated, service_role;  -- recreated (return type): same grants as before")
for name in CHANGED:
    sig = SIGS[name]
    if name.startswith('app.'):
        priv.append(f"revoke all on function {sig} from public, anon, authenticated;  -- otherwise unchanged (postgres; service_role where it had it)")
    else:
        priv.append(f"revoke all on function {sig} from public, anon;  -- ACL unchanged: postgres, authenticated, service_role")
add('\n'.join(priv))

add("""
-- -----------------------------------------------------------------------------
-- 12. Self-check before commit: privileges are what §11 says
-- -----------------------------------------------------------------------------
do $acl$
declare v_bad text;
begin
  select string_agg(n.nspname || '.' || p.proname, ', ') into v_bad
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'app'
    and p.proname in ('person_label', 'person_json', 'require_active_member', 'require_active_profile', 'personal_assign_scope',
                      'task_snapshot', 'can_act_on_task', 'can_decide_task', 'workflow_status', 'open_round',
                      'open_tasks_of_member', 'apply_review_changes', 'task_is_open', 'task_is_unresolved')
    and (has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute'));
  if v_bad is not null then raise exception 'acl_check_failed: %', v_bad; end if;

  select string_agg(p.proname, ', ') into v_bad
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in ('project_member_directory', 'project_member_open_tasks', 'submit_task_for_review', 'review_update_task',
                      'decide_task', 'set_task_blocked', 'clear_task_blocked', 'create_task', 'update_task', 'transition_task',
                      'add_task_collaborator', 'remove_project_member', 'save_workflow_status')
    and has_function_privilege('anon', p.oid, 'execute');
  if v_bad is not null then raise exception 'acl_check_failed: anon on %', v_bad; end if;

  select string_agg(r || ' ' || t || ' ' || p, ', ') into v_bad
  from unnest(array['anon', 'authenticated', 'service_role']) r,
       unnest(array['public.task_review_rounds', 'public.task_reviews', 'public.task_activity_events',
                    'public.task_revision_requests', 'public.task_block_events']) t,
       unnest(array['TRUNCATE', 'TRIGGER', 'REFERENCES']) p
  where has_table_privilege(r, t, p);
  if v_bad is not null then raise exception 'acl_check_failed: history %', v_bad; end if;
  select string_agg(t || ' ' || p, ', ') into v_bad
  from unnest(array['public.task_review_rounds', 'public.task_reviews', 'public.task_activity_events',
                    'public.task_revision_requests', 'public.task_block_events']) t,
       unnest(array['INSERT', 'UPDATE', 'DELETE']) p
  where has_table_privilege('service_role', t, p);
  if v_bad is not null then raise exception 'acl_check_failed: service_role writes history: %', v_bad; end if;

  if has_table_privilege('anon', 'public.task_revision_requests', 'select')
     or has_table_privilege('authenticated', 'public.task_revision_requests', 'insert')
     or has_table_privilege('authenticated', 'public.task_block_events', 'update')
     or has_table_privilege('authenticated', 'public.workflow_status_migration_log', 'select') then
    raise exception 'acl_check_failed: tables';
  end if;
end;
$acl$;

commit;
""")

(DOCS / 'task-workflow-migration-draft.sql').write_text('\n'.join(parts), encoding='utf-8')
(SCRATCH / 'changed-functions.txt').write_text(
    'CHANGED\n' + '\n'.join(CHANGED) + '\nNEW_PUBLIC\n' + '\n'.join(NEW_PUBLIC) + '\nNEW_INTERNAL\n' + '\n'.join(NEW_INTERNAL) + '\n', encoding='utf-8')
print('migration ok:', len(CHANGED), 'changed,', len(NEW_PUBLIC), 'new public,', len(NEW_INTERNAL), 'internal')
