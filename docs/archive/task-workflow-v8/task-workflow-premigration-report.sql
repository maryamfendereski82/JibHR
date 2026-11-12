-- =============================================================================
-- Pre-migration report for docs/task-workflow-migration-draft.sql. Generated.
-- READ ONLY: a read-only transaction that is rolled back; it creates nothing.
-- The plan, workflow classification and integrity queries are the same text
-- the migration uses (proposal §4), so report and migration cannot disagree.
-- Usage (local only):
--   docker exec -i supabase_db_jibhr psql -U postgres -d postgres -P pager=off -v ON_ERROR_STOP=1 \
--     < docs/task-workflow-premigration-report.sql
-- =============================================================================
begin transaction read only;

\echo '== R1. Workflow classification (default = exact status set and transition set) =='
with wf as (
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
select workflow_id, is_default from wf
)
select coalesce(p.name, '(personal)') as workflow, wf.workflow_id, wf.is_default
from wf join public.workflows w on w.id = wf.workflow_id left join public.projects p on p.id = w.project_id
order by 1;

\echo '== R2. Tasks per status, every workflow =='
select coalesce(p.name, '(personal)') as workflow, s.key, s.name, s.category, s.is_active,
  count(t.id) as tasks, count(t.id) filter (where t.archived_at is null) as open_tasks
from public.workflows w left join public.projects p on p.id = w.project_id
join public.workflow_statuses s on s.workflow_id = w.id
left join public.tasks t on t.status_id = s.id
group by 1, s.key, s.name, s.category, s.is_active, s.position
order by 1, s.position;

\echo '== R3. Plan: every task the migration looks at (decision, source, target) =='
with plan as (
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
            and not exists (select 1 from public.task_reviews v where v.round_id = r.id)) as has_open_round
  from public.tasks t
  join public.workflow_statuses s on s.id = t.status_id
  join wf on wf.workflow_id = s.workflow_id
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
  case
    when ts.task_id in (select task_id from excluded) then null
    when not ts.is_default then null
    when ts.key in ('todo', 'in_progress', 'changes_requested') then 'backlog'
    when ts.key = 'approved' and ts.approval_state in ('approved', 'not_required') then 'done'
    when ts.key = 'blocked' and bb.prev_key in ('backlog', 'todo', 'in_progress', 'changes_requested') then 'backlog'
    when ts.key = 'blocked' and bb.prev_key = 'in_review' and ts.approval_required and ts.has_open_round then 'in_review'
    else null
  end as to_key,
  case
    when ts.task_id in (select task_id from excluded) then 'excluded'
    when not ts.is_default and ts.key in ('todo', 'in_progress', 'blocked', 'changes_requested', 'approved') then 'custom_workflow'
    when not ts.is_default then 'keep'
    when ts.key in ('todo', 'in_progress', 'changes_requested') then 'move'
    when ts.key = 'approved' and ts.approval_state in ('approved', 'not_required') then 'move'
    when ts.key = 'approved' then 'ambiguous_approved_without_approval'
    when ts.key = 'blocked' and bb.prev_key in ('backlog', 'todo', 'in_progress', 'changes_requested') then 'move'
    when ts.key = 'blocked' and bb.prev_key = 'in_review' and ts.approval_required and ts.has_open_round then 'move'
    when ts.key = 'blocked' then 'ambiguous_blocked_previous_unknown'
    when ts.key = 'in_review' and (not ts.approval_required or not ts.has_open_round) then 'ambiguous_in_review_without_round'
    else 'keep'
  end as decision,
  ts.key = 'blocked' as blocked_set
from task_state ts
left join before_block bb on bb.task_id = ts.task_id
where ts.key in ('todo', 'in_progress', 'blocked', 'changes_requested', 'approved') or ts.key = 'in_review' or ts.task_id in (select task_id from excluded)
)
select plan.decision, plan.task_id, t.title, plan.from_key, plan.to_key, plan.blocked_set
from plan join public.tasks t on t.id = plan.task_id
where plan.decision <> 'keep'
order by plan.decision, t.title;

