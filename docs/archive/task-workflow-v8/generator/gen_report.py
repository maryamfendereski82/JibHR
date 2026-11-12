"""Generates docs/task-workflow-premigration-report.sql (read only) from the shared plan."""
from common import DOCS, DEFAULT_WORKFLOWS, EXCLUDED_TASKS, PINNED_STATE_SELECT, EXPECTED_PINNED_STATE, EXPECTED_INTEGRITY, EXPECTED_PLAN, INTEGRITY_SELECT, PLAN_SELECT, RETIRED, WF_SELECT, values

sql = f"""-- =============================================================================
-- Pre-migration report for docs/task-workflow-migration-draft.sql. Generated.
-- READ ONLY: a read-only transaction that is rolled back; it creates nothing.
-- The plan, workflow classification and integrity queries are the same text
-- the migration uses (proposal §4), so report and migration cannot disagree.
-- Usage (local only):
--   docker exec -i supabase_db_jibhr psql -U postgres -d postgres -P pager=off -v ON_ERROR_STOP=1 \\
--     < docs/task-workflow-premigration-report.sql
-- =============================================================================
begin transaction read only;

\\echo '== R1. Workflow classification (default = exact status set and transition set) =='
with wf as (
{WF_SELECT.strip()}
)
select coalesce(p.name, '(personal)') as workflow, wf.workflow_id, wf.is_default
from wf join public.workflows w on w.id = wf.workflow_id left join public.projects p on p.id = w.project_id
order by 1;

\\echo '== R2. Tasks per status, every workflow =='
select coalesce(p.name, '(personal)') as workflow, s.key, s.name, s.category, s.is_active,
  count(t.id) as tasks, count(t.id) filter (where t.archived_at is null) as open_tasks
from public.workflows w left join public.projects p on p.id = w.project_id
join public.workflow_statuses s on s.workflow_id = w.id
left join public.tasks t on t.status_id = s.id
group by 1, s.key, s.name, s.category, s.is_active, s.position
order by 1, s.position;

\\echo '== R3. Plan: every task the migration looks at (decision, source, target) =='
with plan as (
{PLAN_SELECT.strip()}
)
select plan.decision, plan.task_id, t.title, plan.from_key, plan.to_key, plan.blocked_set
from plan join public.tasks t on t.id = plan.task_id
where plan.decision <> 'keep'
order by plan.decision, t.title;

\\echo '== R4. Integrity findings (assignee / reviewer / collaborator membership and activity, personal for other, open rounds) =='
with integrity as (
{INTEGRITY_SELECT.strip()}
)
select i.kind, i.task_id, t.title from integrity i join public.tasks t on t.id = i.task_id order by 1, 3;

\\echo '== R5. Pinned tasks (2 excluded + 2 moved): exact current state (same SQL and columns as guard (c)) =='
{PINNED_STATE_SELECT.strip()};

\\echo '== R6. Review history =='
select count(*) as rounds,
  count(*) filter (where not exists (select 1 from public.task_reviews v where v.round_id = r.id)) as open_rounds
from public.task_review_rounds r;
select decision, count(*) as decisions,
  count(*) filter (where reason like 'اصلاح موردنیاز:%') as interim_two_part_reasons
from public.task_reviews group by decision;

\\echo '== R8. Retired statuses (todo «انجام‌نشده», in_progress, blocked, changes_requested, approved): tasks now, moved by the plan, left after it =='
with plan as (
{PLAN_SELECT.strip()}
)
select coalesce(p.name, '(personal)') as workflow, s.key, s.name, s.is_active,
  count(t.id) as tasks_now,
  count(t.id) filter (where pl.decision = 'move') as moved_to_new_status,
  count(t.id) filter (where pl.decision is distinct from 'move') as left_in_retired_status
from public.workflows w left join public.projects p on p.id = w.project_id
join public.workflow_statuses s on s.workflow_id = w.id and s.key in {RETIRED!r}
left join public.tasks t on t.status_id = s.id
left join plan pl on pl.task_id = t.id
group by 1, s.key, s.name, s.is_active, s.position
order by 1, s.position;
-- Every task left in a retired status, with the reason (expected: only the excluded vvvvvvv).
with plan as (
{PLAN_SELECT.strip()}
)
select t.id, t.title, s.key, coalesce(pl.decision, 'not_in_plan') as decision
from public.tasks t join public.workflow_statuses s on s.id = t.status_id
left join plan pl on pl.task_id = t.id
where s.key in {RETIRED!r} and pl.decision is distinct from 'move'
order by s.key, t.title;

\\echo '== R7. Guard comparison: empty result = data matches the reviewed expectations =='
with wf as (
{WF_SELECT.strip()}
), plan as (
{PLAN_SELECT.strip()}
), integrity as (
{INTEGRITY_SELECT.strip()}
), pinned_state as (
{PINNED_STATE_SELECT.strip()}
),
expected_pinned (task_id, title, personal, status_key, approval_state, approval_required, assignee, created_by, reviewer, project_id, project_name, workflow_id, status_id, workspace_id, not_archived) as (values
    {values(EXPECTED_PINNED_STATE)}
),
expected_wf (workflow_id) as (values
    {values([(w,) for w in DEFAULT_WORKFLOWS])}
),
expected_plan (task_id, from_key, to_key, decision) as (values
    {values(EXPECTED_PLAN)}
),
expected_integrity (kind, task_id) as (values
    {values(EXPECTED_INTEGRITY)}
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
"""
(DOCS / 'task-workflow-premigration-report.sql').write_text(sql, encoding='utf-8')
print('report ok')
