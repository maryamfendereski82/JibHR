# Task workflow migration generator (v9, five statuses)

These scripts produce the three SQL drafts in `docs/`. The drafts are not migrations: they live in `docs/` so that no tool applies them. Running them needs separate approval (`docs/task-workflow-proposal.md`).

v9 targets the five-status workflow: `backlog` «در صف انجام», `in_progress` «در حال انجام», `in_review` «در حال بررسی», `approved` «تأیید شده», `rejected` «رد شده». It retires `todo`, `changes_requested`, `blocked` and `done`, which are deactivated, never deleted. The v8 package (four statuses) is kept unchanged in `docs/archive/task-workflow-v8/`.

| File | Role |
|---|---|
| `dump_functions.sh` | Refreshes `fndefs/` with the exact `pg_get_functiondef` of every function the drafts change or restore. It runs in a read-only transaction against the local container `supabase_db_jibhr`. The bodies keep their original bytes, including the CRLF line endings from the migration files. |
| `common.py` | Holds the reviewed expectations and the shared SQL. <ul><li>Expectations: default workflows, the five final statuses and seven final edges, retired keys, the plan, integrity findings, and pinned tasks with their rounds and newest decision.</li><li>Shared SQL: the plan, the workflow classification and the integrity checks.</li><li>The exact-patch helper.</li></ul> |
| `gen_migration.py` | Writes `docs/task-workflow-migration-draft.sql`. Each existing function is its dump plus patches that must each match exactly once, otherwise generation stops. It also writes `changed-functions.txt`. |
| `gen_report.py` | Writes `docs/task-workflow-premigration-report.sql`, a read-only report. Its plan, classification, excluded-task state and integrity checks are the same SQL text as the migration guard. |
| `gen_rollback.py` | Writes `docs/task-workflow-rollback-draft.sql` with the original function bodies verbatim and their md5. |
| `static_check.py` | Never executes the drafts. It runs these checks: <ul><li>parses every statement and every PL/pgSQL body with the PostgreSQL parser (`pglast`);</li><li>lints privileges and `search_path`;</li><li>resolves `public.*` and `app.*` references against the live catalog (read-only queries);</li><li>compares the rollback md5s with the live bodies;</li><li>checks creation order: every function a `LANGUAGE sql` body calls is live or created earlier (those bodies are validated at `CREATE`);</li><li>checks that retired categories (`todo`, `changes_requested`, `blocked`, `done`) are neither seeded nor re-creatable, and appear in no new status comparison outside the plan (unchanged original lines are allowed);</li><li>checks that member removal uses `app.task_is_unresolved`, never `app.task_is_open`;</li><li>v9 checks:<ul><li>the seed creates exactly the five statuses and seven edges;</li><li>`decide_task` approves into `approved`;</li><li>start, submit and complete are limited to the primary assignee;</li><li>no status-changing function or decision accepts `tasks.view.all`;</li><li>the assignee never decides on their own task;</li><li>`complete_task` creates no round, decision or approval;</li><li>unblock returns to backlog;</li><li>a sprint carries over, and a milestone waits for, open work only;</li><li>no four-status leftovers remain.</li></ul></li></ul> |

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

On Windows, the pglast virtualenv used for v9 lives in the session scratchpad (`sqlcheck/Scripts/python.exe`). Any isolated virtualenv works, and it is not a project dependency. Set `PYTHONIOENCODING=utf-8` so the Persian text prints.

Feed the report with a byte-exact redirect (bash `<`). A PowerShell pipe re-encodes the Persian literals in the SQL, so every workflow comes out "custom" and R7 shows false differences.

Do not edit the generated SQL by hand. Change the generator and generate again.
