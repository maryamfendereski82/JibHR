// Live checks of the board order and of the assignment inbox against the
// local Supabase, with two real accounts (A = qa.pm, B = qa.employee).
//
// Opt-in: JIBHR_LIVE_DB=1 flutter test test/work/task_assignment_live_test.dart
// Needs the local stack (container supabase_db_jibhr), env.json and
// .local/qa-accounts.json. Every row it makes is titled "QA-P7 …" and is
// removed afterwards (tasks, their events, rounds, audit and notifications),
// also when a test fails.
@Tags(['live'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jibhr/features/work/work_repository.dart';
import 'package:jibhr/features/work/work_rules.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _marker = 'QA-P7';
final _live = Platform.environment['JIBHR_LIVE_DB'] == '1';

Future<String> _psql(String sql) async {
  final result = await Process.run('docker', ['exec', '-i', 'supabase_db_jibhr', 'psql', '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-At', '-c', sql]);
  if (result.exitCode != 0) throw StateError('psql: ${result.stderr}');
  return (result.stdout as String).trim();
}

const _cleanup =
    '''
begin;
set local session_replication_role = replica;
create temp table qa_p7 on commit drop as select id from public.tasks where title like '$_marker%';
delete from public.task_reviews where round_id in (select id from public.task_review_rounds where task_id in (select id from qa_p7));
delete from public.task_review_rounds where task_id in (select id from qa_p7);
delete from public.task_activity_events where task_id in (select id from qa_p7);
delete from public.task_collaborators where task_id in (select id from qa_p7);
delete from public.notifications where entity_id in (select id from qa_p7);
delete from public.audit_logs where entity_id in (select id from qa_p7);
delete from public.tasks where id in (select id from qa_p7);
commit;
''';

void main() {
  final clients = <String, SupabaseClient>{};
  final ids = <String, String>{};
  late String projectId;
  late WorkflowRow flow;

  Future<SupabaseClient> signIn(String who, Map<String, dynamic> env, Map<String, dynamic> accounts) async {
    final client = SupabaseClient(env['SUPABASE_URL'] as String, env['SUPABASE_PUBLISHABLE_KEY'] as String, authOptions: const AuthClientOptions(autoRefreshToken: false));
    final auth = await client.auth.signInWithPassword(email: '$who@jibhr.local', password: (accounts[who] as Map<String, dynamic>)['password'] as String);
    ids[who] = auth.user!.id;
    return client;
  }

  WorkRepository repo(String who) => WorkRepository(clients[who]!);

  TaskFilter filter({String? assigneeId, String? statusId, String? project, String sort = boardSort}) =>
      (projectId: project, personal: false, assigneeId: assigneeId, statusId: statusId, priority: null, search: _marker, dueFrom: null, dueTo: null, page: 0, sort: sort);

  StatusRow status(String category) => flow.statuses.firstWhere((s) => s.category == category);

  /// Changes only the priority through update_task, every other field as stored.
  Future<void> setPriority(WorkRepository repository, String id, String priority) async {
    final full = (await repository.task(id))!;
    await repository.updateTask(
      TaskRow(
        id: full.id,
        title: full.title,
        description: full.description,
        priority: priority,
        approvalRequired: full.approvalRequired,
        approvalState: full.approvalState,
        requiredSubtask: false,
        assigneeId: full.assigneeId,
        assigneeName: '',
        reviewerId: full.reviewerId,
        statusId: full.statusId,
        statusName: '',
        statusKey: '',
        statusCategory: '',
        collaborators: const [],
        labels: const [],
        createdAt: full.createdAt,
        updatedAt: full.updatedAt,
      ),
      dueIso: full.dueAt?.toIso8601String(),
    );
  }

  setUpAll(() async {
    if (!_live) return;
    await _psql(_cleanup);
    final env = jsonDecode(File('env.json').readAsStringSync()) as Map<String, dynamic>;
    final accounts = (jsonDecode(File('.local/qa-accounts.json').readAsStringSync()) as Map<String, dynamic>)['accounts'] as Map<String, dynamic>;
    for (final who in ['qa.pm', 'qa.employee', 'qa.outsider']) {
      clients[who] = await signIn(who, env, accounts);
    }
    projectId = await _psql("select id from public.projects where name = 'QA پروژه'");
    flow = (await repo('qa.pm').project(projectId))!.workflow!;
  });

  tearDownAll(() async {
    if (!_live) return;
    await _psql(_cleanup);
    for (final client in clients.values) {
      await client.auth.signOut();
    }
  });

  test('board order from the server; priority never changes the status', () async {
    final now = DateTime.now().toUtc();
    final pm = repo('qa.pm');
    Future<String> make(String name, String priority, DateTime? due) =>
        pm.createTask(title: '$_marker $name', description: '', projectId: projectId, assigneeId: ids['qa.pm']!, priority: priority, dueIso: due?.toIso8601String());
    await make('low near', 'low', now.add(const Duration(days: 1)));
    await make('medium past', 'medium', now.subtract(const Duration(days: 2)));
    await make('critical undated', 'critical', null);
    await make('high today', 'high', now.add(const Duration(hours: 2)));
    await make('critical tomorrow', 'critical', now.add(const Duration(days: 1)));
    await make('tie 1', 'medium', DateTime.utc(2027, 1, 1, 8));
    await make('tie 2', 'medium', DateTime.utc(2027, 1, 1, 8));

    final backlog = status('backlog');
    List<String> titles(TaskPage page) => [for (final t in page.tasks) t.title.replaceFirst('$_marker ', '')];
    final column = await pm.tasks(filter(project: projectId, statusId: backlog.id));
    expect(titles(column), ['critical tomorrow', 'critical undated', 'high today', 'medium past', 'tie 1', 'tie 2', 'low near']);
    // The same order twice: stable paging.
    expect(titles(await pm.tasks(filter(project: projectId, statusId: backlog.id))), titles(column));

    // Rule: creating a Critical task changes nothing in the workflow. Every
    // new task, Critical included, is in the workflow's initial status.
    for (final task in column.tasks) {
      expect(task.statusId, backlog.id, reason: '${task.title} starts in the initial status');
    }
    expect(
      (await pm.tasks(filter(project: projectId, statusId: status('in_review').id))).tasks,
      isEmpty,
      reason: 'nothing jumps into review',
    );

    // Raising "low near" to critical puts it at the top (nearest critical due)
    // and leaves its status exactly as it was.
    final low = column.tasks.firstWhere((t) => t.title.endsWith('low near'));
    await setPriority(pm, low.id, 'critical');
    expect(titles(await pm.tasks(filter(project: projectId, statusId: backlog.id))).first, 'low near');
    expect((await pm.task(low.id))!.statusId, backlog.id, reason: 'priority alone never changes the status');

    // Review is entered only by the workflow's own transitions (the
    // assignee sending it). Inside the review column the same order holds.
    final after = (await pm.tasks(filter(project: projectId, statusId: backlog.id))).tasks;
    final critical = after.firstWhere((t) => t.title.endsWith('critical undated'));
    final high = after.firstWhere((t) => t.title.endsWith('high today'));
    for (final task in [high, critical]) {
      for (final category in ['todo', 'in_progress', 'in_review']) {
        await pm.transition(task.id, status(category).id);
      }
    }
    final inReview = status('in_review');
    expect(titles(await pm.tasks(filter(project: projectId, statusId: inReview.id))), ['critical undated', 'high today']);

    // Lowering the Critical one inside review: it stays in review, only its
    // place in the column changes.
    await setPriority(pm, critical.id, 'low');
    expect((await pm.task(critical.id))!.statusId, inReview.id);
    expect(titles(await pm.tasks(filter(project: projectId, statusId: inReview.id))), ['high today', 'critical undated']);
  }, skip: _live ? false : 'set JIBHR_LIVE_DB=1');

  test('reassigning moves the task between the two people\'s "my tasks"', () async {
    final pm = repo('qa.pm');
    final employee = repo('qa.employee');
    final id = await pm.createTask(
      title: '$_marker inbox',
      description: '',
      projectId: projectId,
      assigneeId: ids['qa.employee']!,
      priority: 'high',
      dueIso: DateTime.utc(2027, 2, 1).toIso8601String(),
    );

    // B sees it as assigned to B, with project, priority and due date.
    final mineB = await employee.tasks(filter(assigneeId: ids['qa.employee']));
    final seen = mineB.tasks.where((t) => t.id == id).single;
    expect(seen.projectName, 'QA پروژه');
    expect(seen.priority, 'high');
    expect(seen.dueAt, DateTime.utc(2027, 2, 1));
    // A created it but is not its assignee: not in A's "my tasks".
    expect((await pm.tasks(filter(assigneeId: ids['qa.pm']))).tasks.where((t) => t.id == id), isEmpty);

    // A hands it to A; B's "my tasks" drops it on the next read.
    final full = (await pm.task(id))!;
    await pm.updateTask(
      TaskRow(
        id: id,
        title: full.title,
        description: full.description,
        priority: full.priority,
        approvalRequired: full.approvalRequired,
        approvalState: full.approvalState,
        requiredSubtask: false,
        assigneeId: ids['qa.pm'],
        assigneeName: '',
        reviewerId: full.reviewerId,
        statusId: full.statusId,
        statusName: '',
        statusKey: '',
        statusCategory: '',
        collaborators: const [],
        labels: const [],
        createdAt: full.createdAt,
        updatedAt: full.updatedAt,
      ),
      dueIso: full.dueAt?.toIso8601String(),
    );
    expect((await employee.tasks(filter(assigneeId: ids['qa.employee']))).tasks.where((t) => t.id == id), isEmpty);
    expect((await pm.tasks(filter(assigneeId: ids['qa.pm']))).tasks.where((t) => t.id == id), hasLength(1));
    expect((await pm.task(id))!.assigneeId, ids['qa.pm']);
  }, skip: _live ? false : 'set JIBHR_LIVE_DB=1');

  test('REPRODUCES the backend gap: an assignee outside a project_wide project cannot see the task', () async {
    // create_task accepts any assignee, but app.task_visible_directly only
    // lets members see project_wide tasks. Flip these expectations when the
    // proposed fix (docs/task-workflow-proposal.md, section 8) is applied.
    final id = await repo('qa.pm').createTask(title: '$_marker outsider', description: '', projectId: projectId, assigneeId: ids['qa.outsider']!, priority: 'medium');
    expect(await _psql("select primary_assignee_id from public.tasks where id = '$id'"), ids['qa.outsider'], reason: 'assignee is stored');
    final mine = await repo('qa.outsider').tasks(filter(assigneeId: ids['qa.outsider']));
    expect(mine.tasks.where((t) => t.id == id), isEmpty, reason: 'today the outsider cannot see their own task');
  }, skip: _live ? false : 'set JIBHR_LIVE_DB=1');

  test('REPRODUCES the picker root cause: profile RLS hides other members from a project manager', () async {
    final people = await repo('qa.pm').people('');
    expect(people.map((p) => p.id), [ids['qa.pm']], reason: 'profiles_select = can_view_employee: only self');
    // The member list itself is readable (ids and roles), so the form uses it.
    final project = (await repo('qa.pm').project(projectId))!;
    expect(project.members.map((m) => m.profileId), containsAll([ids['qa.pm'], ids['qa.employee']]));
    expect(project.members.firstWhere((m) => m.profileId == ids['qa.employee']).name, isEmpty, reason: 'the name is hidden by the same RLS');
  }, skip: _live ? false : 'set JIBHR_LIVE_DB=1');
}
