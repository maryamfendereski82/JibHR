"""Static checks of the drafts. Never executes them. Catalog lookups are read-only SELECTs."""
import hashlib
import re
import subprocess
import sys

from pglast import parser
from pglast.ast import CreateFunctionStmt, DefElem

from common import DOCS

FILES = ['task-workflow-migration-draft.sql', 'task-workflow-rollback-draft.sql', 'task-workflow-premigration-report.sql']
problems: list[str] = []
notes: list[str] = []


def psql(sql: str) -> list[str]:
    out = subprocess.run(['docker', 'exec', '-i', 'supabase_db_jibhr', 'psql', '-U', 'postgres', '-d', 'postgres', '-At', '-v', 'ON_ERROR_STOP=1'],
                         input=f'begin transaction read only;\n{sql}\nrollback;\n', capture_output=True, text=True, encoding='utf-8')
    if out.returncode != 0:
        raise SystemExit(out.stderr)
    return [l for l in out.stdout.splitlines() if l and l not in ('BEGIN', 'ROLLBACK')]


def opt(stmt: CreateFunctionStmt, name: str):
    for o in stmt.options or ():
        if isinstance(o, DefElem) and o.defname == name:
            return o.arg
    return None


created: dict[str, list[str]] = {}
for file in FILES:
    text = (DOCS / file).read_bytes().decode('utf-8')
    sql = '\n'.join('' if l.startswith('\\') else l for l in text.splitlines())   # psql meta-commands
    try:
        stmts = parser.parse_sql(sql)
    except parser.ParseError as e:
        problems.append(f'{file}: parse error {e}')
        continue
    raw = parser.split(sql)
    notes.append(f'{file}: {len(stmts)} statements parsed')
    plpgsql = 0
    names = []
    for stmt, source in zip(stmts, raw):
        node = stmt.stmt
        if isinstance(node, CreateFunctionStmt):
            fname = '.'.join(n.sval for n in node.funcname)
            names.append(fname)
            lang = opt(node, 'language')
            lang = lang.sval if lang is not None else ''
            if lang == 'plpgsql':
                try:
                    parser.parse_plpgsql_json(source)
                    plpgsql += 1
                except Exception as e:  # noqa: BLE001
                    problems.append(f'{file}: plpgsql body of {fname}: {e}')
            secdef = opt(node, 'security')
            definer = secdef is not None and bool(getattr(secdef, 'boolval', secdef))
            setopt = [o for o in (node.options or ()) if isinstance(o, DefElem) and o.defname == 'set']
            if not setopt or "search_path" not in source.lower().split('as $')[0].replace('"', ''):
                problems.append(f'{file}: {fname} has no SET search_path')
            if definer and not re.search(r"set search_path (to|=) ''", source, re.I):
                problems.append(f'{file}: SECURITY DEFINER {fname} without empty search_path')
        if 'DO' == type(node).__name__ or type(node).__name__ == 'DoStmt':
            for arg in node.args:
                if arg.defname == 'as':
                    try:
                        parser.parse_plpgsql_json(f'create function _do() returns void language plpgsql as $$ {arg.arg.sval} $$;')
                        plpgsql += 1
                    except Exception as e:  # noqa: BLE001
                        problems.append(f'{file}: DO block: {e}')
    created[file] = names
    notes.append(f'{file}: {plpgsql} PL/pgSQL bodies (functions + DO blocks) parsed')

    # no placeholder comments left where SQL is required
    for marker in ('verbatim at implementation', 'unchanged part', '-- create_task:', '-- update_task (', 'goes here'):
        if marker in text:
            problems.append(f'{file}: placeholder text "{marker}"')

# --------------------------------------------------------------------------- privileges in the migration
mig = (DOCS / 'task-workflow-migration-draft.sql').read_text(encoding='utf-8')
for fname in created['task-workflow-migration-draft.sql']:
    if not re.search(r'revoke all on function ' + re.escape(fname) + r'\(', mig):
        problems.append(f'migration: no revoke for {fname}')
for m in re.finditer(r'grant execute on function (app\.[a-z_]+)\(', mig):
    problems.append(f'migration: internal {m.group(1)} granted')
