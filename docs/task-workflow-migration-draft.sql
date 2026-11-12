-- =============================================================================
-- DRAFT v9 — DO NOT APPLY. Generated; do not edit by hand (proposal §13).
-- Not in supabase/migrations on purpose. Local Supabase only, after approval.
-- Five-status task workflow: در صف انجام (backlog), در حال انجام (in_progress),
-- در حال بررسی (in_review), تأیید شده (approved), رد شده (rejected).
-- Review cycle with versions, blocked flag, membership integrity.
-- Existing functions are the exact pg_get_functiondef bodies of the local
-- database with reviewed, minimal edits (proposal §6 lists every edit).
-- One transaction. Retired statuses (todo, changes_requested, blocked, done)
-- are deactivated, never deleted.
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


-- -----------------------------------------------------------------------------
-- 0. Plan (same SQL as docs/task-workflow-premigration-report.sql) and guard
-- -----------------------------------------------------------------------------
create temporary table migration_wf on commit drop as
with expected_status (key, name, category, position, requires_authority, is_active) as (values
    ('backlog', 'بک‌لاگ', 'backlog', 1, false, true),
    ('todo', 'انجام‌نشده', 'todo', 2, false, true),
    ('in_progress', 'در حال انجام', 'in_progress', 3, false, true),
    ('in_review', 'در حال بررسی', 'in_review', 4, false, true),
    ('approved', 'تأییدشده', 'approved', 5, true, true),
    ('done', 'انجام‌شده', 'done', 6, true, true),
    ('blocked', 'مسدود', 'blocked', 7, false, true),
    ('changes_requested', 'نیاز به اصلاح', 'changes_requested', 8, true, true),
    ('rejected', 'ردشده', 'rejected', 9, true, true)
),
expected_transition (from_key, to_key) as (values
    ('backlog', 'todo'),
    ('todo', 'in_progress'),
    ('in_progress', 'in_review'),
    ('in_progress', 'blocked'),
    ('blocked', 'in_progress'),
    ('in_review', 'approved'),
    ('approved', 'done'),
    ('in_review', 'changes_requested'),
    ('changes_requested', 'in_progress'),
    ('in_review', 'rejected')
),
wf as (
  select w.id as workflow_id,
    not exists (
      (select key, name, category, position, requires_authority, is_active from public.workflow_statuses where workflow_id = w.id
       except select * from expected_status)
      union all
      (select * from expected_status
       except select key, name, category, position, requires_authority, is_active from public.workflow_statuses where workflow_id = w.id)
    )
    and not exists (
      (select f.key, t.key from public.workflow_transitions x
         join public.workflow_statuses f on f.id = x.from_status_id
         join public.workflow_statuses t on t.id = x.to_status_id
        where x.workflow_id = w.id
       except select * from expected_transition)
      union all
      (select * from expected_transition
       except select f.key, t.key from public.workflow_transitions x
         join public.workflow_statuses f on f.id = x.from_status_id
         join public.workflow_statuses t on t.id = x.to_status_id
        where x.workflow_id = w.id)
    ) as is_default
  from public.workflows w
)
select workflow_id, is_default from wf;

create temporary table migration_plan on commit drop as
with expected_status (key, name, category, position, requires_authority, is_active) as (values
    ('backlog', 'بک‌لاگ', 'backlog', 1, false, true),
    ('todo', 'انجام‌نشده', 'todo', 2, false, true),
    ('in_progress', 'در حال انجام', 'in_progress', 3, false, true),
    ('in_review', 'در حال بررسی', 'in_review', 4, false, true),
    ('approved', 'تأییدشده', 'approved', 5, true, true),
    ('done', 'انجام‌شده', 'done', 6, true, true),
    ('blocked', 'مسدود', 'blocked', 7, false, true),
    ('changes_requested', 'نیاز به اصلاح', 'changes_requested', 8, true, true),
    ('rejected', 'ردشده', 'rejected', 9, true, true)
),
expected_transition (from_key, to_key) as (values
    ('backlog', 'todo'),
    ('todo', 'in_progress'),
    ('in_progress', 'in_review'),
    ('in_progress', 'blocked'),
    ('blocked', 'in_progress'),
    ('in_review', 'approved'),
    ('approved', 'done'),
    ('in_review', 'changes_requested'),
    ('changes_requested', 'in_progress'),
    ('in_review', 'rejected')
),
wf as (
  select w.id as workflow_id,
    not exists (
      (select key, name, category, position, requires_authority, is_active from public.workflow_statuses where workflow_id = w.id
       except select * from expected_status)
      union all
      (select * from expected_status
       except select key, name, category, position, requires_authority, is_active from public.workflow_statuses where workflow_id = w.id)
    )
    and not exists (
      (select f.key, t.key from public.workflow_transitions x
         join public.workflow_statuses f on f.id = x.from_status_id
         join public.workflow_statuses t on t.id = x.to_status_id
        where x.workflow_id = w.id
       except select * from expected_transition)
      union all
      (select * from expected_transition
       except select f.key, t.key from public.workflow_transitions x
         join public.workflow_statuses f on f.id = x.from_status_id
         join public.workflow_statuses t on t.id = x.to_status_id
        where x.workflow_id = w.id)
    ) as is_default
  from public.workflows w
),
excluded (task_id) as (
  select v::uuid from (values
    ('47d8d5a3-6354-4c97-8ccd-7f56ef8923e4'),
    ('cf890d3d-6396-432c-93b0-a8bb59593830')
  ) x(v)
),
task_state as (
  select t.id as task_id, t.status_id, s.key, s.workflow_id, t.approval_state, t.approval_required, wf.is_default,
    exists (select 1 from public.task_review_rounds r where r.task_id = t.id
            and not exists (select 1 from public.task_reviews v where v.round_id = r.id)) as has_open_round,
    (select v.decision from public.task_review_rounds r join public.task_reviews v on v.round_id = r.id
      where r.task_id = t.id order by r.round_number desc limit 1) as last_decision
  from public.tasks t
  join public.workflow_statuses s on s.id = t.status_id
  join wf on wf.workflow_id = s.workflow_id
),
approval_ok as (
  -- A finished task is consistent with "approved" (v9 §2): approval not required
  -- and never sent ('not_required'), or approved by the decision of its newest
  -- round. Never an open round. Anything else is ambiguous and stops the migration.
  select ts.task_id,
    not ts.has_open_round and (
      (not ts.approval_required and ts.approval_state = 'not_required')
      or (ts.approval_state = 'approved' and ts.last_decision = 'approved')) as ok
  from task_state ts
),
before_block as (
  -- The status a task was in before it entered "blocked": the transition event
  -- that preceded the latest move into its current blocked status.
  select ts.task_id, (
    select prev_s.key
    from public.task_activity_events into_block
    join public.task_activity_events prev
      on prev.task_id = into_block.task_id and prev.action = 'task.transition' and prev.created_at < into_block.created_at
    join public.workflow_statuses prev_s on prev_s.id = (prev.metadata ->> 'to')::uuid
    where into_block.task_id = ts.task_id and into_block.action = 'task.transition'
      and (into_block.metadata ->> 'to')::uuid = ts.status_id
    order by into_block.created_at desc, prev.created_at desc
    limit 1
  ) as prev_key
  from task_state ts where ts.key = 'blocked'
)
select ts.task_id, ts.workflow_id, ts.status_id as from_status_id, ts.key as from_key,
  -- v9 mapping (proposal §2). A blocked task becomes the flag on the status it
  -- came from, mapped to the five statuses; blocked from review is not mapped.
  case
    when ts.task_id in (select task_id from excluded) then null
    when not ts.is_default then null
    when ts.key in ('todo', 'changes_requested') then 'backlog'
    when ts.key = 'done' and ao.ok then 'approved'
    when ts.key = 'blocked' and not ts.has_open_round and bb.prev_key in ('backlog', 'todo', 'changes_requested') then 'backlog'
    when ts.key = 'blocked' and not ts.has_open_round and bb.prev_key = 'in_progress' then 'in_progress'
    else null
  end as to_key,
  case
    when ts.task_id in (select task_id from excluded) then 'excluded'
    when not ts.is_default and ts.key in ('todo', 'changes_requested', 'blocked', 'done') then 'custom_workflow'
    when not ts.is_default then 'keep'
    when ts.key in ('todo', 'changes_requested') then 'move'
    when ts.key = 'done' and ao.ok then 'move'
    when ts.key = 'done' then 'ambiguous_done_approval'
    when ts.key = 'blocked' and not ts.has_open_round and bb.prev_key in ('backlog', 'todo', 'changes_requested', 'in_progress') then 'move'
    when ts.key = 'blocked' then 'ambiguous_blocked_previous_unknown'
    when ts.key = 'approved' and not ao.ok then 'ambiguous_approved_approval'
    when ts.key = 'in_review' and (not ts.approval_required or not ts.has_open_round) then 'ambiguous_in_review_without_round'
    else 'keep'
  end as decision,
  ts.key = 'blocked' as blocked_set
