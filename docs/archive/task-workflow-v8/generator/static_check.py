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
    if f"'{key}'" not in mig[mig.index('-- D7: retired categories'):][:400]:
        problems.append(f'migration: save_workflow_status does not refuse retired category {key}')
# new code never treats a retired category as a live column / inbox: outside the
# plan, the status retirement and the D7 refusal, no comparison with them remains
from common import PLAN_SELECT, WF_SELECT  # noqa: E402
scan = mig
for shared in (PLAN_SELECT.strip(), WF_SELECT.strip()):   # classification of the OLD defaults + the plan
    scan = scan.replace(shared, '')
allowed = (
    "'is_active', s.key not in",                        # §6: the retirement itself
    "if p_category in ('todo', 'in_progress', 'blocked', 'changes_requested', 'approved')",   # D7 refusal
    "'backlog', 'todo', 'in_progress', 'in_review', 'approved', 'done',",                     # save_workflow_status: existing category list (rows stay valid)
    "('upcoming', 'in_progress'",                       # milestone status, not a task category
)
for no, line in enumerate(scan.splitlines(), 1):
    if re.search(r"'(todo|in_progress)'", line) and not any(a in line for a in allowed):
        problems.append(f'migration: retired category outside the allowed places: {line.strip()[:120]}')

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