if 'grant' in mig.lower() and re.search(r'grant [a-z ,]+ to (public|anon)\b', mig, re.I):
    problems.append('migration: grant to public/anon')
if re.search(r'on public\.profiles', mig, re.I):
    problems.append('migration: touches profiles grants/policies')

# --------------------------------------------------------------------------- catalog references
refs = set(re.findall(r'\b(public|app)\.([a-z_][a-z0-9_]*)\b', mig))
existing = set(tuple(l.split('|')) for l in psql("""
select n.nspname || '|' || c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname in ('public', 'app')
union select n.nspname || '|' || p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname in ('public', 'app');"""))
made = set(tuple(x.split('.')) for x in created['task-workflow-migration-draft.sql'])
made |= set(re.findall(r'create (?:temporary )?table (?:(public)\.)?([a-z_]+)', mig))
made |= {('public', s) for s in ('workflow_status_migration_log_id_seq', 'workflow_status_migration_report_id_seq', 'workflow_rollback_runs_id_seq')}
made = {(a or 'public', b) for a, b in made}
missing = sorted(f'{a}.{b}' for a, b in refs if (a, b) not in existing and (a, b) not in made)
if missing:
    problems.append('migration: unknown objects ' + ', '.join(missing))
notes.append(f'migration: {len(refs)} distinct public/app references resolved against the live catalog')

# columns used on existing tables must exist or be added
cols = set(l.split('|')[0] + '.' + l.split('|')[1] for l in psql(
    "select table_name || '|' || column_name from information_schema.columns where table_schema = 'public';"))
added = set()
for table, block in re.findall(r'alter table public\.([a-z_]+)(.*?);', mig, re.S):
    for col in re.findall(r'add column ([a-z_]+)', block):
        added.add(f'{table}.{col}')
for col in ['tasks.blocked_at', 'tasks.blocked_by', 'task_review_rounds.snapshot_status', 'task_review_rounds.submitted_by_source',
            'task_reviews.reviewer_name_source', 'workflow_statuses.is_active', 'tasks.priority_rank', 'project_members.removed_at',
            'profiles.status', 'task_activity_events.metadata']:
    if col not in cols and col not in added:
        problems.append(f'migration: column {col} neither exists nor is added')

# --------------------------------------------------------------------------- rollback proof vs live database
rb = (DOCS / 'task-workflow-rollback-draft.sql').read_bytes().decode('utf-8')
expected = re.findall(r"\('(public|app)', '([a-z0-9_]+)', '([0-9a-f]{32})'\)", rb)
live = dict((l.split('|')[0], l.split('|')[1]) for l in psql(
    "select n.nspname || '.' || p.proname || '|' || md5(p.prosrc) from pg_proc p join pg_namespace n on n.oid = p.pronamespace "
    "where n.nspname in ('public', 'app');"))
for schema, fn, md5 in expected:
    if live.get(f'{schema}.{fn}') != md5:
        problems.append(f'rollback: md5 of {schema}.{fn} differs from the live pre-migration body')
notes.append(f'rollback: {len(expected)} original bodies match the live database byte for byte (md5 of prosrc)')
restored = len(re.findall(r'^-- (?:public|app)\.[a-z0-9_]+: original definition', rb, re.M))
if restored != len(expected):
    problems.append(f'rollback: {restored} restored bodies but {len(expected)} md5 entries checked')
# rollback drops exactly what the migration created (minus kept trigger functions)
dropped = set(re.findall(r'drop function ((?:public|app)\.[a-z0-9_]+)\(', rb))
kept = {'app.protect_review_round', 'app.reject_change', 'app.check_revision_request'}
new_names = {n for n in created['task-workflow-migration-draft.sql']} - {
    'public.create_task', 'public.update_task', 'public.transition_task', 'public.add_task_collaborator', 'public.remove_project_member',
    'public.save_workflow_status', 'app.seed_workflow', 'public.project_sprint_counts', 'public.project_milestone_counts',
    'public.set_sprint_status', 'public.work_analytics', 'public.remove_task_collaborator', 'app.task_visible_directly',
    'public.set_task_labels', 'public.add_checklist_item', 'public.toggle_checklist_item', 'public.rename_checklist_item',
    'public.delete_checklist_item', 'public.move_checklist_item', 'public.transfer_sprint_remainder', 'public.set_milestone_status',
    'app.dashboard_summary_v1', 'public.dashboard_projects', 'public.dashboard_team', 'public.dashboard_people', 'public.dashboard_personal'}