from task_state ts
join approval_ok ao on ao.task_id = ts.task_id
left join before_block bb on bb.task_id = ts.task_id
where ts.key in ('todo', 'changes_requested', 'blocked', 'done') or ts.key in ('in_review', 'approved') or ts.task_id in (select task_id from excluded);

create temporary table migration_integrity on commit drop as
select 'assignee_not_member' as kind, t.id as task_id from public.tasks t
where t.project_id is not null and not exists (
  select 1 from public.project_members m join public.profiles p on p.id = m.profile_id
  where m.project_id = t.project_id and m.profile_id = t.primary_assignee_id and m.removed_at is null and p.status = 'active')
union all
select 'assignee_inactive', t.id from public.tasks t join public.profiles p on p.id = t.primary_assignee_id where p.status <> 'active'
union all
select 'reviewer_not_member', t.id from public.tasks t
where t.project_id is not null and t.reviewer_id is not null and not exists (
  select 1 from public.project_members m where m.project_id = t.project_id and m.profile_id = t.reviewer_id and m.removed_at is null)
union all
select 'reviewer_inactive', t.id from public.tasks t join public.profiles p on p.id = t.reviewer_id where p.status <> 'active'
union all
select 'collaborator_not_member', c.task_id from public.task_collaborators c join public.tasks t on t.id = c.task_id
where not exists (select 1 from public.project_members m where m.project_id = t.project_id and m.profile_id = c.profile_id and m.removed_at is null)
union all
select 'collaborator_inactive', c.task_id from public.task_collaborators c join public.profiles p on p.id = c.profile_id where p.status <> 'active'
union all
select 'personal_created_for_other', t.id from public.tasks t where t.project_id is null and t.primary_assignee_id <> t.created_by
union all
select 'open_round', r.task_id from public.task_review_rounds r where not exists (select 1 from public.task_reviews v where v.round_id = r.id);

do $guard$
declare
  v_diff jsonb;
