#!/usr/bin/env bash
# Refreshes fndefs/*.sql: the exact pg_get_functiondef of every function the
# drafts change or restore. READ ONLY (a read-only transaction, rolled back).
# Bodies keep their original bytes (they contain CRLF from the migration files).
# Local Supabase only: container supabase_db_jibhr.
set -euo pipefail
cd "$(dirname "$0")"
FUNCS="public.create_task public.update_task public.transition_task public.decide_task public.add_task_collaborator
public.remove_task_collaborator public.remove_project_member public.save_workflow_status public.project_sprint_counts
public.project_milestone_counts public.set_sprint_status public.work_analytics app.seed_workflow app.task_visible_directly
public.set_task_labels public.add_checklist_item public.toggle_checklist_item public.rename_checklist_item
public.delete_checklist_item public.move_checklist_item app.task_children_block_done app.task_counts_complete
app.dashboard_summary_v1 public.dashboard_projects public.dashboard_team public.dashboard_people public.dashboard_personal
public.report_export public.set_milestone_status public.transfer_sprint_remainder"
for f in $FUNCS; do
  docker exec -i supabase_db_jibhr psql -U postgres -d postgres -At -v ON_ERROR_STOP=1 >"fndefs/$f.sql" <<SQL
begin transaction read only;
select pg_get_functiondef(p.oid) || ';' from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname || '.' || p.proname = '$f';
rollback;
SQL
  # drop the BEGIN / ROLLBACK lines psql prints
  python -c "import sys,pathlib;p=pathlib.Path(sys.argv[1]);b=p.read_bytes().split(b'\n');p.write_bytes(b'\n'.join(l for l in b if l not in (b'BEGIN',b'ROLLBACK')))" "fndefs/$f.sql"
  echo "$f $(wc -c <"fndefs/$f.sql") bytes"
done
