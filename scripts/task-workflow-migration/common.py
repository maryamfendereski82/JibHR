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


# ----------------------------------------------------------------------------- reviewed expectations (v9)
# Values of the pre-migration report of 2026-11-10 (read only). The guard
# compares the live data with these, row by row; any difference aborts the
# migration. Nothing here is a guess: every value was read from the database.
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

LOCAL_PRODUCT_PROJECT = '9ce11cff-e0ba-4122-b282-39f286aab335'  # «محصول محلی»
LOCAL_PRODUCT_WORKFLOW = 'cb3fe4b1-be2e-4f2f-a7e6-a0583140a11f'

# Pinned columns (after the id): title, project is null, status key, approval_state, approval_required,
# assignee, created_by, reviewer, project_id, project name, workflow_id, status_id, workspace_id,
# review rounds, open rounds, decision of the newest round.
EXCLUDED_TASKS = {
    # rgdfdgf: v8 pinned it in backlog. On 2026-11-09 17:24 UTC (after the v8 report) the super admin
    # moved it todo -> in_progress -> in_review; round 1 is open, no decision. Its assignee is not a
    # member of «باگ بانتی» (integrity). v9 keeps it exactly as it is now (excluded, no change) and
    # pins this state. NEEDS REVIEWER CONFIRMATION (proposal §3).
    '47d8d5a3-6354-4c97-8ccd-7f56ef8923e4': ('rgdfdgf', False, 'in_review', 'pending', True,
                                             '8d2697db-f8b7-4ee7-b714-f58511e3c173', '06c2ffaf-8db2-4413-95ef-5b6d7d93c8f5', None,
                                             BUG_BOUNTY_PROJECT, 'باگ بانتی', BUG_BOUNTY_WORKFLOW,
                                             'b097c632-b2bc-4717-9c65-73c99e439a1a', WORKSPACE, 1, 1, None),
    # vvvvvvv: approved, approval not required, no rounds; personal task created for someone else.
    # Stays in "approved" (an active status in v9): no change.
    'cf890d3d-6396-432c-93b0-a8bb59593830': ('vvvvvvv', True, 'approved', 'not_required', False,
                                             '0ab53a33-b9a3-407c-b977-45856a42fe96', '06c2ffaf-8db2-4413-95ef-5b6d7d93c8f5', '0ab53a33-b9a3-407c-b977-45856a42fe96',
                                             None, None, PERSONAL_WORKFLOW, 'e7216b79-af18-4aea-8dd0-ff9af01f7192', WORKSPACE, 0, 0, None),
}
# Tasks the migration moves: their full state is pinned too, so any later
# change (status, approval, rounds, people, archive) stops the migration.
MOVED_TASKS = {
    # ttt: APPROVED in review v5 (2026-11-09): changes_requested -> backlog (approval not required).
    'f4725489-31c7-4c03-8698-984e4435ebcc': ('ttt', True, 'changes_requested', 'not_required', False,
                                             '8d2697db-f8b7-4ee7-b714-f58511e3c173', '8d2697db-f8b7-4ee7-b714-f58511e3c173', None,
                                             None, None, PERSONAL_WORKFLOW, 'e0655322-8cb1-487f-8cb2-3985494f169a', WORKSPACE, 0, 0, None),
    # کار محلی: the only "done" task. Approval required and approved; one round, decided "approved";
    # path todo > in_progress > in_review > done (2026-11-05..07). done -> approved.
    '020b27db-e513-40a5-96e1-c8b124b1baa9': ('کار محلی', False, 'done', 'approved', True,
                                             '06c2ffaf-8db2-4413-95ef-5b6d7d93c8f5', '06c2ffaf-8db2-4413-95ef-5b6d7d93c8f5', None,
                                             LOCAL_PRODUCT_PROJECT, 'محصول محلی', LOCAL_PRODUCT_WORKFLOW,
                                             '85109c5d-21af-48b8-b858-e432fc5a69a3', WORKSPACE, 1, 0, 'approved'),
}
# Tasks the migration does NOT move but whose state is pinned (v9: «لندینگ باگ بانتی»
# stays in "approved", the status v9 keeps; v8 had moved it to "done").
KEPT_PINNED_TASKS = {
    '30445be8-9067-44fb-818d-9380d7a46575': ('لندینگ باگ بانتی', True, 'approved', 'approved', True,
                                             '06c2ffaf-8db2-4413-95ef-5b6d7d93c8f5', '06c2ffaf-8db2-4413-95ef-5b6d7d93c8f5', None,
                                             None, None, PERSONAL_WORKFLOW, 'e7216b79-af18-4aea-8dd0-ff9af01f7192', WORKSPACE, 1, 0, 'approved'),
}
PINNED_TASKS = {**EXCLUDED_TASKS, **MOVED_TASKS, **KEPT_PINNED_TASKS}
EXPECTED_PLAN = [
    # (task_id, from_key, to_key, decision); rows with decision 'keep' are not listed.
    ('f4725489-31c7-4c03-8698-984e4435ebcc', 'changes_requested', 'backlog', 'move'),
    ('020b27db-e513-40a5-96e1-c8b124b1baa9', 'done', 'approved', 'move'),
    ('47d8d5a3-6354-4c97-8ccd-7f56ef8923e4', 'in_review', None, 'excluded'),
    ('cf890d3d-6396-432c-93b0-a8bb59593830', 'approved', None, 'excluded'),
]