begin
  -- (a) exactly the reviewed workflows exist, all of them default (same classification as the plan)
  with expected (workflow_id) as (values
    ('397a6e0a-c058-4f59-856a-b77f57f83c5c'),
    ('7c934bc9-0038-441e-9cdc-bb55002e809d'),
    ('92986332-ac6f-4467-9762-abb6b6463f3a'),
    ('3f3262cf-df3c-4c4e-8631-48dccc2728c3'),
    ('cb3fe4b1-be2e-4f2f-a7e6-a0583140a11f')
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
    ('f4725489-31c7-4c03-8698-984e4435ebcc', 'changes_requested', 'backlog', 'move'),
    ('020b27db-e513-40a5-96e1-c8b124b1baa9', 'done', 'approved', 'move'),
    ('47d8d5a3-6354-4c97-8ccd-7f56ef8923e4', 'in_review', null, 'excluded'),
    ('cf890d3d-6396-432c-93b0-a8bb59593830', 'approved', null, 'excluded')
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

  -- (c) every pinned task (2 excluded + 2 moved + 1 kept) is exactly in its reviewed
  --     state, including its review rounds, open rounds and newest decision
  with expected (task_id, title, personal, status_key, approval_state, approval_required, assignee, created_by, reviewer, project_id, project_name, workflow_id, status_id, workspace_id, rounds, open_rounds, last_decision, not_archived) as (values
    ('47d8d5a3-6354-4c97-8ccd-7f56ef8923e4', 'rgdfdgf', false, 'in_review', 'pending', true, '8d2697db-f8b7-4ee7-b714-f58511e3c173', '06c2ffaf-8db2-4413-95ef-5b6d7d93c8f5', null, 'c4fa2aef-59a5-478a-8667-32777e793d91', 'باگ بانتی', '92986332-ac6f-4467-9762-abb6b6463f3a', 'b097c632-b2bc-4717-9c65-73c99e439a1a', 'a0000000-0000-4000-8000-000000000001', 1, 1, null, true),
    ('cf890d3d-6396-432c-93b0-a8bb59593830', 'vvvvvvv', true, 'approved', 'not_required', false, '0ab53a33-b9a3-407c-b977-45856a42fe96', '06c2ffaf-8db2-4413-95ef-5b6d7d93c8f5', '0ab53a33-b9a3-407c-b977-45856a42fe96', null, null, '397a6e0a-c058-4f59-856a-b77f57f83c5c', 'e7216b79-af18-4aea-8dd0-ff9af01f7192', 'a0000000-0000-4000-8000-000000000001', 0, 0, null, true),
    ('f4725489-31c7-4c03-8698-984e4435ebcc', 'ttt', true, 'changes_requested', 'not_required', false, '8d2697db-f8b7-4ee7-b714-f58511e3c173', '8d2697db-f8b7-4ee7-b714-f58511e3c173', null, null, null, '397a6e0a-c058-4f59-856a-b77f57f83c5c', 'e0655322-8cb1-487f-8cb2-3985494f169a', 'a0000000-0000-4000-8000-000000000001', 0, 0, null, true),
    ('020b27db-e513-40a5-96e1-c8b124b1baa9', 'کار محلی', false, 'done', 'approved', true, '06c2ffaf-8db2-4413-95ef-5b6d7d93c8f5', '06c2ffaf-8db2-4413-95ef-5b6d7d93c8f5', null, '9ce11cff-e0ba-4122-b282-39f286aab335', 'محصول محلی', 'cb3fe4b1-be2e-4f2f-a7e6-a0583140a11f', '85109c5d-21af-48b8-b858-e432fc5a69a3', 'a0000000-0000-4000-8000-000000000001', 1, 0, 'approved', true),
    ('30445be8-9067-44fb-818d-9380d7a46575', 'لندینگ باگ بانتی', true, 'approved', 'approved', true, '06c2ffaf-8db2-4413-95ef-5b6d7d93c8f5', '06c2ffaf-8db2-4413-95ef-5b6d7d93c8f5', null, null, null, '397a6e0a-c058-4f59-856a-b77f57f83c5c', 'e7216b79-af18-4aea-8dd0-ff9af01f7192', 'a0000000-0000-4000-8000-000000000001', 1, 0, 'approved', true)
  ), actual as (
select t.id::text as task_id, t.title, t.project_id is null as personal, s.key as status_key, t.approval_state,
       t.approval_required, t.primary_assignee_id::text as assignee, t.created_by::text as created_by,
       t.reviewer_id::text as reviewer, t.project_id::text as project_id, pr.name as project_name,
       s.workflow_id::text as workflow_id, t.status_id::text as status_id, t.workspace_id::text as workspace_id,
       (select count(*)::integer from public.task_review_rounds r where r.task_id = t.id) as rounds,
       (select count(*)::integer from public.task_review_rounds r where r.task_id = t.id
          and not exists (select 1 from public.task_reviews v where v.round_id = r.id)) as open_rounds,
       (select v.decision from public.task_review_rounds r join public.task_reviews v on v.round_id = r.id
         where r.task_id = t.id order by r.round_number desc limit 1) as last_decision,
       t.archived_at is null as not_archived
from public.tasks t join public.workflow_statuses s on s.id = t.status_id
left join public.projects pr on pr.id = t.project_id
where t.id in ('47d8d5a3-6354-4c97-8ccd-7f56ef8923e4'::uuid, 'cf890d3d-6396-432c-93b0-a8bb59593830'::uuid, 'f4725489-31c7-4c03-8698-984e4435ebcc'::uuid, '020b27db-e513-40a5-96e1-c8b124b1baa9'::uuid, '30445be8-9067-44fb-818d-9380d7a46575'::uuid)
  )
  select jsonb_agg(to_jsonb(d)) into v_diff from (
    (select * from actual except select * from expected)
    union all (select * from expected except select * from actual)) d;
  if v_diff is not null then raise exception 'premigration_mismatch' using detail = 'pinned tasks: ' || v_diff::text; end if;

  -- (d) integrity findings: exactly the reviewed rows (reviewers/collaborators/inactive: none;
  --     the only open round is rgdfdgf's)
  with expected (kind, task_id) as (values
    ('assignee_not_member', '47d8d5a3-6354-4c97-8ccd-7f56ef8923e4'),
    ('personal_created_for_other', 'cf890d3d-6396-432c-93b0-a8bb59593830'),
    ('open_round', '47d8d5a3-6354-4c97-8ccd-7f56ef8923e4')
  )
  select jsonb_agg(to_jsonb(d)) into v_diff from (
    (select kind, task_id::text from migration_integrity except select * from expected)
    union all (select * from expected except select kind, task_id::text from migration_integrity)) d;
  if v_diff is not null then raise exception 'premigration_mismatch' using detail = 'integrity: ' || v_diff::text; end if;
end;
$guard$;


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
  status_id uuid not null references public.workflow_statuses (id),   -- status when the event happened
  to_status_id uuid references public.workflow_statuses (id),         -- v9: unblock returns the task to the queue
  actor_id uuid references public.profiles (id),            -- null only for migration rows
  actor_name text,                                          -- name at that moment; null when unknown
  created_at timestamptz not null default clock_timestamp(),
  check (action = 'unblocked' or char_length(trim(coalesce(reason, ''))) > 0),
  check (action = 'unblocked' or to_status_id is null)
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


-- -----------------------------------------------------------------------------
-- 3. Internal helpers. SECURITY INVOKER: they run with the rights of the
--    SECURITY DEFINER RPC that calls them; EXECUTE is revoked from every client
--    role in §11, so only those RPCs (owner postgres) can call them.
-- -----------------------------------------------------------------------------

-- Name at this moment, for historical columns. First and last name only.
create function app.person_label(p_profile uuid)
returns text language sql stable security invoker set search_path = '' as $$
  select nullif(trim(concat_ws(' ', p.first_name, p.last_name)), '') from public.profiles p where p.id = p_profile;
$$;

create function app.person_json(p_profile uuid)
returns jsonb language sql stable security invoker set search_path = '' as $$
  select jsonb_build_object('id', p.id, 'first_name', p.first_name, 'last_name', p.last_name)
  from public.profiles p where p.id = p_profile;
$$;

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
$$;

create function app.require_active_profile(p_profile uuid, p_error text)
returns void language plpgsql security invoker set search_path = '' as $$
begin
  if p_profile is null then return; end if;
  if not exists (select 1 from public.profiles where id = p_profile and status = 'active'
                 and workspace_id = app.current_workspace()) then
    raise exception '%', p_error;
  end if;
end;
$$;

-- Personal tasks: the scope create_task already uses (no new permission).
create function app.personal_assign_scope(p_assignee uuid)
returns text language sql stable security invoker set search_path = '' as $$
  select case
    when p_assignee = auth.uid() then 'self'
    when app.is_team_approver(app.primary_team(p_assignee), auth.uid()) then 'team_approver'
    when app.has_permission('tasks.view.all') then 'view_all'
  end;
$$;

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
$$;

-- Who may move a task today (same test as transition_task / update_task).
create function app.can_act_on_task(p_task public.tasks)
returns boolean language sql stable security invoker set search_path = '' as $$
  select p_task.primary_assignee_id = auth.uid() or app.has_permission('tasks.manage.project')
      or app.is_team_approver(app.primary_team(p_task.primary_assignee_id), auth.uid());
$$;

-- decide_task eligibility. As before, except: (v9) the primary assignee never
-- decides on their own task, whatever other right they hold; a named reviewer
-- of a project task must still be an active member of that project.
-- tasks.view.all gives no decision right.
create function app.can_decide_task(p_task public.tasks)
returns boolean language sql stable security invoker set search_path = '' as $$
  select p_task.primary_assignee_id is distinct from auth.uid() and case
    when p_task.reviewer_id is not null then
      (p_task.reviewer_id = auth.uid() and (p_task.project_id is null or exists (
        select 1 from public.project_members m
        where m.project_id = p_task.project_id and m.profile_id = auth.uid() and m.removed_at is null)))
      or app.is_super_admin(auth.uid())
    when p_task.project_id is null then app.is_team_approver(app.primary_team(p_task.primary_assignee_id), auth.uid()) or app.is_super_admin(auth.uid())
    else app.is_super_admin(auth.uid()) or exists (select 1 from public.project_members m
      where m.project_id = p_task.project_id and m.profile_id = auth.uid() and m.removed_at is null and m.member_role in ('manager', 'reviewer'))
  end;
$$;

-- First active status of a category in the workflow of a status; null if none.
create function app.workflow_status(p_any_status uuid, p_category text)
returns uuid language sql stable security invoker set search_path = '' as $$
  select s.id from public.workflow_statuses s
  where s.workflow_id = (select workflow_id from public.workflow_statuses where id = p_any_status)
    and s.category = p_category and s.is_active
  order by s.position, s.id limit 1;
$$;

-- The undecided round of a task, locked. Callers hold the task row lock.
create function app.open_round(p_task uuid)
returns uuid language sql volatile security invoker set search_path = '' as $$
  select r.id from public.task_review_rounds r
  where r.task_id = p_task and not exists (select 1 from public.task_reviews v where v.round_id = r.id)
  order by r.round_number desc limit 1
  for update;
$$;

-- Unresolved work (proposal §4): not archived, not completed, and not Final
-- Rejected. A blocked task IS unresolved: it goes back to the queue when the
-- flag is cleared. Used where pending work must still count although it is not
-- open for work right now: member removal (B3) and the blocked counts.
-- (v9: a sprint carries over and a milestone waits for open work only.)
create function app.task_is_unresolved(p_task uuid)
returns boolean language sql stable security invoker set search_path = '' as $$
  select exists (
    select 1 from public.tasks t join public.workflow_statuses s on s.id = t.status_id
    where t.id = p_task and t.archived_at is null and s.category <> 'rejected'
  ) and not app.task_counts_complete(p_task);
$$;

-- Open for work (proposal §4): unresolved and not blocked. False for an
-- archived, completed, Final Rejected or blocked task. Neither Final Rejected nor
-- blocked is a success: app.task_counts_complete (unchanged) keeps returning
-- false for them. Remaining, overdue, active, sprint carry-over and milestone
-- completion use it. Not used alone for member removal (app.task_is_unresolved).
create function app.task_is_open(p_task uuid)
returns boolean language sql stable security invoker set search_path = '' as $$
  select app.task_is_unresolved(p_task)
     and exists (select 1 from public.tasks t where t.id = p_task and t.blocked_at is null);
$$;

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
$$;

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
$$;

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
$$;

create function app.reject_change()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
  raise exception 'immutable_row';
end;
$$;

-- B1 at the data level: a revision decision has exactly one structured request at commit.
create function app.require_revision_request()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
  if new.decision = 'revision_requested' and not exists (select 1 from public.task_revision_requests where review_id = new.id) then
    raise exception 'revision_request_missing';
  end if;
  return null;
end;
$$;

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
$$;

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
  case when review.reason like 'اصلاح موردنیاز:%' and position(E'\nعلت:' in review.reason) > 0
       then trim(substring(review.reason from char_length('اصلاح موردنیاز:') + 1
                           for position(E'\nعلت:' in review.reason) - char_length('اصلاح موردنیاز:') - 1))
       else trim(review.reason) end,
  case when review.reason like 'اصلاح موردنیاز:%' and position(E'\nعلت:' in review.reason) > 0
       then trim(substring(review.reason from position(E'\nعلت:' in review.reason) + char_length(E'\nعلت:')))
       else 'ثبت‌شده پیش از تفکیک فیلدها' end,
  review.reviewer_id, null, 'unavailable',
  case when review.reason like 'اصلاح موردنیاز:%' and position(E'\nعلت:' in review.reason) > 0 then 'legacy_two_part' else 'legacy_free_text' end,
  review.created_at
from public.task_reviews review join public.task_review_rounds round on round.id = review.round_id
where review.decision = 'revision_requested';


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
select t.workspace_id, m.task_id, null, 'task.migrated', jsonb_build_object('from', m.from_status_id, 'to', m.to_status_id, 'reason', 'workflow_v9_five_status')
from moves m join public.tasks t on t.id = m.task_id;

-- -----------------------------------------------------------------------------
-- 6. Default workflows only: rename, reorder, retire, add transitions
--    Active afterwards, in this order: backlog, in_progress, in_review, approved, rejected.
-- -----------------------------------------------------------------------------
create temporary table default_status on commit drop as
select s.* from public.workflow_statuses s
where s.workflow_id in (select workflow_id::uuid from (values ('397a6e0a-c058-4f59-856a-b77f57f83c5c'), ('7c934bc9-0038-441e-9cdc-bb55002e809d'), ('92986332-ac6f-4467-9762-abb6b6463f3a'), ('3f3262cf-df3c-4c4e-8631-48dccc2728c3'), ('cb3fe4b1-be2e-4f2f-a7e6-a0583140a11f')) v(workflow_id));

insert into public.workflow_status_changes (status_id, before, after)
select s.id,
  jsonb_build_object('name', s.name, 'position', s.position, 'is_active', s.is_active),
  jsonb_build_object(
    'name', coalesce(f.name, s.name),
    'position', coalesce(f.position, s.position + 100),
    'is_active', s.key not in ('todo', 'changes_requested', 'blocked', 'done'))
from default_status s
left join (values
    ('backlog', 'در صف انجام', 'backlog', 1),
    ('in_progress', 'در حال انجام', 'in_progress', 2),
    ('in_review', 'در حال بررسی', 'in_review', 3),
    ('approved', 'تأیید شده', 'approved', 4),
    ('rejected', 'رد شده', 'rejected', 5)
  ) f (key, name, category, position) on f.key = s.key;

-- No task may stay in a retired status (the guard already stopped every ambiguous row).
do $retired$
declare v_left jsonb;
begin
  select jsonb_agg(jsonb_build_object('task', t.id, 'status', s.key)) into v_left
  from public.tasks t join default_status s on s.id = t.status_id
  where s.key in ('todo', 'changes_requested', 'blocked', 'done');
  if v_left is not null then raise exception 'premigration_mismatch' using detail = 'tasks left in retired statuses: ' || v_left::text; end if;
end;
$retired$;

update public.workflow_statuses s set
  name = c.after ->> 'name',
  position = (c.after ->> 'position')::integer,
  is_active = (c.after ->> 'is_active')::boolean
from public.workflow_status_changes c where c.status_id = s.id;

with wanted (from_key, to_key) as (values
    ('backlog', 'in_progress'),
    ('in_review', 'backlog'),
    ('in_progress', 'approved'),
    ('rejected', 'backlog')
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

-- Every migrated default workflow now has exactly the five active statuses and
-- every final edge between them.
do $final$
declare v_bad jsonb;
begin
  with expected_active (key) as (values ('backlog'), ('in_progress'), ('in_review'), ('approved'), ('rejected')),
  expected_edge (from_key, to_key) as (values
    ('backlog', 'in_progress'),
    ('in_progress', 'in_review'),
    ('in_review', 'approved'),
    ('in_review', 'backlog'),
    ('in_review', 'rejected'),
    ('in_progress', 'approved'),
    ('rejected', 'backlog')
  ),
  wfs as (select distinct workflow_id from default_status)
  select jsonb_agg(x) into v_bad from (
    select jsonb_build_object('workflow', w.workflow_id, 'active', (
      select jsonb_agg(s.key order by s.position) from public.workflow_statuses s where s.workflow_id = w.workflow_id and s.is_active)) as x
    from wfs w
    where exists ((select key from public.workflow_statuses where workflow_id = w.workflow_id and is_active except select key from expected_active)
                  union all (select key from expected_active except select key from public.workflow_statuses where workflow_id = w.workflow_id and is_active))
    union all
    select jsonb_build_object('workflow', w.workflow_id, 'missing_edge', e.from_key || '>' || e.to_key)
    from wfs w cross join expected_edge e
    where not exists (select 1 from public.workflow_transitions x
                      join public.workflow_statuses f on f.id = x.from_status_id and f.key = e.from_key
                      join public.workflow_statuses t on t.id = x.to_status_id and t.key = e.to_key
                      where x.workflow_id = w.workflow_id)) d;
  if v_bad is not null then raise exception 'migration_self_check' using detail = v_bad::text; end if;
end;
$final$;


-- -----------------------------------------------------------------------------
-- 7. New RPCs (SECURITY DEFINER; EXECUTE for authenticated only, §11)
-- -----------------------------------------------------------------------------
drop function public.decide_task(uuid, text, text);

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
$$;

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
$$;

-- B2. The only way into review: «ارسال برای بررسی», in_progress -> in_review.
-- Primary assignee only (v9). Creates version vN with its real snapshot.
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
  if not found or not app.can_view_task(p_task) then raise exception 'forbidden'; end if;
  if v_task.primary_assignee_id is distinct from auth.uid() then raise exception 'assignee_only'; end if;
  if v_task.archived_at is not null then raise exception 'archived'; end if;
  if not v_task.approval_required then raise exception 'not_required'; end if;
  if v_task.blocked_at is not null then raise exception 'task_blocked'; end if;
  select category into v_category from public.workflow_statuses where id = v_task.status_id;
  if v_category <> 'in_progress' then raise exception 'invalid_state'; end if;
  if app.open_round(p_task) is not null then raise exception 'already_submitted'; end if;
  v_review := app.workflow_status(v_task.status_id, 'in_review');
  if v_review is null then raise exception 'workflow_incomplete'; end if;

  select coalesce(max(round_number), 0) + 1 into v_round from public.task_review_rounds where task_id = p_task;
  insert into public.task_review_rounds
    (task_id, round_number, submitted_by, submitted_by_source, submitted_by_name, snapshot, snapshot_version, snapshot_status)
  values (p_task, v_round, auth.uid(), 'submission', coalesce(app.person_label(auth.uid()), '—'), app.task_snapshot(p_task), 1, 'captured');
  update public.tasks set status_id = v_review, approval_state = 'pending' where id = p_task;

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

  insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)
  values (v_task.workspace_id, p_task, auth.uid(), 'task.submit', jsonb_build_object('version', v_round, 'to', v_review));
  perform app.audit(v_task.workspace_id, auth.uid(), 'task.submit', 'task', p_task, jsonb_build_object('version', v_round));
  return v_round;
end;
$$;

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
$$;

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
  -- Approving completes the task: the same required-subtask rule as complete_task.
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
    case p_decision when 'approved' then 'approved' when 'revision_requested' then 'backlog' else 'rejected' end);
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
  values (v_task.workspace_id, p_task, auth.uid(), 'task.review', jsonb_build_object('decision', p_decision, 'round_id', v_round));
  perform app.audit(v_task.workspace_id, auth.uid(), 'task.review', 'task', p_task, jsonb_build_object('decision', p_decision, 'round_id', v_round));
end;
$$;

-- v9 «انجام شد»: in_progress -> approved for a task that needs no approval.
-- Primary assignee only; one atomic step on its own edge. Creates no review
-- round and no decision: approval_state is left as it is (never 'approved').
-- p_override_reason: required subtasks not complete; tasks.manage.project or
-- super admin only (same rule as decide_task).
create function public.complete_task(p_task uuid, p_override_reason text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_task public.tasks%rowtype;
  v_status uuid;
begin
  perform app.require_active();
  select * into v_task from public.tasks where id = p_task for update;
  if not found or not app.can_view_task(p_task) then raise exception 'forbidden'; end if;
  if v_task.primary_assignee_id is distinct from auth.uid() then raise exception 'assignee_only'; end if;
  if v_task.archived_at is not null then raise exception 'archived'; end if;
  if v_task.approval_required then raise exception 'approval_required'; end if;
  if v_task.blocked_at is not null then raise exception 'task_blocked'; end if;
  if (select category from public.workflow_statuses where id = v_task.status_id) <> 'in_progress' then
    raise exception 'invalid_state';
  end if;
  if app.open_round(p_task) is not null then raise exception 'invalid_state'; end if;
  -- Serialise with a concurrent reopen of a required child (see decide_task).
  perform 1 from public.tasks where parent_task_id = p_task and is_required and archived_at is null for share;
  if app.task_children_block_done(p_task) then
    if p_override_reason is null or char_length(trim(p_override_reason)) = 0 then
      raise exception 'subtasks_incomplete';
    end if;
    if not (app.has_permission('tasks.manage.project') or app.is_super_admin(auth.uid())) then
      raise exception 'forbidden';
    end if;
    perform app.audit(v_task.workspace_id, auth.uid(), 'task.override_subtasks', 'task', p_task, jsonb_build_object('reason', trim(p_override_reason)));
    insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)
    values (v_task.workspace_id, p_task, auth.uid(), 'task.override', jsonb_build_object('reason', trim(p_override_reason)));
  end if;
  v_status := app.workflow_status(v_task.status_id, 'approved');
  if v_status is null then raise exception 'workflow_incomplete'; end if;

  update public.tasks set status_id = v_status where id = p_task;
  insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)
  values (v_task.workspace_id, p_task, auth.uid(), 'task.complete', jsonb_build_object('from', v_task.status_id, 'to', v_status));
  if v_task.parent_task_id is not null then
    insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)
    values (v_task.workspace_id, v_task.parent_task_id, auth.uid(), 'task.subtask_done', jsonb_build_object('child', p_task));
  end if;
  perform app.audit(v_task.workspace_id, auth.uid(), 'task.complete', 'task', p_task, jsonb_build_object('from', v_task.status_id, 'to', v_status));