\echo '== R4. Integrity findings (assignee / reviewer / collaborator membership and activity, personal for other, open rounds) =='
with integrity as (
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
select 'open_round', r.task_id from public.task_review_rounds r where not exists (select 1 from public.task_reviews v where v.round_id = r.id)
)
select i.kind, i.task_id, t.title from integrity i join public.tasks t on t.id = i.task_id order by 1, 3;

\echo '== R5. Pinned tasks (2 excluded + 2 moved): exact current state (same SQL and columns as guard (c)) =='
select t.id::text as task_id, t.title, t.project_id is null as personal, s.key as status_key, t.approval_state,
       t.approval_required, t.primary_assignee_id::text as assignee, t.created_by::text as created_by,
       t.reviewer_id::text as reviewer, t.project_id::text as project_id, pr.name as project_name,
       s.workflow_id::text as workflow_id, t.status_id::text as status_id, t.workspace_id::text as workspace_id,
       t.archived_at is null as not_archived
from public.tasks t join public.workflow_statuses s on s.id = t.status_id
left join public.projects pr on pr.id = t.project_id
where t.id in ('47d8d5a3-6354-4c97-8ccd-7f56ef8923e4'::uuid, 'cf890d3d-6396-432c-93b0-a8bb59593830'::uuid, 'f4725489-31c7-4c03-8698-984e4435ebcc'::uuid, '30445be8-9067-44fb-818d-9380d7a46575'::uuid);

\echo '== R6. Review history =='
select count(*) as rounds,
  count(*) filter (where not exists (select 1 from public.task_reviews v where v.round_id = r.id)) as open_rounds
from public.task_review_rounds r;
select decision, count(*) as decisions,
  count(*) filter (where reason like 'اصلاح موردنیاز:%') as interim_two_part_reasons
from public.task_reviews group by decision;

\echo '== R8. Retired statuses (todo «انجام‌نشده», in_progress, blocked, changes_requested, approved): tasks now, moved by the plan, left after it =='
with plan as (
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
            and not exists (select 1 from public.task_reviews v where v.round_id = r.id)) as has_open_round
  from public.tasks t
  join public.workflow_statuses s on s.id = t.status_id
  join wf on wf.workflow_id = s.workflow_id
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
  case
    when ts.task_id in (select task_id from excluded) then null
    when not ts.is_default then null
    when ts.key in ('todo', 'in_progress', 'changes_requested') then 'backlog'
    when ts.key = 'approved' and ts.approval_state in ('approved', 'not_required') then 'done'
    when ts.key = 'blocked' and bb.prev_key in ('backlog', 'todo', 'in_progress', 'changes_requested') then 'backlog'
    when ts.key = 'blocked' and bb.prev_key = 'in_review' and ts.approval_required and ts.has_open_round then 'in_review'
    else null
  end as to_key,
  case
    when ts.task_id in (select task_id from excluded) then 'excluded'
    when not ts.is_default and ts.key in ('todo', 'in_progress', 'blocked', 'changes_requested', 'approved') then 'custom_workflow'
    when not ts.is_default then 'keep'
    when ts.key in ('todo', 'in_progress', 'changes_requested') then 'move'
    when ts.key = 'approved' and ts.approval_state in ('approved', 'not_required') then 'move'
    when ts.key = 'approved' then 'ambiguous_approved_without_approval'
    when ts.key = 'blocked' and bb.prev_key in ('backlog', 'todo', 'in_progress', 'changes_requested') then 'move'
    when ts.key = 'blocked' and bb.prev_key = 'in_review' and ts.approval_required and ts.has_open_round then 'move'
    when ts.key = 'blocked' then 'ambiguous_blocked_previous_unknown'
    when ts.key = 'in_review' and (not ts.approval_required or not ts.has_open_round) then 'ambiguous_in_review_without_round'
    else 'keep'
  end as decision,
  ts.key = 'blocked' as blocked_set