# v9: the five active statuses are backlog, in_progress, in_review, approved, rejected.
RETIRED = ('todo', 'changes_requested', 'blocked', 'done')
FINAL_STATUSES = [
    # key, name, category, position, requires_authority (seed_workflow and the renamed default workflows)
    ('backlog', 'در صف انجام', 'backlog', 1, False),
    ('in_progress', 'در حال انجام', 'in_progress', 2, False),
    ('in_review', 'در حال بررسی', 'in_review', 3, False),
    ('approved', 'تأیید شده', 'approved', 4, True),
    ('rejected', 'رد شده', 'rejected', 5, True),
]
FINAL_CATEGORIES = tuple(s[2] for s in FINAL_STATUSES)
FINAL_TRANSITIONS = [
    # (from, to, the only server path that may use it)
    ('backlog', 'in_progress', 'transition_task: start, primary assignee only'),
    ('in_progress', 'in_review', 'submit_task_for_review: primary assignee only, approval required'),
    ('in_review', 'approved', 'decide_task approved: eligible reviewer, never the assignee'),
    ('in_review', 'backlog', 'decide_task revision_requested: eligible reviewer, what + why'),
    ('in_review', 'rejected', 'decide_task rejected: eligible reviewer, reason'),
    ('in_progress', 'approved', 'complete_task: primary assignee only, approval not required'),
    ('rejected', 'backlog', 'transition_task: reopen, tasks.manage.project or super admin'),
]
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
# Added to the migrated default workflows: the final edges they do not have yet.
# Edges into or out of retired statuses stay (no row is deleted); their retired
# endpoint is inactive, so transition_task refuses them (status_inactive).
NEW_TRANSITIONS = [(f, t) for f, t, _ in FINAL_TRANSITIONS if (f, t) not in DEFAULT_TRANSITIONS]
assert NEW_TRANSITIONS == [('backlog', 'in_progress'), ('in_review', 'backlog'), ('in_progress', 'approved'), ('rejected', 'backlog')], NEW_TRANSITIONS


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
    when not ts.is_default and ts.key in {RETIRED!r} then 'custom_workflow'
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
where ts.key in {RETIRED!r} or ts.key in ('in_review', 'approved') or ts.task_id in (select task_id from excluded)
"""

# Exact state of every pinned task (excluded + moved): the columns guard (c) and report R5/R7 compare.
PINNED_STATE_SELECT = """
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
PINNED_COLUMNS = ('task_id, title, personal, status_key, approval_state, approval_required, assignee, created_by, reviewer, '
                  'project_id, project_name, workflow_id, status_id, workspace_id, rounds, open_rounds, last_decision, not_archived')
EXPECTED_INTEGRITY = [
    ('assignee_not_member', '47d8d5a3-6354-4c97-8ccd-7f56ef8923e4'),
    ('personal_created_for_other', 'cf890d3d-6396-432c-93b0-a8bb59593830'),
    # v9: rgdfdgf has been in review since 2026-11-09 with round 1 undecided (see EXCLUDED_TASKS).
    ('open_round', '47d8d5a3-6354-4c97-8ccd-7f56ef8923e4'),
]