end;
$$;

-- D2. A flag on open work (queue or in progress); the status does not change.
-- Shown in the «رد شده» group with the «مسدود» badge.
create function public.set_task_blocked(p_task uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_task public.tasks%rowtype;
begin
  perform app.require_active();
  if char_length(trim(coalesce(p_reason, ''))) = 0 then raise exception 'reason_required'; end if;
  select * into v_task from public.tasks where id = p_task for update;
  if not found or not app.can_view_task(p_task) or not app.can_act_on_task(v_task) then raise exception 'forbidden'; end if;
  if v_task.archived_at is not null then raise exception 'archived'; end if;
  if (select category from public.workflow_statuses where id = v_task.status_id) not in ('backlog', 'in_progress')
     or app.open_round(p_task) is not null then
    raise exception 'invalid_state';
  end if;
  if v_task.blocked_at is not null then raise exception 'already_blocked'; end if;
  update public.tasks set blocked_at = clock_timestamp(), blocked_reason = trim(p_reason), blocked_by = auth.uid() where id = p_task;
  insert into public.task_block_events (task_id, action, reason, status_id, actor_id, actor_name)
  values (p_task, 'blocked', trim(p_reason), v_task.status_id, auth.uid(), app.person_label(auth.uid()));
  insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)
  values (v_task.workspace_id, p_task, auth.uid(), 'task.block', jsonb_build_object('reason', trim(p_reason)));
  perform app.audit(v_task.workspace_id, auth.uid(), 'task.block', 'task', p_task, jsonb_build_object('reason', trim(p_reason)));