from task_state ts
left join before_block bb on bb.task_id = ts.task_id
where ts.key in ('todo', 'in_progress', 'blocked', 'changes_requested', 'approved') or ts.key = 'in_review' or ts.task_id in (select task_id from excluded)
)
select coalesce(p.name, '(personal)') as workflow, s.key, s.name, s.is_active,
  count(t.id) as tasks_now,
  count(t.id) filter (where pl.decision = 'move') as moved_to_new_status,
  count(t.id) filter (where pl.decision is distinct from 'move') as left_in_retired_status
from public.workflows w left join public.projects p on p.id = w.project_id
join public.workflow_statuses s on s.workflow_id = w.id and s.key in ('todo', 'in_progress', 'blocked', 'changes_requested', 'approved')
left join public.tasks t on t.status_id = s.id
left join plan pl on pl.task_id = t.id
group by 1, s.key, s.name, s.is_active, s.position
order by 1, s.position;
-- Every task left in a retired status, with the reason (expected: only the excluded vvvvvvv).
with plan as (
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
            and not exists (select 1 from public.task_reviews v where v.round_id = r.id)) as has_open_round
  from public.tasks t
  join public.workflow_statuses s on s.id = t.status_id
  join wf on wf.workflow_id = s.workflow_id
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
  case
    when ts.task_id in (select task_id from excluded) then null
    when not ts.is_default then null
    when ts.key in ('todo', 'in_progress', 'changes_requested') then 'backlog'
    when ts.key = 'approved' and ts.approval_state in ('approved', 'not_required') then 'done'
    when ts.key = 'blocked' and bb.prev_key in ('backlog', 'todo', 'in_progress', 'changes_requested') then 'backlog'
    when ts.key = 'blocked' and bb.prev_key = 'in_review' and ts.approval_required and ts.has_open_round then 'in_review'
    else null
  end as to_key,
  case
    when ts.task_id in (select task_id from excluded) then 'excluded'
    when not ts.is_default and ts.key in ('todo', 'in_progress', 'blocked', 'changes_requested', 'approved') then 'custom_workflow'
    when not ts.is_default then 'keep'
    when ts.key in ('todo', 'in_progress', 'changes_requested') then 'move'
    when ts.key = 'approved' and ts.approval_state in ('approved', 'not_required') then 'move'
    when ts.key = 'approved' then 'ambiguous_approved_without_approval'
    when ts.key = 'blocked' and bb.prev_key in ('backlog', 'todo', 'in_progress', 'changes_requested') then 'move'
    when ts.key = 'blocked' and bb.prev_key = 'in_review' and ts.approval_required and ts.has_open_round then 'move'
    when ts.key = 'blocked' then 'ambiguous_blocked_previous_unknown'
    when ts.key = 'in_review' and (not ts.approval_required or not ts.has_open_round) then 'ambiguous_in_review_without_round'
    else 'keep'
  end as decision,
  ts.key = 'blocked' as blocked_set
from task_state ts
left join before_block bb on bb.task_id = ts.task_id
where ts.key in ('todo', 'in_progress', 'blocked', 'changes_requested', 'approved') or ts.key = 'in_review' or ts.task_id in (select task_id from excluded)
)
select t.id, t.title, s.key, coalesce(pl.decision, 'not_in_plan') as decision
from public.tasks t join public.workflow_statuses s on s.id = t.status_id
left join plan pl on pl.task_id = t.id
where s.key in ('todo', 'in_progress', 'blocked', 'changes_requested', 'approved') and pl.decision is distinct from 'move'
order by s.key, t.title;

