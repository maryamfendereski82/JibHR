// Live check of WorkRepository.assignedOpen against the local Supabase.
//
// Opt-in: JIBHR_LIVE_DB=1 flutter test test/work/open_tasks_live_test.dart
// Needs the local stack (container supabase_db_jibhr), env.json and
// .local/qa-accounts.json. Seeds tasks titled "QA-OPEN …" for qa.employee and
// deletes them afterwards, also when a test fails.
@Tags(['live'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jibhr/features/work/work_repository.dart';
import 'package:jibhr/features/work/work_rules.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _marker = 'QA-OPEN';
final _live = Platform.environment['JIBHR_LIVE_DB'] == '1';

Future<String> _psql(String sql) async {
  final result = await Process.run('docker', ['exec', '-i', 'supabase_db_jibhr', 'psql', '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-At', '-c', sql]);
  if (result.exitCode != 0) throw StateError('psql: ${result.stderr}');
  return (result.stdout as String).trim();
}

const _cleanup = "delete from public.tasks where title like '$_marker%';";

// Statuses are looked up by category in each task's own workflow, never by id.
const _seed =
    '''
with me as (
  select p.id, p.workspace_id from public.profiles p join auth.users u on u.id = p.id where u.email = 'qa.employee@jibhr.local'
),
personal as (select w.id from public.workflows w where w.project_id is null),
project as (select p.id as project_id, w.id from public.projects p join public.workflows w on w.project_id = p.id where p.name = 'QA پروژه'),
st as (
  select 'personal' as flow, s.category, s.id from public.workflow_statuses s where s.workflow_id = (select id from personal)
  union all
  select 'project', s.category, s.id from public.workflow_statuses s where s.workflow_id = (select id from project)
),
rows (title, flow, category, due, approval_required, approval_state, archived) as (values
  -- 12 personal tasks done, oldest deadlines
  ('$_marker done 01', 'personal', 'done', timestamptz '2026-01-01 08:00Z', false, 'not_required', false),
  ('$_marker done 02', 'personal', 'done', timestamptz '2026-01-02 08:00Z', false, 'not_required', false),
  ('$_marker done 03', 'personal', 'done', timestamptz '2026-01-03 08:00Z', false, 'not_required', false),
  ('$_marker done 04', 'personal', 'done', timestamptz '2026-01-04 08:00Z', false, 'not_required', false),
  ('$_marker done 05', 'personal', 'done', timestamptz '2026-01-05 08:00Z', false, 'not_required', false),
  ('$_marker done 06', 'personal', 'done', timestamptz '2026-01-06 08:00Z', false, 'not_required', false),
  ('$_marker done 07', 'personal', 'done', timestamptz '2026-01-07 08:00Z', false, 'not_required', false),
  ('$_marker done 08', 'personal', 'done', timestamptz '2026-01-08 08:00Z', false, 'not_required', false),
  ('$_marker done 09', 'personal', 'done', timestamptz '2026-01-09 08:00Z', false, 'not_required', false),
  ('$_marker done 10', 'personal', 'done', timestamptz '2026-01-10 08:00Z', false, 'not_required', false),
  ('$_marker done 11', 'personal', 'done', timestamptz '2026-01-11 08:00Z', false, 'not_required', false),
  ('$_marker done 12', 'personal', 'done', timestamptz '2026-01-12 08:00Z', false, 'not_required', false),
  -- 4 project tasks in the project's own "approved" category, no approval needed
  ('$_marker done 13', 'project', 'approved', timestamptz '2026-01-13 08:00Z', false, 'not_required', false),
  ('$_marker done 14', 'project', 'approved', timestamptz '2026-01-14 08:00Z', false, 'not_required', false),
  ('$_marker done 15', 'project', 'approved', timestamptz '2026-01-15 08:00Z', false, 'not_required', false),
  ('$_marker done 16', 'project', 'approved', timestamptz '2026-01-16 08:00Z', false, 'not_required', false),
  -- done and approval granted: complete
  ('$_marker done 17', 'project', 'done', timestamptz '2026-01-17 08:00Z', true, 'approved', false),
  -- open but archived: excluded
  ('$_marker archived', 'personal', 'todo', timestamptz '2026-01-20 08:00Z', false, 'not_required', true),
  -- done but waiting for approval: open by the rule
  ('$_marker A awaiting approval', 'personal', 'done', timestamptz '2026-02-01 08:00Z', true, 'pending', false),
  ('$_marker B changes requested', 'personal', 'changes_requested', now() + interval '1 day', false, 'not_required', false),
  ('$_marker C in progress', 'project', 'in_progress', now() + interval '2 days', false, 'not_required', false),
  ('$_marker D todo soon', 'personal', 'todo', now() + interval '5 days', false, 'not_required', false),
  ('$_marker E todo later', 'personal', 'todo', now() + interval '9 days', false, 'not_required', false),
  ('$_marker F blocked undated', 'personal', 'blocked', null, false, 'not_required', false)
)
insert into public.tasks (workspace_id, project_id, title, primary_assignee_id, status_id, due_at, approval_required, approval_state, created_by, archived_at)
select me.workspace_id,
       case when r.flow = 'project' then (select project_id from project) end,
       r.title, me.id,
       (select st.id from st where st.flow = r.flow and st.category = r.category limit 1),
       r.due, r.approval_required, r.approval_state, me.id,
       case when r.archived then now() end
from rows r cross join me
returning id;
''';

void main() {
  SupabaseClient? signedIn;
  SupabaseClient client() => signedIn!;
  late String profileId;

  setUpAll(() async {
    if (!_live) return;
    final env = jsonDecode(File('env.json').readAsStringSync()) as Map<String, dynamic>;
    final accounts = (jsonDecode(File('.local/qa-accounts.json').readAsStringSync()) as Map<String, dynamic>)['accounts'] as Map<String, dynamic>;
    final employee = accounts['qa.employee'] as Map<String, dynamic>;
    await _psql(_cleanup);
    final uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-');
    final inserted = (await _psql(_seed)).split('\n').where((line) => uuid.hasMatch(line.trim())).length;
    expect(inserted, 24, reason: 'seed rows');
    final created = SupabaseClient(env['SUPABASE_URL'] as String, env['SUPABASE_PUBLISHABLE_KEY'] as String, authOptions: const AuthClientOptions(autoRefreshToken: false));
    final auth = await created.auth.signInWithPassword(email: 'qa.employee@jibhr.local', password: employee['password'] as String);
    signedIn = created;
    profileId = auth.user!.id;
  });

  // Cleanup first, so seeded rows go even when setup failed half-way.
  tearDownAll(() async {
    if (!_live) return;
    await _psql(_cleanup);
    await signedIn?.auth.signOut();
  });

  test('17 old completed tasks do not crowd out the open ones', () async {
    final open = await WorkRepository(client()).assignedOpen(profileId, limit: 6);
    final titles = open.map((t) => t.title).toList();
    expect(titles, ['$_marker A awaiting approval', '$_marker B changes requested', '$_marker C in progress', '$_marker D todo soon', '$_marker E todo later', '$_marker F blocked undated']);
    for (final task in open) {
      expect(
        taskCountsComplete(category: task.statusCategory, approvalRequired: task.approvalRequired, approvalState: task.approvalState),
        isFalse,
        reason: task.title,
      );
    }
  }, skip: _live ? false : 'set JIBHR_LIVE_DB=1');

  test('a smaller limit keeps the nearest deadlines', () async {
    final open = await WorkRepository(client()).assignedOpen(profileId, limit: 3);
    expect(open.map((t) => t.title), ['$_marker A awaiting approval', '$_marker B changes requested', '$_marker C in progress']);
  }, skip: _live ? false : 'set JIBHR_LIVE_DB=1');

  test('the previous approach (read 20, filter on the client) really lost tasks', () async {
    // The query Home used before: no server filter, limit 20.
    final rows = await client()
        .from('tasks')
        .select('id, title, due_at, approval_required, approval_state, workflow_statuses(category)')
        .eq('primary_assignee_id', profileId)
        .isFilter('archived_at', null)
        .order('due_at', ascending: true, nullsFirst: false)
        .limit(20);
    final survivors = [
      for (final row in rows)
        if (!taskCountsComplete(category: (row['workflow_statuses'] as Map)['category'] as String, approvalRequired: row['approval_required'] as bool, approvalState: row['approval_state'] as String))
          row['title'],
    ];
    expect(survivors.length, lessThan(6), reason: 'old approach: $survivors');
  }, skip: _live ? false : 'set JIBHR_LIVE_DB=1');
}