end;
$$;

-- v9 «بازگرداندن به چرخه» for a blocked task: clears the flag and returns the
-- task to the queue (backlog). Rounds, version numbers, approval state, review
-- and block history are not touched.
create function public.clear_task_blocked(p_task uuid, p_note text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_task public.tasks%rowtype;
  v_backlog uuid;
begin
  perform app.require_active();
  select * into v_task from public.tasks where id = p_task for update;
  if not found or not app.can_view_task(p_task) or not app.can_act_on_task(v_task) then raise exception 'forbidden'; end if;
  if v_task.blocked_at is null then raise exception 'not_blocked'; end if;
  -- A blocked task never has an open round (set_task_blocked and the migration
  -- plan refuse it); checked again so no version is ever stranded.
  if app.open_round(p_task) is not null then raise exception 'invalid_state'; end if;
  v_backlog := app.workflow_status(v_task.status_id, 'backlog');
  if v_backlog is null then raise exception 'workflow_incomplete'; end if;
  update public.tasks set blocked_at = null, blocked_reason = null, blocked_by = null, status_id = v_backlog where id = p_task;
  insert into public.task_block_events (task_id, action, reason, status_id, to_status_id, actor_id, actor_name)
  values (p_task, 'unblocked', nullif(trim(coalesce(p_note, '')), ''), v_task.status_id, v_backlog, auth.uid(), app.person_label(auth.uid()));
  insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)
  values (v_task.workspace_id, p_task, auth.uid(), 'task.unblock', jsonb_build_object('from', v_task.status_id, 'to', v_backlog));
  perform app.audit(v_task.workspace_id, auth.uid(), 'task.unblock', 'task', p_task, jsonb_build_object('from', v_task.status_id, 'to', v_backlog));
end;
$$;

-- -----------------------------------------------------------------------------
-- 8. Existing functions: current bodies with the reviewed edits only
-- -----------------------------------------------------------------------------

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
    perform app.require_active_profile(v_assignee, 'assignee_inactive');
    perform app.require_active_profile(p_reviewer, 'reviewer_inactive');
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
    perform app.require_active_member(p_project, v_assignee, 'assignee_not_member');
    perform app.require_active_member(p_project, p_reviewer, 'reviewer_not_member');
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
    -- Share-lock the parent: a subtask cannot appear while the parent is being completed.
    select project_id into v_parent_project from public.tasks where id = p_parent for share;
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
  values (v_workspace, v_id, auth.uid(), 'task.create',
          jsonb_build_object('assignee', v_assignee, 'on_behalf', v_assignee <> auth.uid(), 'created_by', auth.uid()));
  if p_parent is not null then
    insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)
    values (v_workspace, p_parent, auth.uid(), 'task.subtask', jsonb_build_object('child', v_id));
  end if;
  perform app.audit(v_workspace, auth.uid(), 'task.create', 'task', v_id, '{}'::jsonb);
  if v_assignee <> auth.uid() then
    -- Created on behalf of someone else: who, for whom, under which scope.
    perform app.audit(v_workspace, auth.uid(), 'task.create_for', 'task', v_id, jsonb_build_object(
      'assignee', v_assignee, 'created_by', auth.uid(), 'project', p_project,
      'scope', case when p_project is null then app.personal_assign_scope(v_assignee) else 'project' end));
  end if;
  if v_assignee <> auth.uid() then
    perform app.notify(v_workspace, v_assignee, 'task', 'تسک جدید', 'یک تسک به شما سپرده شد.', 'task', v_id);
  end if;
  return v_id;
end;
$function$
;

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

  -- v9: a submitted version is frozen until the reviewer decides. Content and
  -- the approval policy cannot change (the reviewer edits through
  -- review_update_task / decide_task, recorded against the round); people
  -- (assignee, reviewer) can still be changed by those allowed, with audit.
  if app.open_round(p_task) is not null and (
       v_task.title is distinct from trim(p_title) or v_task.description is distinct from coalesce(p_description, '')
       or v_task.priority is distinct from p_priority or v_task.due_at is distinct from p_due
       or v_task.approval_required is distinct from p_approval) then
    raise exception 'task_in_review';
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
     and not (app.has_permission('tasks.manage.project') or app.is_super_admin(auth.uid()))
  then
    raise exception 'rejected_closed';
  end if;

  -- Leaving review is a reviewer decision only (decide_task).
  if v_current = 'in_review' then
    raise exception 'use_decide';
  end if;
  -- A blocked task leaves the flag only through clear_task_blocked.
  if v_task.blocked_at is not null then
    raise exception 'task_blocked';
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
  if v_category = 'in_review' then
    raise exception 'use_submit';
  end if;
  -- Finishing is complete_task (no approval) or decide_task (approval).
  if v_category = 'approved' then
    raise exception 'use_complete';
  end if;
  -- Final rejection is a reviewer decision only.
  if v_category = 'rejected' then
    raise exception 'use_decide';
  end if;
  -- Final Rejected leaves only through reopening, and only to backlog.
  if v_current = 'rejected' and v_category <> 'backlog' then
    raise exception 'reopen_backlog_only';
  end if;
  -- Starting work: the primary assignee only (not a manager, not a team approver).
  if v_category = 'in_progress' and v_task.primary_assignee_id is distinct from auth.uid() then
    raise exception 'assignee_only';
  end if;

  if v_authority
     and v_task.approval_required
     and v_task.approval_state <> 'approved'
     and v_category in ('approved', 'done', 'changes_requested', 'rejected')
  then
    raise exception 'approval_required';
  end if;

  -- Required-subtask override: complete_task / decide_task (v9).

  update public.tasks set status_id = p_status where id = p_task;
  -- Reopening a Final Rejected task (proposal §4): a new cycle ("not sent yet",
  -- not "rejected"), recorded as its own event and audit entry. Earlier rounds,
  -- decisions and versions stay as they are; the next submission is vN+1.
  if v_current = 'rejected' then
    if v_task.approval_required then
      update public.tasks set approval_state = 'pending' where id = p_task;
    end if;
    insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)
    values (v_task.workspace_id, p_task, auth.uid(), 'task.reopen', jsonb_build_object('from', v_from, 'to', p_status));
    perform app.audit(v_task.workspace_id, auth.uid(), 'task.reopen', 'task', p_task, jsonb_build_object('from', v_from, 'to', p_status));
  end if;

  -- Entering review is submit_task_for_review only (B2); its round and notifications moved there.

  insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)
  values (v_task.workspace_id, p_task, auth.uid(), 'task.transition', jsonb_build_object('to', p_status));
  perform app.audit(v_task.workspace_id, auth.uid(), 'task.transition', 'task', p_task, jsonb_build_object('status', p_status));