left = sorted(new_names - dropped - kept - {'public.decide_task'})
if left:
    problems.append('rollback: new functions not dropped: ' + ', '.join(left))
if 'drop function public.decide_task(uuid, text, uuid, text, text, jsonb, text)' not in rb:
    problems.append('rollback: new decide_task not dropped')

# --------------------------------------------------------------------------- creation order (v8)
# A LANGUAGE sql body is validated at CREATE time: every function it calls must
# already exist (live) or be created earlier in the migration.
live_fns = set(l for l in psql(
    "select n.nspname || '.' || p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname in ('public', 'app');"))
mig_sql = '\n'.join('' if l.startswith('\\') else l for l in mig.splitlines())
mig_fns = set(created['task-workflow-migration-draft.sql'])
seen: set[str] = set()
sql_bodies = 0
for stmt, source in zip(parser.parse_sql(mig_sql), parser.split(mig_sql)):
    node = stmt.stmt
    if not isinstance(node, CreateFunctionStmt):
        continue
    fname = '.'.join(n.sval for n in node.funcname)
    lang = opt(node, 'language')
    if lang is not None and lang.sval == 'sql':
        sql_bodies += 1
        body = source.split('$$', 1)[1] if '$$' in source else source
        for schema, fn in set(re.findall(r'\b(app|public)\.([a-z0-9_]+)\s*\(', body)):
            ref = f'{schema}.{fn}'
            if ref != fname and ref in mig_fns and ref not in live_fns and ref not in seen:
                problems.append(f'migration: sql function {fname} calls {ref} before it is created')
    seen.add(fname)
notes.append(f'migration: creation order checked for {sql_bodies} LANGUAGE sql bodies')

# --------------------------------------------------------------------------- retired statuses (v8)
from common import RETIRED  # noqa: E402
seed = mig[mig.index('CREATE OR REPLACE FUNCTION app.seed_workflow'):]
seed = seed[:seed.index('$function$\n;')]
for key in RETIRED:
    if f"'{key}'" in seed:
        problems.append(f'migration: seed_workflow still creates retired status {key}')
    if f"'{key}'" not in mig[mig.index('-- D7 (v9): retired categories'):][:400]:
        problems.append(f'migration: save_workflow_status does not refuse retired category {key}')
# new code never treats a retired category as a live status: outside the plan,
# the status retirement, the D7 refusal and unchanged original lines, no
# comparison of a status / category with a retired key remains
from common import PLAN_SELECT, WF_SELECT, FINAL_STATUSES, FINAL_TRANSITIONS, DUMPS  # noqa: E402
original_lines = set()
for f in DUMPS.glob('*.sql'):
    original_lines |= {l.strip() for l in f.read_bytes().decode('utf-8').replace('\r\n', '\n').splitlines() if l.strip()}
scan = mig
for shared in (PLAN_SELECT.strip(), WF_SELECT.strip()):   # classification of the OLD defaults + the plan
    scan = scan.replace(shared, '')
retired_re = re.compile(r"'(" + '|'.join(RETIRED) + r")'")
status_ctx = re.compile(r"(category|\bkey\b|\.key|v_current|v_category|prev_key|from_key|to_key)")
allowed = (
    "'is_active', s.key not in",                        # §6: the retirement itself
    "where s.key in ('todo'",                          # §6: no task left in a retired status
    "if p_category in ('todo'",                        # D7 refusal
)
for line in scan.splitlines():
    if retired_re.search(line) and status_ctx.search(line) and line.strip() not in original_lines \
            and not any(a in line for a in allowed):
        problems.append(f'migration: retired category outside the allowed places: {line.strip()[:120]}')

# --------------------------------------------------------------------------- v9: five statuses, no four-status leftovers
final_keys = [s[0] for s in FINAL_STATUSES]
assert not set(final_keys) & set(RETIRED)
for key in final_keys:
    if f"(v_workflow, '{key}', " not in seed:
        problems.append(f'migration: seed_workflow does not create the final status {key}')
