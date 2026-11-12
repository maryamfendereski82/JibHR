"""Shared pieces of the generated drafts: dumps, exact patching, the plan SQL."""
import pathlib

HERE = pathlib.Path(__file__).resolve().parent
DUMPS = HERE / 'fndefs'                     # refreshed by dump_functions.sh (read only)
DOCS = HERE.parents[1] / 'docs'             # generated drafts go to docs/
SCRATCH = HERE                              # generator outputs (changed-functions.txt)


def dump(name: str, raw: bool = False) -> str:
    """Current definition as pg_get_functiondef returned it. The live bodies
    contain CRLF (their migration files are CRLF): raw=True keeps every byte
    (rollback); otherwise line ends are normalised to LF (new bodies)."""
    text = (DUMPS / f'{name}.sql').read_bytes().decode('utf-8')
    if not raw:
        text = text.replace(chr(13) + chr(10), chr(10))
    text = text.strip(chr(32) + chr(10))
    assert text.startswith('CREATE OR REPLACE FUNCTION'), name
    return text


def patch(text: str, old: str, new: str, name: str) -> str:
    """Replace exactly one occurrence; anything else is a generator error."""
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{name}: expected 1 match, found {count}:\n{old[:200]}')
    return text.replace(old, new)


# ----------------------------------------------------------------------------- reviewed expectations
# Values of the reviewed pre-migration report. The guard compares the live data
# with these, row by row; any difference aborts the migration.
DEFAULT_WORKFLOWS = [
    '397a6e0a-c058-4f59-856a-b77f57f83c5c',  # personal
    '7c934bc9-0038-441e-9cdc-bb55002e809d',  # QA پروژه
    '92986332-ac6f-4467-9762-abb6b6463f3a',  # باگ بانتی
    '3f3262cf-df3c-4c4e-8631-48dccc2728c3',  # بلبلل
    'cb3fe4b1-be2e-4f2f-a7e6-a0583140a11f',  # محصول محلی
]
WORKSPACE = 'a0000000-0000-4000-8000-000000000001'
PERSONAL_WORKFLOW = '397a6e0a-c058-4f59-856a-b77f57f83c5c'
BUG_BOUNTY_PROJECT = 'c4fa2aef-59a5-478a-8667-32777e793d91'      # «باگ بانتی»
BUG_BOUNTY_WORKFLOW = '92986332-ac6f-4467-9762-abb6b6463f3a'

EXCLUDED_TASKS = {
    # id: (title, project is null, status key, approval_state, approval_required, assignee, created_by, reviewer,
    #      project_id, project name, workflow_id, status_id, workspace_id)
    '47d8d5a3-6354-4c97-8ccd-7f56ef8923e4': ('rgdfdgf', False, 'backlog', 'pending', True,
                                             '8d2697db-f8b7-4ee7-b714-f58511e3c173', '06c2ffaf-8db2-4413-95ef-5b6d7d93c8f5', None,
                                             BUG_BOUNTY_PROJECT, 'باگ بانتی', BUG_BOUNTY_WORKFLOW,
                                             '6aa7533b-fae5-46fe-8443-86908ec7628e', WORKSPACE),
    'cf890d3d-6396-432c-93b0-a8bb59593830': ('vvvvvvv', True, 'approved', 'not_required', False,
                                             '0ab53a33-b9a3-407c-b977-45856a42fe96', '06c2ffaf-8db2-4413-95ef-5b6d7d93c8f5', '0ab53a33-b9a3-407c-b977-45856a42fe96',
                                             None, None, PERSONAL_WORKFLOW, 'e7216b79-af18-4aea-8dd0-ff9af01f7192', WORKSPACE),
}
EXPECTED_PLAN = [
    # (task_id, from_key, to_key, decision)
    # ttt: was 'todo' in the 2026-11-08 report; its assignee moved it through the app on 2026-11-09
    # (todo -> in_progress -> in_review -> changes_requested; approval not required).
    # APPROVED in review v5 (2026-11-09): changes_requested -> backlog. Its full state is pinned below.
    ('f4725489-31c7-4c03-8698-984e4435ebcc', 'changes_requested', 'backlog', 'move'),
    ('30445be8-9067-44fb-818d-9380d7a46575', 'approved', 'done', 'move'),
    ('47d8d5a3-6354-4c97-8ccd-7f56ef8923e4', 'backlog', None, 'excluded'),
    ('cf890d3d-6396-432c-93b0-a8bb59593830', 'approved', None, 'excluded'),
]