end;
$function$
;

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
  v_assignee uuid;
begin
  perform app.require_active();
  -- Lock the task row: serialised with submit / review / decide (snapshot).
  select project_id, workspace_id, primary_assignee_id into v_project, v_workspace, v_assignee
  from public.tasks where id = p_task for update;
  if v_project is null then
    raise exception 'personal_task';
  end if;
  if not app.can_view_task(p_task) then
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
  perform app.require_active_member(v_project, p_profile, 'collaborator_not_member');
  insert into public.task_collaborators (task_id, profile_id)
  values (p_task, p_profile)
  on conflict do nothing;
  get diagnostics v_inserted = row_count;
  -- Already a collaborator: nothing changed, so no notification, event or audit.
  if v_inserted = 0 then
    return;
  end if;
  if p_profile is distinct from auth.uid() then
    perform app.notify(v_workspace, p_profile, 'task', 'همکار تسک شدید', 'به یک تسک به‌عنوان همکار اضافه شدید.', 'task', p_task);
  end if;
  insert into public.task_activity_events (workspace_id, task_id, actor_id, action, metadata)
  values (app.current_workspace(), p_task, auth.uid(), 'task.collaborator', jsonb_build_object('profile_id', p_profile));
  perform app.audit(v_workspace, auth.uid(), 'task.collaborator_add', 'task', p_task, jsonb_build_object('profile_id', p_profile));
end;
$function$
;

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
  v_blocking jsonb;
begin
  perform app.require_active();
  if not app.can_edit_project(p_project) then
    raise exception 'forbidden';
  end if;
  select workspace_id into v_workspace from public.projects where id = p_project;
  select member_role into v_role
  from public.project_members
  where project_id = p_project and profile_id = p_profile and removed_at is null
  for update;
  if v_role is null then
    raise exception 'not_found';
  end if;
  -- B3: a member who holds open tasks stays until they are reassigned.
  v_blocking := app.open_tasks_of_member(p_project, p_profile, 50);
  if (v_blocking ->> 'total')::integer > 0 then
    raise exception 'member_has_open_tasks' using detail = v_blocking::text;
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

