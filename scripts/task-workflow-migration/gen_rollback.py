"""Generates docs/task-workflow-rollback-draft.sql: original bodies verbatim."""
import hashlib

from common import DOCS, dump

RESTORE = [
    # (dump name, signature for grants, original ACL roles besides postgres)
    ('public.create_task', 'public.create_task(text, text, uuid, uuid, text, timestamptz, boolean, uuid, uuid, boolean)', 'authenticated, service_role'),
    ('public.update_task', 'public.update_task(uuid, text, text, uuid, uuid, text, timestamptz, boolean)', 'authenticated, service_role'),
    ('public.transition_task', 'public.transition_task(uuid, uuid, text)', 'authenticated, service_role'),
    ('public.decide_task', 'public.decide_task(uuid, text, text)', 'authenticated, service_role'),
    ('public.add_task_collaborator', 'public.add_task_collaborator(uuid, uuid)', 'authenticated, service_role'),
    ('public.remove_project_member', 'public.remove_project_member(uuid, uuid)', 'authenticated, service_role'),
    ('public.save_workflow_status', 'public.save_workflow_status(uuid, uuid, text, text, integer, boolean, boolean)', 'authenticated, service_role'),
    ('public.project_sprint_counts', 'public.project_sprint_counts(uuid)', 'authenticated, service_role'),
    ('public.project_milestone_counts', 'public.project_milestone_counts(uuid)', 'authenticated, service_role'),
    ('public.set_sprint_status', 'public.set_sprint_status(uuid, text)', 'authenticated, service_role'),
    ('public.work_analytics', 'public.work_analytics(uuid)', 'authenticated, service_role'),
    ('app.seed_workflow', 'app.seed_workflow(uuid, uuid)', 'service_role'),
    ('public.remove_task_collaborator', 'public.remove_task_collaborator(uuid, uuid)', 'authenticated, service_role'),
    ('app.task_visible_directly', 'app.task_visible_directly(uuid, uuid, uuid)', 'service_role'),
    ('public.set_task_labels', 'public.set_task_labels(uuid, uuid[])', 'authenticated, service_role'),
    ('public.add_checklist_item', 'public.add_checklist_item(uuid, text)', 'authenticated, service_role'),
    ('public.toggle_checklist_item', 'public.toggle_checklist_item(uuid, boolean)', 'authenticated, service_role'),
    ('public.rename_checklist_item', 'public.rename_checklist_item(uuid, text)', 'authenticated, service_role'),
    ('public.delete_checklist_item', 'public.delete_checklist_item(uuid)', 'authenticated, service_role'),
    ('public.move_checklist_item', 'public.move_checklist_item(uuid, integer)', 'authenticated, service_role'),
    ('public.transfer_sprint_remainder', 'public.transfer_sprint_remainder(uuid, uuid)', 'authenticated, service_role'),
    ('public.set_milestone_status', 'public.set_milestone_status(uuid, text, text)', 'authenticated, service_role'),
    ('app.dashboard_summary_v1', 'app.dashboard_summary_v1()', ''),
    ('public.dashboard_projects', 'public.dashboard_projects()', 'authenticated, service_role'),
    ('public.dashboard_team', 'public.dashboard_team()', 'authenticated, service_role'),
    ('public.dashboard_people', 'public.dashboard_people(text, uuid, text, boolean, integer, integer)', 'authenticated, service_role'),
    ('public.dashboard_personal', 'public.dashboard_personal()', 'authenticated, service_role'),
]
# Their return type changed in the migration: drop the new one before restoring.
DROP_FIRST = {'public.project_sprint_counts': 'public.project_sprint_counts(uuid)',
              'public.project_milestone_counts': 'public.project_milestone_counts(uuid)'}


def q(v):
    return "'" + v.replace("'", "''") + "'"


def prosrc(definition: str) -> str:
    start = definition.index('$function$') + len('$function$')
    end = definition.rindex('$function$')
    return definition[start:end]


bodies = []
checks = []
grants = []
for name, sig, roles in RESTORE:
    text = dump(name, raw=True)
    drop = f'drop function {DROP_FIRST[name]};\n' if name in DROP_FIRST else ''
    bodies.append(f'\n-- {name}: original definition (pg_get_functiondef before the migration)\n{drop}{text}')
    if roles:
        grants.append(f"revoke all on function {sig} from public, anon{', authenticated' if 'authenticated' not in roles else ''};")
        grants.append(f"grant execute on function {sig} to {roles};")
    else:  # owner only (e.g. app.dashboard_summary_v1)
        grants.append(f"revoke all on function {sig} from public, anon, authenticated, service_role;")


checks = []
for name, sig, roles in RESTORE:
    schema, fn = name.split('.')
    checks.append(f"    ({q(schema)}, {q(fn)}, {q(hashlib.md5(prosrc(dump(name, raw=True)).encode('utf-8')).hexdigest())})")

sql = f"""-- =============================================================================
-- DRAFT v9 — DO NOT APPLY. Generated; do not edit by hand (proposal §13).
-- Rollback of docs/task-workflow-migration-draft.sql (five statuses). Local Supabase only.
-- Policy (proposal §9):
--   * restores, only where nothing changed them after the migration:
--     task statuses, status name / position / is_active, added transitions;
--   * restores the exact pre-migration bodies of every changed function
--     (verbatim below, verified by md5 at the end) and their grants;
--   * NEVER deletes history or data written after the migration: rounds,
--     snapshots, historical names, decisions, revision requests, block events,
--     logs — and keeps their immutability triggers;
--   * reports what it kept or could not restore and records the run.
-- After a rollback the Flutter client of the migration release must keep
-- working: it falls back to the pre-migration transition path when the new
-- RPCs are missing (proposal §10). Columns and history tables stay, so the
-- blocked flag set after the migration is still readable by that client.
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
       jsonb_build_object('from', r.to_status_id, 'to', r.from_status_id, 'reason', 'rollback_workflow_v9_five_status')
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
drop function public.complete_task(uuid, text);
drop function public.set_task_blocked(uuid, text);
drop function public.clear_task_blocked(uuid, text);

-- -----------------------------------------------------------------------------
-- 6. Original function bodies, verbatim
-- -----------------------------------------------------------------------------
{''.join(bodies)}

{chr(10).join(grants)}

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
{(','+chr(10)).join(checks)}
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
\\echo '== Restored =='
select 'task' as object, task_id::text as id, from_status_id::text as detail from rollback_tasks where restorable
union all select 'status', status_id::text, before::text from rollback_statuses where restorable
union all select 'transition_removed', transition_id::text, null from rollback_transitions where restorable
order by 1, 2;

\\echo '== Kept (changed after the migration; left as people set it) =='
select 'task' as object, task_id::text as id, kept_reason as reason from rollback_tasks where not restorable
union all select 'status', status_id::text, 'changed_after_migration' from rollback_statuses where not restorable
union all select 'transition', transition_id::text, kept_reason from rollback_transitions where not restorable
union all select 'blocked_flag', id::text, 'set by a person' from public.tasks where blocked_at is not null
order by 1, 2;

\\echo '== Kept by policy (history) =='
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
"""
(DOCS / 'task-workflow-rollback-draft.sql').write_text(sql, encoding='utf-8', newline='')
print('rollback ok:', len(RESTORE), 'bodies')
