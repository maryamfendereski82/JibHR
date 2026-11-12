# Task workflow migration generator

These scripts produce the three SQL drafts in `docs/`. The drafts are not migrations: they live in `docs/` so that no tool applies them. Running them needs separate approval (`docs/task-workflow-proposal.md`).

| File | Role |
|---|---|
| `dump_functions.sh` | Refreshes `fndefs/` with the exact `pg_get_functiondef` of every function the drafts change or restore. It runs in a read-only transaction against the local container `supabase_db_jibhr`. The bodies keep their original bytes, including the CRLF line endings from the migration files. |
| `common.py` | Holds the reviewed expectations (default workflows, excluded tasks, plan, integrity findings), the shared plan SQL, the workflow classification and integrity SQL, and the exact-patch helper. |
| `gen_migration.py` | Writes `docs/task-workflow-migration-draft.sql`. Each existing function is its dump plus patches that must each match exactly once, otherwise generation stops. It also writes `changed-functions.txt`. |
| `gen_report.py` | Writes `docs/task-workflow-premigration-report.sql`, a read-only report. Its plan, classification, excluded-task state and integrity checks are the same SQL text as the migration guard. |
| `gen_rollback.py` | Writes `docs/task-workflow-rollback-draft.sql` with the original function bodies verbatim and their md5. |
| `static_check.py` | Never executes the drafts. It runs these checks: <ul><li>parses every statement and every PL/pgSQL body with the PostgreSQL parser (`pglast`);</li><li>lints privileges and `search_path`;</li><li>resolves `public.*` and `app.*` references against the live catalog (read-only queries);</li><li>compares the rollback md5s with the live bodies;</li><li>checks creation order: every function a `LANGUAGE sql` body calls is live or created earlier (those bodies are validated at `CREATE`);</li><li>checks that retired categories (`todo`, `in_progress`, …) are neither seeded nor re-creatable, and appear in no new comparison outside the plan;</li><li>checks that member removal uses `app.task_is_unresolved`, never `app.task_is_open`.</li></ul> |

## Use

```bash
bash scripts/task-workflow-migration/dump_functions.sh   # optional: refresh the dumps (read only)
python -m venv /tmp/sqlcheck && /tmp/sqlcheck/bin/pip install pglast   # isolated; not a project dependency
cd scripts/task-workflow-migration
python gen_migration.py && python gen_report.py && python gen_rollback.py
/tmp/sqlcheck/bin/python static_check.py
docker exec -i supabase_db_jibhr psql -U postgres -d postgres -P pager=off -v ON_ERROR_STOP=1 \
  < ../../docs/task-workflow-premigration-report.sql      # read only; R7 must be empty
```

Feed the report with a byte-exact redirect (bash `<`). A PowerShell pipe re-encodes the Persian literals in the SQL, so every workflow comes out "custom" and R7 shows false differences.

Do not edit the generated SQL by hand. Change the generator and generate again.