CREATE OR REPLACE FUNCTION public.remove_task_collaborator(p_task uuid, p_profile uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
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
end;
$function$
;

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
  -- Lock the task row first: serialised with submit / review / decide (snapshot).
  perform 1 from public.tasks where id = p_task for update;
  -- v9: a submitted version is frozen until the reviewer decides.
  if app.open_round(p_task) is not null then
    raise exception 'task_in_review';
  end if;
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
  -- Lock the task row first: serialised with submit / review / decide (snapshot).
  perform 1 from public.tasks where id = p_task for update;
  -- v9: a submitted version is frozen until the reviewer decides.
  if app.open_round(p_task) is not null then
    raise exception 'task_in_review';
  end if;
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
  -- Lock the task row first (task, then item): serialised with submit / review / decide (snapshot).
  perform 1 from public.tasks where id = (select task_id from public.task_checklist_items where id = p_item) for update;
  -- v9: a submitted version is frozen until the reviewer decides.
  if app.open_round((select task_id from public.task_checklist_items where id = p_item)) is not null then
    raise exception 'task_in_review';
  end if;
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
  -- Lock the task row first (task, then item): serialised with submit / review / decide (snapshot).
  perform 1 from public.tasks where id = (select task_id from public.task_checklist_items where id = p_item) for update;
  -- v9: a submitted version is frozen until the reviewer decides.
  if app.open_round((select task_id from public.task_checklist_items where id = p_item)) is not null then
    raise exception 'task_in_review';
  end if;
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
  -- Lock the task row first (task, then item): serialised with submit / review / decide (snapshot).
  perform 1 from public.tasks where id = (select task_id from public.task_checklist_items where id = p_item) for update;
  -- v9: a submitted version is frozen until the reviewer decides.
  if app.open_round((select task_id from public.task_checklist_items where id = p_item)) is not null then
    raise exception 'task_in_review';
  end if;
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
  -- Lock the task row first (task, then item): serialised with submit / review / decide (snapshot).
  perform 1 from public.tasks where id = (select task_id from public.task_checklist_items where id = p_item) for update;
  -- v9: a submitted version is frozen until the reviewer decides.
  if app.open_round((select task_id from public.task_checklist_items where id = p_item)) is not null then
    raise exception 'task_in_review';
  end if;
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
      select 1 from public.task_collaborators c
      join public.project_members m on m.project_id = p_project and m.profile_id = c.profile_id and m.removed_at is null
      where c.task_id = p_task and c.profile_id = auth.uid()
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
  v_current public.workflow_statuses%rowtype;
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
  if p_status is not null then
    select * into v_current from public.workflow_statuses where id = p_status and workflow_id = p_workflow for update;
    if not found then
      raise exception 'not_found';
    end if;
  end if;
  -- D7 (v9): retired categories can be neither created, assigned, nor re-activated.
  if p_category in ('todo', 'changes_requested', 'blocked', 'done')
     and (p_status is null or v_current.category is distinct from p_category or (p_active and not v_current.is_active)) then
    raise exception 'category_retired';
  end if;
  -- Every workflow keeps the backlog status and an active status of each of
  -- the five categories the cycle needs (v9).
  if p_status is not null then
    if v_current.key = 'backlog' and p_category <> 'backlog' then
      raise exception 'status_required';
    end if;
    if v_current.is_active and v_current.category in ('backlog', 'in_progress', 'in_review', 'approved', 'rejected')
       and (not p_active or p_category <> v_current.category)
       and not exists (select 1 from public.workflow_statuses
                       where workflow_id = p_workflow and category = v_current.category and is_active and id <> p_status) then
      raise exception 'status_required';
    end if;
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

-- New projects (and a new workspace's personal workflow) get the five-status
-- workflow (proposal §2) with exactly the seven final edges.
CREATE OR REPLACE FUNCTION app.seed_workflow(p_workspace uuid, p_project uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_workflow uuid;
  v_name text := case when p_project is null then 'شخصی' else 'پیش‌فرض' end;
begin
  insert into public.workflows (workspace_id, project_id, name)
  values (p_workspace, p_project, v_name)
  returning id into v_workflow;

  insert into public.workflow_statuses (workflow_id, key, name, category, position, requires_authority)
  values
    (v_workflow, 'backlog', 'در صف انجام', 'backlog', 1, false),
    (v_workflow, 'in_progress', 'در حال انجام', 'in_progress', 2, false),
    (v_workflow, 'in_review', 'در حال بررسی', 'in_review', 3, false),
    (v_workflow, 'approved', 'تأیید شده', 'approved', 4, true),
    (v_workflow, 'rejected', 'رد شده', 'rejected', 5, true);

  -- Edges and the only server path that may use each:
  --   backlog -> in_progress: transition_task: start, primary assignee only
  --   in_progress -> in_review: submit_task_for_review: primary assignee only, approval required
  --   in_review -> approved: decide_task approved: eligible reviewer, never the assignee
  --   in_review -> backlog: decide_task revision_requested: eligible reviewer, what + why
  --   in_review -> rejected: decide_task rejected: eligible reviewer, reason
  --   in_progress -> approved: complete_task: primary assignee only, approval not required
  --   rejected -> backlog: transition_task: reopen, tasks.manage.project or super admin
  insert into public.workflow_transitions (workflow_id, from_status_id, to_status_id)
  values
    (v_workflow, (select id from public.workflow_statuses where workflow_id = v_workflow and key = 'backlog'),
                 (select id from public.workflow_statuses where workflow_id = v_workflow and key = 'in_progress')),
    (v_workflow, (select id from public.workflow_statuses where workflow_id = v_workflow and key = 'in_progress'),
                 (select id from public.workflow_statuses where workflow_id = v_workflow and key = 'in_review')),
    (v_workflow, (select id from public.workflow_statuses where workflow_id = v_workflow and key = 'in_review'),
                 (select id from public.workflow_statuses where workflow_id = v_workflow and key = 'approved')),
    (v_workflow, (select id from public.workflow_statuses where workflow_id = v_workflow and key = 'in_review'),
                 (select id from public.workflow_statuses where workflow_id = v_workflow and key = 'backlog')),
    (v_workflow, (select id from public.workflow_statuses where workflow_id = v_workflow and key = 'in_review'),
                 (select id from public.workflow_statuses where workflow_id = v_workflow and key = 'rejected')),
    (v_workflow, (select id from public.workflow_statuses where workflow_id = v_workflow and key = 'in_progress'),
                 (select id from public.workflow_statuses where workflow_id = v_workflow and key = 'approved')),
    (v_workflow, (select id from public.workflow_statuses where workflow_id = v_workflow and key = 'rejected'),
                 (select id from public.workflow_statuses where workflow_id = v_workflow and key = 'backlog'));

  return v_workflow;
end;
$function$
;

drop function public.project_sprint_counts(uuid);
CREATE OR REPLACE FUNCTION public.project_sprint_counts(p_project uuid)
 RETURNS TABLE(sprint_id uuid, total integer, complete integer, blocked integer, rejected integer, rejected_group integer, remaining integer)
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
      where t.blocked_at is not null and app.task_is_unresolved(t.id)
    )::integer,
    count(t.id) filter (where st.category = 'rejected')::integer,
    count(t.id) filter (where st.category = 'rejected' or (t.blocked_at is not null and app.task_is_unresolved(t.id)))::integer,
    count(t.id) filter (where app.task_is_open(t.id))::integer
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

drop function public.project_milestone_counts(uuid);
CREATE OR REPLACE FUNCTION public.project_milestone_counts(p_project uuid)
 RETURNS TABLE(milestone_id uuid, total integer, complete integer, blocked integer, rejected integer, rejected_group integer, remaining integer)
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
      where t.blocked_at is not null and app.task_is_unresolved(t.id)
    )::integer,
    count(t.id) filter (where st.category = 'rejected')::integer,
    count(t.id) filter (where st.category = 'rejected' or (t.blocked_at is not null and app.task_is_unresolved(t.id)))::integer,
    count(t.id) filter (where app.task_is_open(t.id))::integer
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
  v_rejected integer;
  v_remaining integer;
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
        where t.blocked_at is not null and app.task_is_unresolved(t.id)
      )::integer,
      count(t.id) filter (where st.category = 'rejected')::integer,
      count(t.id) filter (where app.task_is_open(t.id))::integer
    into v_total, v_complete, v_blocked, v_rejected, v_remaining
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
            'rejected', v_rejected,
            'remaining', v_remaining,
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
      and app.task_is_open(t.id)
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
      and app.task_is_open(t.id);
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
          and app.task_is_open(t.id)
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
          and app.task_is_open(t.id)
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
          and app.can_view_task(t.id) and app.task_is_open(t.id)
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
          and app.task_is_open(t.id)
      ),
      'project_tasks', (
        select count(*) from public.tasks t
        where t.primary_assignee_id = v_me and t.project_id is not null and t.archived_at is null
          and app.can_view_task(t.id) and app.task_is_open(t.id)
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
        and app.can_view_task(t.id) and app.task_is_open(t.id)
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
        and app.task_is_open(t.id)
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
        and app.task_is_open(t.id)
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
        count(*) filter (where app.task_is_open(t.id))::integer as active_tasks,
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
        and app.task_is_open(t.id)
    ),
    'project_tasks', (
      select count(*) from public.tasks t
      where t.primary_assignee_id = v_me and t.project_id is not null and t.archived_at is null
        and app.can_view_task(t.id) and app.task_is_open(t.id)
    ),
    'rejected_tasks', (
      select count(*) from public.tasks t
      join public.workflow_statuses s on s.id = t.status_id
      where t.primary_assignee_id = v_me and t.archived_at is null and app.can_view_task(t.id) and s.category = 'rejected'
    ),
    'blocked_tasks', (
      select count(*) from public.tasks t
      where t.primary_assignee_id = v_me and t.blocked_at is not null and app.can_view_task(t.id)
        and app.task_is_unresolved(t.id)
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
    'rejected', (
      select count(*) from public.tasks t
      join public.workflow_statuses s on s.id = t.status_id
      where t.archived_at is null and app.can_view_task(t.id) and s.category = 'rejected'
        and (p_project is null or t.project_id = p_project)
    ),
    'rejected_group', (
      select count(*) from public.tasks t
      join public.workflow_statuses s on s.id = t.status_id
      where t.archived_at is null and app.can_view_task(t.id)
        and (s.category = 'rejected' or (t.blocked_at is not null and app.task_is_unresolved(t.id)))
        and (p_project is null or t.project_id = p_project)
    ),
    'remaining', (
      select count(*) from public.tasks t
      where t.archived_at is null and app.can_view_task(t.id) and app.task_is_open(t.id)
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
      where t.archived_at is null and app.can_view_task(t.id) and t.blocked_at is not null
        and app.task_is_unresolved(t.id)
        and (p_project is null or t.project_id = p_project)
    ),
    'overdue', (
      select count(*) from public.tasks t
      where t.archived_at is null and app.can_view_task(t.id)
        and t.due_at < clock_timestamp() and app.task_is_open(t.id)
        and (p_project is null or t.project_id = p_project)
    ),
    'sprints', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', s.id, 'project_id', s.project_id, 'name', s.name, 'status', s.status,
        'start_date', s.start_date, 'end_date', s.end_date,
        'total', coalesce(c.total, 0), 'complete', coalesce(c.complete, 0),
        'rejected', coalesce(c.rejected, 0), 'blocked', coalesce(c.blocked, 0),
        'remaining', coalesce(c.open, 0),
        'percent', case when coalesce(c.total, 0) = 0 then 0 else (c.complete * 100 / c.total) end,
        'summary', s.summary
      ) order by s.start_date desc, s.id)
      from public.sprints s
      left join lateral (
        select count(t.id)::integer as total,
          count(t.id) filter (where app.task_counts_complete(t.id))::integer as complete,
          count(t.id) filter (where exists (select 1 from public.workflow_statuses st
                                            where st.id = t.status_id and st.category = 'rejected'))::integer as rejected,
          count(t.id) filter (where t.blocked_at is not null and app.task_is_unresolved(t.id))::integer as blocked,
          count(t.id) filter (where app.task_is_open(t.id))::integer as open
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
        'rejected', coalesce(c.rejected, 0), 'blocked', coalesce(c.blocked, 0),
        'remaining', coalesce(c.open, 0),
        'percent', case when coalesce(c.total, 0) = 0 then 0 else (c.complete * 100 / c.total) end
      ) order by m.target_date, m.id)
      from public.milestones m
      left join lateral (
        select count(t.id)::integer as total,
          count(t.id) filter (where app.task_counts_complete(t.id))::integer as complete,
          count(t.id) filter (where exists (select 1 from public.workflow_statuses st
                                            where st.id = t.status_id and st.category = 'rejected'))::integer as rejected,
          count(t.id) filter (where t.blocked_at is not null and app.task_is_unresolved(t.id))::integer as blocked,
          count(t.id) filter (where app.task_is_open(t.id))::integer as open
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


-- -----------------------------------------------------------------------------
-- 11. Privileges. Real defaults of this database (pg_default_acl): new objects in
--     schema public get EXECUTE / ALL for anon and authenticated, and functions in
--     schema app get EXECUTE for PUBLIC. Nothing here relies on defaults:
--     every grant is revoked, then granted explicitly.
-- -----------------------------------------------------------------------------
revoke all on table public.task_block_events from public, anon, authenticated, service_role;
grant select on table public.task_block_events to authenticated, service_role;
revoke all on table public.task_revision_requests from public, anon, authenticated, service_role;
grant select on table public.task_revision_requests to authenticated, service_role;
revoke insert, update, delete, truncate, trigger, references on table public.task_review_rounds from public, anon, authenticated, service_role;
revoke insert, update, delete, truncate, trigger, references on table public.task_reviews from public, anon, authenticated, service_role;
revoke insert, update, delete, truncate, trigger, references on table public.task_activity_events from public, anon, authenticated, service_role;
revoke all on table public.workflow_status_migration_log from public, anon, authenticated, service_role;
revoke all on table public.workflow_status_migration_report from public, anon, authenticated, service_role;
revoke all on table public.workflow_status_changes from public, anon, authenticated, service_role;
revoke all on table public.workflow_migration_added_transitions from public, anon, authenticated, service_role;
revoke all on table public.workflow_rollback_runs from public, anon, authenticated, service_role;
revoke all on sequence public.workflow_status_migration_log_id_seq from public, anon, authenticated, service_role;
revoke all on sequence public.workflow_status_migration_report_id_seq from public, anon, authenticated, service_role;
revoke all on sequence public.workflow_rollback_runs_id_seq from public, anon, authenticated, service_role;
revoke all on function app.person_label(uuid) from public, anon, authenticated, service_role;
revoke all on function app.person_json(uuid) from public, anon, authenticated, service_role;
revoke all on function app.require_active_member(uuid, uuid, text) from public, anon, authenticated, service_role;
revoke all on function app.require_active_profile(uuid, text) from public, anon, authenticated, service_role;
revoke all on function app.personal_assign_scope(uuid) from public, anon, authenticated, service_role;
revoke all on function app.task_snapshot(uuid) from public, anon, authenticated, service_role;
revoke all on function app.can_act_on_task(public.tasks) from public, anon, authenticated, service_role;
revoke all on function app.can_decide_task(public.tasks) from public, anon, authenticated, service_role;
revoke all on function app.workflow_status(uuid, text) from public, anon, authenticated, service_role;
revoke all on function app.open_round(uuid) from public, anon, authenticated, service_role;
revoke all on function app.task_is_unresolved(uuid) from public, anon, authenticated, service_role;
revoke all on function app.task_is_open(uuid) from public, anon, authenticated, service_role;
revoke all on function app.open_tasks_of_member(uuid, uuid, integer) from public, anon, authenticated, service_role;
revoke all on function app.apply_review_changes(public.tasks, uuid, jsonb) from public, anon, authenticated, service_role;
revoke all on function app.protect_review_round() from public, anon, authenticated, service_role;
revoke all on function app.reject_change() from public, anon, authenticated, service_role;
revoke all on function app.require_revision_request() from public, anon, authenticated, service_role;
revoke all on function app.check_revision_request() from public, anon, authenticated, service_role;
revoke all on function public.project_member_directory(uuid) from public, anon;
grant execute on function public.project_member_directory(uuid) to authenticated, service_role;
revoke all on function public.project_member_open_tasks(uuid, uuid, integer) from public, anon;
grant execute on function public.project_member_open_tasks(uuid, uuid, integer) to authenticated, service_role;
revoke all on function public.submit_task_for_review(uuid) from public, anon;
grant execute on function public.submit_task_for_review(uuid) to authenticated, service_role;
revoke all on function public.review_update_task(uuid, uuid, jsonb) from public, anon;
grant execute on function public.review_update_task(uuid, uuid, jsonb) to authenticated, service_role;
revoke all on function public.decide_task(uuid, text, uuid, text, text, jsonb, text) from public, anon;
grant execute on function public.decide_task(uuid, text, uuid, text, text, jsonb, text) to authenticated, service_role;
revoke all on function public.complete_task(uuid, text) from public, anon;
grant execute on function public.complete_task(uuid, text) to authenticated, service_role;
revoke all on function public.set_task_blocked(uuid, text) from public, anon;
grant execute on function public.set_task_blocked(uuid, text) to authenticated, service_role;
revoke all on function public.clear_task_blocked(uuid, text) from public, anon;
grant execute on function public.clear_task_blocked(uuid, text) to authenticated, service_role;
grant execute on function public.project_sprint_counts(uuid) to authenticated, service_role;  -- recreated (return type): same grants as before
grant execute on function public.project_milestone_counts(uuid) to authenticated, service_role;  -- recreated (return type): same grants as before
revoke all on function public.create_task(text, text, uuid, uuid, text, timestamptz, boolean, uuid, uuid, boolean) from public, anon;  -- ACL unchanged: postgres, authenticated, service_role
revoke all on function public.update_task(uuid, text, text, uuid, uuid, text, timestamptz, boolean) from public, anon;  -- ACL unchanged: postgres, authenticated, service_role
revoke all on function public.transition_task(uuid, uuid, text) from public, anon;  -- ACL unchanged: postgres, authenticated, service_role
revoke all on function public.add_task_collaborator(uuid, uuid) from public, anon;  -- ACL unchanged: postgres, authenticated, service_role
revoke all on function public.remove_project_member(uuid, uuid) from public, anon;  -- ACL unchanged: postgres, authenticated, service_role
revoke all on function public.remove_task_collaborator(uuid, uuid) from public, anon;  -- ACL unchanged: postgres, authenticated, service_role
revoke all on function public.set_task_labels(uuid, uuid[]) from public, anon;  -- ACL unchanged: postgres, authenticated, service_role
revoke all on function public.add_checklist_item(uuid, text) from public, anon;  -- ACL unchanged: postgres, authenticated, service_role
revoke all on function public.toggle_checklist_item(uuid, boolean) from public, anon;  -- ACL unchanged: postgres, authenticated, service_role
revoke all on function public.rename_checklist_item(uuid, text) from public, anon;  -- ACL unchanged: postgres, authenticated, service_role
revoke all on function public.delete_checklist_item(uuid) from public, anon;  -- ACL unchanged: postgres, authenticated, service_role
revoke all on function public.move_checklist_item(uuid, integer) from public, anon;  -- ACL unchanged: postgres, authenticated, service_role
revoke all on function app.task_visible_directly(uuid, uuid, uuid) from public, anon, authenticated;  -- otherwise unchanged (postgres; service_role where it had it)
revoke all on function public.save_workflow_status(uuid, uuid, text, text, integer, boolean, boolean) from public, anon;  -- ACL unchanged: postgres, authenticated, service_role
revoke all on function app.seed_workflow(uuid, uuid) from public, anon, authenticated;  -- otherwise unchanged (postgres; service_role where it had it)
revoke all on function public.project_sprint_counts(uuid) from public, anon;  -- ACL unchanged: postgres, authenticated, service_role
revoke all on function public.project_milestone_counts(uuid) from public, anon;  -- ACL unchanged: postgres, authenticated, service_role
revoke all on function public.set_sprint_status(uuid, text) from public, anon;  -- ACL unchanged: postgres, authenticated, service_role
revoke all on function public.transfer_sprint_remainder(uuid, uuid) from public, anon;  -- ACL unchanged: postgres, authenticated, service_role
revoke all on function public.set_milestone_status(uuid, text, text) from public, anon;  -- ACL unchanged: postgres, authenticated, service_role
revoke all on function app.dashboard_summary_v1() from public, anon, authenticated;  -- otherwise unchanged (postgres; service_role where it had it)
revoke all on function public.dashboard_projects() from public, anon;  -- ACL unchanged: postgres, authenticated, service_role
revoke all on function public.dashboard_team() from public, anon;  -- ACL unchanged: postgres, authenticated, service_role
revoke all on function public.dashboard_people(text, uuid, text, boolean, integer, integer) from public, anon;  -- ACL unchanged: postgres, authenticated, service_role
revoke all on function public.dashboard_personal() from public, anon;  -- ACL unchanged: postgres, authenticated, service_role
revoke all on function public.work_analytics(uuid) from public, anon;  -- ACL unchanged: postgres, authenticated, service_role

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
                      'decide_task', 'complete_task', 'set_task_blocked', 'clear_task_blocked', 'create_task', 'update_task', 'transition_task',
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