if seed.count('(v_workflow, (select id from public.workflow_statuses') != len(FINAL_TRANSITIONS):
    problems.append('migration: seed_workflow does not create exactly the final edges')


def body_of(name: str) -> str:
    """The function's SQL without -- comments (comments may name what is refused)."""
    for marker in (f'create function {name}(', f'CREATE OR REPLACE FUNCTION {name}('):
        if marker in mig:
            b = mig[mig.index(marker):]
            end = b.index('$function$\n;') if marker.startswith('CREATE') else b.index('$$;')
            return '\n'.join(l.split('--')[0] for l in b[:end].splitlines())
    problems.append(f'migration: {name} not found')
    return ''


if "when 'approved' then 'approved' when 'revision_requested' then 'backlog' else 'rejected'" not in body_of('public.decide_task'):
    problems.append('migration: decide_task does not finish an approved task in "approved"')
for fn in ('public.submit_task_for_review', 'public.complete_task'):
    b = body_of(fn)
    if "v_task.primary_assignee_id is distinct from auth.uid() then raise exception 'assignee_only'" not in b:
        problems.append(f'migration: {fn} is not limited to the primary assignee')
tt = body_of('public.transition_task')
if "v_category = 'in_progress' and v_task.primary_assignee_id is distinct from auth.uid()" not in tt:
    problems.append('migration: transition_task lets someone other than the assignee start work')
for code in ("raise exception 'use_submit'", "raise exception 'use_complete'", "raise exception 'use_decide'", "raise exception 'reopen_backlog_only'"):
    if code not in tt:
        problems.append(f'migration: transition_task misses {code}')
# tasks.view.all alone never changes a status or decides
for fn in ('public.transition_task', 'public.submit_task_for_review', 'public.decide_task', 'public.complete_task',
           'public.set_task_blocked', 'public.clear_task_blocked', 'app.can_decide_task', 'app.can_act_on_task'):
    if 'tasks.view.all' in body_of(fn):
        problems.append(f'migration: {fn} still accepts tasks.view.all')
if 'p_task.primary_assignee_id is distinct from auth.uid() and case' not in body_of('app.can_decide_task'):
    problems.append('migration: the assignee may decide on their own task')
cb = body_of('public.complete_task')
if 'task_review_rounds' in cb or 'task_reviews' in cb or "approval_state = 'approved'" in cb:
    problems.append('migration: complete_task creates a review round, a decision or an approval')
if "app.workflow_status(v_task.status_id, 'approved')" not in cb:
    problems.append('migration: complete_task does not finish in "approved"')
if "app.workflow_status(v_task.status_id, 'backlog')" not in body_of('public.clear_task_blocked'):
    problems.append('migration: clear_task_blocked does not return the task to the queue')
for fn in ('public.transfer_sprint_remainder', 'public.set_milestone_status'):
    if 'app.task_is_open(t.id)' not in body_of(fn):
        problems.append(f'migration: {fn} still carries blocked / final rejected work')
sw = mig[mig.index('-- the five categories the cycle needs (v9).'):][:600]
for cat in final_keys:
    if f"'{cat}'" not in sw:
        problems.append(f'migration: save_workflow_status does not keep an active {cat} status')
for phrase in ("'رد نهایی'", "then 'done'", "'done', 3", "key = 'done'", "category = 'done'", "category = 'blocked'"):
    if phrase in scan:   # the plan (shared with the report) maps the old keys and is excluded
        problems.append(f'migration: four-status leftover {phrase}')
notes.append(f'migration: five-status rules checked (seed {len(final_keys)} statuses / {len(FINAL_TRANSITIONS)} edges, assignee-only paths, no tasks.view.all, no fake review in complete_task)')

# --------------------------------------------------------------------------- member removal never uses task_is_open alone (v8)
for fn in ('app.open_tasks_of_member', 'public.project_member_open_tasks'):
    body = mig[mig.index(f'create function {fn}('):]
    body = body[:body.index('$$;')]
    if 'task_is_open' in body or 'task_is_unresolved' not in body:
        problems.append(f'migration: {fn} must use app.task_is_unresolved (blocked tasks still hold a member)')

print('\n'.join(notes))
print('PROBLEMS:' if problems else 'NO PROBLEMS')
print('\n'.join(problems))
sys.exit(1 if problems else 0)