\echo '== R7. Guard comparison: empty result = data matches the reviewed expectations =='
with wf as (
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
select workflow_id, is_default from wf
), plan as (
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
            and not exists (select 1 from public.task_reviews v where v.round_id = r.id)) as has_open_round
  from public.tasks t
  join public.workflow_statuses s on s.id = t.status_id
  join wf on wf.workflow_id = s.workflow_id
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
  case
    when ts.task_id in (select task_id from excluded) then null
    when not ts.is_default then null
    when ts.key in ('todo', 'in_progress', 'changes_requested') then 'backlog'
    when ts.key = 'approved' and ts.approval_state in ('approved', 'not_required') then 'done'
    when ts.key = 'blocked' and bb.prev_key in ('backlog', 'todo', 'in_progress', 'changes_requested') then 'backlog'
    when ts.key = 'blocked' and bb.prev_key = 'in_review' and ts.approval_required and ts.has_open_round then 'in_review'
    else null
  end as to_key,
  case
    when ts.task_id in (select task_id from excluded) then 'excluded'
    when not ts.is_default and ts.key in ('todo', 'in_progress', 'blocked', 'changes_requested', 'approved') then 'custom_workflow'
    when not ts.is_default then 'keep'
    when ts.key in ('todo', 'in_progress', 'changes_requested') then 'move'
    when ts.key = 'approved' and ts.approval_state in ('approved', 'not_required') then 'move'
    when ts.key = 'approved' then 'ambiguous_approved_without_approval'
    when ts.key = 'blocked' and bb.prev_key in ('backlog', 'todo', 'in_progress', 'changes_requested') then 'move'
    when ts.key = 'blocked' and bb.prev_key = 'in_review' and ts.approval_required and ts.has_open_round then 'move'
    when ts.key = 'blocked' then 'ambiguous_blocked_previous_unknown'
    when ts.key = 'in_review' and (not ts.approval_required or not ts.has_open_round) then 'ambiguous_in_review_without_round'
    else 'keep'
  end as decision,
  ts.key = 'blocked' as blocked_set