# Tasks the migration moves: their full state is pinned too, so any later
# change (status, approval, people, archive) stops the migration.
MOVED_TASKS = {
    # id: (title, project is null, status key, approval_state, approval_required, assignee, created_by, reviewer)
    'f4725489-31c7-4c03-8698-984e4435ebcc': ('ttt', True, 'changes_requested', 'not_required', False,
                                             '8d2697db-f8b7-4ee7-b714-f58511e3c173', '8d2697db-f8b7-4ee7-b714-f58511e3c173', None,
                                             None, None, PERSONAL_WORKFLOW, 'e0655322-8cb1-487f-8cb2-3985494f169a', WORKSPACE),
    '30445be8-9067-44fb-818d-9380d7a46575': ('لندینگ باگ بانتی', True, 'approved', 'approved', True,
                                             '06c2ffaf-8db2-4413-95ef-5b6d7d93c8f5', '06c2ffaf-8db2-4413-95ef-5b6d7d93c8f5', None,
                                             None, None, PERSONAL_WORKFLOW, 'e7216b79-af18-4aea-8dd0-ff9af01f7192', WORKSPACE),
}
PINNED_TASKS = {**EXCLUDED_TASKS, **MOVED_TASKS}

RETIRED = ('todo', 'in_progress', 'blocked', 'changes_requested', 'approved')
DEFAULT_STATUSES = [
    # key, name, category, position, requires_authority, is_active
    ('backlog', 'بک‌لاگ', 'backlog', 1, False, True),
    ('todo', 'انجام‌نشده', 'todo', 2, False, True),
    ('in_progress', 'در حال انجام', 'in_progress', 3, False, True),
    ('in_review', 'در حال بررسی', 'in_review', 4, False, True),
    ('approved', 'تأییدشده', 'approved', 5, True, True),
    ('done', 'انجام‌شده', 'done', 6, True, True),
    ('blocked', 'مسدود', 'blocked', 7, False, True),
    ('changes_requested', 'نیاز به اصلاح', 'changes_requested', 8, True, True),
    ('rejected', 'ردشده', 'rejected', 9, True, True),
]
DEFAULT_TRANSITIONS = [
    ('backlog', 'todo'), ('todo', 'in_progress'), ('in_progress', 'in_review'), ('in_progress', 'blocked'),
    ('blocked', 'in_progress'), ('in_review', 'approved'), ('approved', 'done'), ('in_review', 'changes_requested'),
    ('changes_requested', 'in_progress'), ('in_review', 'rejected'),
]
NEW_TRANSITIONS = [
    ('backlog', 'in_review'),   # submit_task_for_review only
    ('in_review', 'done'),      # decide approved only
    ('in_review', 'backlog'),   # decide revision_requested only
    ('in_review', 'rejected'),  # decide rejected only (already present)
    ('backlog', 'done'),        # complete; refused when approval is required
    ('rejected', 'backlog'),    # reopen; managers only (rejected_closed)
]


def q(value):
    if value is None:
        return 'null'
    if isinstance(value, bool):
        return 'true' if value else 'false'
    if isinstance(value, int):
        return str(value)
    return "'" + str(value).replace("'", "''") + "'"


def values(rows):
    return ',\n    '.join('(' + ', '.join(q(v) for v in row) + ')' for row in rows)


# ----------------------------------------------------------------------------- the one plan
# Used verbatim by the pre-migration report (inside WITH) and by the migration
# (CREATE TEMP TABLE ... AS). Same text, same result.
WF_WITH = f"""expected_status (key, name, category, position, requires_authority, is_active) as (values
    {values(DEFAULT_STATUSES)}
),
expected_transition (from_key, to_key) as (values
    {values(DEFAULT_TRANSITIONS)}
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
)"""

WF_SELECT = "with " + WF_WITH + "\nselect workflow_id, is_default from wf"

PLAN_SELECT = "with " + WF_WITH + f""",
excluded (task_id) as (
  select v::uuid from (values
    {values([(k,) for k in EXCLUDED_TASKS])}
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
    when not ts.is_default and ts.key in {RETIRED!r} then 'custom_workflow'
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
where ts.key in {RETIRED!r} or ts.key = 'in_review' or ts.task_id in (select task_id from excluded)
"""

# Exact state of every pinned task (excluded + moved): the columns guard (c) and report R5/R7 compare.
PINNED_STATE_SELECT = """
select t.id::text as task_id, t.title, t.project_id is null as personal, s.key as status_key, t.approval_state,
       t.approval_required, t.primary_assignee_id::text as assignee, t.created_by::text as created_by,
       t.reviewer_id::text as reviewer, t.project_id::text as project_id, pr.name as project_name,
       s.workflow_id::text as workflow_id, t.status_id::text as status_id, t.workspace_id::text as workspace_id,
       t.archived_at is null as not_archived
from public.tasks t join public.workflow_statuses s on s.id = t.status_id
left join public.projects pr on pr.id = t.project_id
where t.id in (""" + ', '.join("'" + k + "'::uuid" for k in PINNED_TASKS) + """)
"""
EXPECTED_PINNED_STATE = [(k, *v, True) for k, v in PINNED_TASKS.items()]

# Integrity checks shared by the report and the guard.
INTEGRITY_SELECT = """
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
"""
EXPECTED_INTEGRITY = [
    ('assignee_not_member', '47d8d5a3-6354-4c97-8ccd-7f56ef8923e4'),
    ('personal_created_for_other', 'cf890d3d-6396-432c-93b0-a8bb59593830'),
]