from task_state ts
left join before_block bb on bb.task_id = ts.task_id
where ts.key in ('todo', 'in_progress', 'blocked', 'changes_requested', 'approved') or ts.key = 'in_review' or ts.task_id in (select task_id from excluded)
), integrity as (
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
select 'open_round', r.task_id from public.task_review_rounds r where not exists (select 1 from public.task_reviews v where v.round_id = r.id)
), pinned_state as (
select t.id::text as task_id, t.title, t.project_id is null as personal, s.key as status_key, t.approval_state,
       t.approval_required, t.primary_assignee_id::text as assignee, t.created_by::text as created_by,
       t.reviewer_id::text as reviewer, t.project_id::text as project_id, pr.name as project_name,
       s.workflow_id::text as workflow_id, t.status_id::text as status_id, t.workspace_id::text as workspace_id,
       t.archived_at is null as not_archived
from public.tasks t join public.workflow_statuses s on s.id = t.status_id
left join public.projects pr on pr.id = t.project_id
where t.id in ('47d8d5a3-6354-4c97-8ccd-7f56ef8923e4'::uuid, 'cf890d3d-6396-432c-93b0-a8bb59593830'::uuid, 'f4725489-31c7-4c03-8698-984e4435ebcc'::uuid, '30445be8-9067-44fb-818d-9380d7a46575'::uuid)
),
expected_pinned (task_id, title, personal, status_key, approval_state, approval_required, assignee, created_by, reviewer, project_id, project_name, workflow_id, status_id, workspace_id, not_archived) as (values
    ('47d8d5a3-6354-4c97-8ccd-7f56ef8923e4', 'rgdfdgf', false, 'backlog', 'pending', true, '8d2697db-f8b7-4ee7-b714-f58511e3c173', '06c2ffaf-8db2-4413-95ef-5b6d7d93c8f5', null, 'c4fa2aef-59a5-478a-8667-32777e793d91', 'باگ بانتی', '92986332-ac6f-4467-9762-abb6b6463f3a', '6aa7533b-fae5-46fe-8443-86908ec7628e', 'a0000000-0000-4000-8000-000000000001', true),
    ('cf890d3d-6396-432c-93b0-a8bb59593830', 'vvvvvvv', true, 'approved', 'not_required', false, '0ab53a33-b9a3-407c-b977-45856a42fe96', '06c2ffaf-8db2-4413-95ef-5b6d7d93c8f5', '0ab53a33-b9a3-407c-b977-45856a42fe96', null, null, '397a6e0a-c058-4f59-856a-b77f57f83c5c', 'e7216b79-af18-4aea-8dd0-ff9af01f7192', 'a0000000-0000-4000-8000-000000000001', true),
    ('f4725489-31c7-4c03-8698-984e4435ebcc', 'ttt', true, 'changes_requested', 'not_required', false, '8d2697db-f8b7-4ee7-b714-f58511e3c173', '8d2697db-f8b7-4ee7-b714-f58511e3c173', null, null, null, '397a6e0a-c058-4f59-856a-b77f57f83c5c', 'e0655322-8cb1-487f-8cb2-3985494f169a', 'a0000000-0000-4000-8000-000000000001', true),
    ('30445be8-9067-44fb-818d-9380d7a46575', 'لندینگ باگ بانتی', true, 'approved', 'approved', true, '06c2ffaf-8db2-4413-95ef-5b6d7d93c8f5', '06c2ffaf-8db2-4413-95ef-5b6d7d93c8f5', null, null, null, '397a6e0a-c058-4f59-856a-b77f57f83c5c', 'e7216b79-af18-4aea-8dd0-ff9af01f7192', 'a0000000-0000-4000-8000-000000000001', true)
),
expected_wf (workflow_id) as (values
    ('397a6e0a-c058-4f59-856a-b77f57f83c5c'),
    ('7c934bc9-0038-441e-9cdc-bb55002e809d'),
    ('92986332-ac6f-4467-9762-abb6b6463f3a'),
    ('3f3262cf-df3c-4c4e-8631-48dccc2728c3'),
    ('cb3fe4b1-be2e-4f2f-a7e6-a0583140a11f')
),
expected_plan (task_id, from_key, to_key, decision) as (values
    ('f4725489-31c7-4c03-8698-984e4435ebcc', 'changes_requested', 'backlog', 'move'),
    ('30445be8-9067-44fb-818d-9380d7a46575', 'approved', 'done', 'move'),
    ('47d8d5a3-6354-4c97-8ccd-7f56ef8923e4', 'backlog', null, 'excluded'),
    ('cf890d3d-6396-432c-93b0-a8bb59593830', 'approved', null, 'excluded')
),
expected_integrity (kind, task_id) as (values
    ('assignee_not_member', '47d8d5a3-6354-4c97-8ccd-7f56ef8923e4'),
    ('personal_created_for_other', 'cf890d3d-6396-432c-93b0-a8bb59593830')
)
select 'workflow' as part, x::text as row from (
  (select workflow_id::text from wf where is_default except select workflow_id from expected_wf)
  union all (select workflow_id from expected_wf except select workflow_id::text from wf where is_default)
  union all (select workflow_id::text || ' (custom)' from wf where not is_default)) x(x)
union all
select 'plan', to_jsonb(d)::text from (
  (select task_id::text, from_key, to_key, decision from plan where decision <> 'keep' except select * from expected_plan)
  union all (select * from expected_plan except select task_id::text, from_key, to_key, decision from plan where decision <> 'keep')) d
union all
select 'pinned_state', to_jsonb(d)::text from (
  (select * from pinned_state except select * from expected_pinned)
  union all (select * from expected_pinned except select * from pinned_state)) d
union all
select 'integrity', to_jsonb(d)::text from (
  (select kind, task_id::text from integrity except select * from expected_integrity)
  union all (select * from expected_integrity except select kind, task_id::text from integrity)) d;

rollback;
