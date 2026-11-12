import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jibhr/core/localization/fa.dart';
import 'package:jibhr/core/theme/app_theme.dart';
import 'package:jibhr/features/session/workspace_session.dart';
import 'package:jibhr/features/work/task_actions.dart';
import 'package:jibhr/features/work/widgets/work_ui.dart';
import 'package:jibhr/features/work/work_repository.dart';
import 'package:jibhr/features/work/workflow_presentation.dart';

// The nine-status default workflow the database still has before the migration.
const _keys = ['backlog', 'todo', 'in_progress', 'in_review', 'approved', 'done', 'blocked', 'changes_requested', 'rejected'];
final _flow = WorkflowRow(
  id: 'w',
  statuses: [
    for (var i = 0; i < _keys.length; i++) StatusRow(id: _keys[i], key: _keys[i], name: 'stored-${_keys[i]}', category: _keys[i], position: i, requiresAuthority: false, active: true),
  ],
  transitions: const [
    (from: 'backlog', to: 'todo'),
    (from: 'todo', to: 'in_progress'),
    (from: 'in_progress', to: 'in_review'),
    (from: 'in_progress', to: 'blocked'),
    (from: 'blocked', to: 'in_progress'),
    (from: 'in_review', to: 'approved'),
    (from: 'approved', to: 'done'),
    (from: 'in_review', to: 'changes_requested'),
    (from: 'changes_requested', to: 'in_progress'),
    (from: 'in_review', to: 'rejected'),
  ],
);

TaskRow _task(String category, {bool approval = false}) => TaskRow(
  id: 't',
  title: 'T',
  description: '',
  priority: 'medium',
  approvalRequired: approval,
  approvalState: approval ? 'pending' : 'not_required',
  requiredSubtask: false,
  assigneeName: 'A',
  statusId: category,
  statusName: 'stored-$category',
  statusKey: category,
  statusCategory: category,
  collaborators: const [],
  labels: const [],
  createdAt: DateTime.utc(2026, 11, 1),
  updatedAt: DateTime.utc(2026, 11, 1),
);

List<String>? _path(TaskRow task, TaskAction action) => actionPath(task, _flow, action)?.map((s) => s.id).toList();

TaskRow _owned(String category, {bool approval = false, String assignee = 'me'}) => TaskRow(
  id: 't',
  title: 'T',
  description: '',
  priority: 'medium',
  approvalRequired: approval,
  approvalState: approval ? 'pending' : 'not_required',
  requiredSubtask: false,
  assigneeName: 'A',
  assigneeId: assignee,
  statusId: category,
  statusName: 'stored-$category',
  statusKey: category,
  statusCategory: category,
  collaborators: const [],
  labels: const [],
  createdAt: DateTime.utc(2026, 11, 1),
  updatedAt: DateTime.utc(2026, 11, 1),
);

void main() {
  test('every stored category maps to one of five statuses', () {
    expect({for (final k in _keys) k: groupOfCategory(k)}, {
      'backlog': TaskGroup.backlog,
      'todo': TaskGroup.backlog,
      'changes_requested': TaskGroup.backlog,
      'in_progress': TaskGroup.inProgress,
      'in_review': TaskGroup.inReview,
      'approved': TaskGroup.approved,
      'done': TaskGroup.approved,
      'blocked': TaskGroup.rejected,
      'rejected': TaskGroup.rejected,
    });
  });

  test('the board has exactly five columns in workflow order', () {
    expect(groupColumns().map((c) => c.name), [Fa.groupBacklog, Fa.groupInProgress, Fa.groupInReview, Fa.groupApproved, Fa.groupRejected]);
    for (final retired in ['انجام‌نشده', 'نیاز به اصلاح', 'مسدود', 'انجام‌شده']) {
      expect(groupColumns().map((c) => c.name), isNot(contains(retired)));
    }
  });

  testWidgets('the five status colours are all different', (tester) async {
    final p = AppPalette.light;
    final tones = {for (final g in taskGroups) statusTone(p, groupCategory(g))};
    expect(tones, hasLength(5));
  });

  test('filters offer the five statuses and the two rejected marks only', () {
    final labels = statusFilterChoices().map((c) => c.label).toList();
    expect(labels, hasLength(7));
    expect(labels.where((l) => l.contains('انجام‌نشده') || l.contains('نیاز به اصلاح')), isEmpty);
    expect(categoriesForKey(groupKey(TaskGroup.backlog)), ['backlog', 'todo', 'changes_requested']);
    expect(categoriesForKey(groupKey(TaskGroup.inProgress)), ['in_progress']);
    expect(categoriesForKey(groupKey(TaskGroup.approved)), ['approved', 'done']);
    expect(categoriesForKey(rejectedKindKey(RejectedKind.blocked)), ['blocked']);
    expect(categoriesForKey(rejectedKindKey(RejectedKind.finalRejected)), ['rejected']);
    expect(categoriesForKey('a-status-id'), isNull);
  });

  group('transitions along the stored workflow', () {
    test('start: backlog (todo, needs revision) → in progress', () {
      expect(_path(_task('backlog'), TaskAction.start), ['todo', 'in_progress']);
      expect(_path(_task('changes_requested', approval: true), TaskAction.start), ['in_progress'], reason: 'after a revision request');
      expect(_path(_task('in_progress'), TaskAction.start), isNull);
    });

    test('submit: in progress → in review, only with approval', () {
      expect(_path(_task('in_progress', approval: true), TaskAction.submit), ['in_review']);
      expect(_path(_task('backlog', approval: true), TaskAction.submit), isNull, reason: 'start first');
      expect(_path(_task('in_progress'), TaskAction.submit), isNull);
    });

    test('complete (no approval): in progress → approved; never with approval', () {
      final path = _path(_task('in_progress'), TaskAction.complete)!;
      expect(groupOfCategory(path.last), TaskGroup.approved);
      expect(_path(_task('in_progress', approval: true), TaskAction.complete), isNull);
      expect(_path(_task('backlog'), TaskAction.complete), isNull);
    });

    test('return to the cycle: blocked has its stored way out; a final rejection has none before the migration', () {
      expect(_path(_task('blocked'), TaskAction.returnToCycle), ['in_progress']);
      expect(_path(_task('rejected'), TaskAction.returnToCycle), isNull);
    });

    test('block: from in progress only', () {
      expect(_path(_task('in_progress'), TaskAction.block), ['blocked']);
      expect(_path(_task('backlog'), TaskAction.block), isNull);
      expect(_path(_task('in_review', approval: true), TaskAction.block), isNull);
    });

    test('one primary action per status; none in review or approved', () {
      expect(primaryAction(_task('todo')), TaskAction.start);
      expect(primaryAction(_task('in_progress', approval: true)), TaskAction.submit);
      expect(primaryAction(_task('in_progress')), TaskAction.complete);
      expect(primaryAction(_task('in_review', approval: true)), isNull, reason: 'the reviewer decides');
      expect(primaryAction(_task('approved')), isNull);
      expect(primaryAction(_task('blocked')), TaskAction.returnToCycle);
      expect(primaryAction(_task('rejected')), TaskAction.returnToCycle);
    });

    test('drops mean the same actions; anything else is refused', () {
      expect(dropAction(_task('todo'), TaskGroup.inProgress), TaskAction.start);
      expect(dropAction(_task('in_progress', approval: true), TaskGroup.inReview), TaskAction.submit);
      expect(dropAction(_task('in_progress'), TaskGroup.approved), TaskAction.complete);
      expect(dropAction(_task('blocked'), TaskGroup.backlog), TaskAction.returnToCycle);
      expect(dropAction(_task('todo'), TaskGroup.inReview), isNull, reason: 'start first');
      expect(dropAction(_task('in_review', approval: true), TaskGroup.approved), isNull, reason: 'approval is a reviewer decision');
      expect(dropAction(_task('in_review', approval: true), TaskGroup.backlog), isNull, reason: 'a revision request is a decision');
      expect(dropAction(_task('in_progress'), TaskGroup.rejected), isNull, reason: 'rejection only through review');
    });
  });

  group('who may do what', () {
    bool allowed(TaskRow task, TaskAction action, {bool assignee = false, bool edit = false, bool manager = false}) =>
        actionAllowed(task, action, isAssignee: assignee, canEdit: edit, canReopenRejected: manager);

    test('start, submit and complete: the primary assignee only, not a manager', () {
      for (final action in [TaskAction.start, TaskAction.submit, TaskAction.complete]) {
        expect(allowed(_owned('todo'), action, assignee: true), isTrue);
        expect(allowed(_owned('todo'), action, edit: true, manager: true), isFalse, reason: '$action by a manager');
      }
    });

    test('reopening a final rejection needs tasks.manage.project; seeing every task is not enough', () {
      WorkspaceSession session(Set<String> permissions) =>
          WorkspaceSession(profileId: 'p', firstName: 'م', lastName: 'ن', status: 'active', mustChangePassword: false, permissions: permissions);
      expect(canReopenRejected(session({'tasks.manage.project'})), isTrue);
      expect(canReopenRejected(session({'tasks.view.all'})), isFalse);
      expect(canReopenRejected(session(const {})), isFalse);
      expect(canReopenRejected(null), isFalse);
    });

    test('a final rejection is reopened by management only; a blocked task by anyone who may edit it', () {
      expect(allowed(_owned('rejected'), TaskAction.returnToCycle, assignee: true, edit: true), isFalse);
      expect(allowed(_owned('rejected'), TaskAction.returnToCycle, manager: true), isTrue);
      expect(allowed(_owned('blocked'), TaskAction.returnToCycle, edit: true), isTrue);
      expect(allowed(_owned('blocked'), TaskAction.returnToCycle), isFalse);
    });
  });

  testWidgets('a status pill never shows a retired name', (tester) async {
    for (final k in _keys) {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: Scaffold(body: StatusBadge(name: 'stored-$k', category: k)),
        ),
      );
      expect(find.textContaining('stored-'), findsNothing);
      expect(find.text(groupLabel(groupOfCategory(k))), findsOneWidget);
    }
  });

  testWidgets('blocked and final rejection are told apart by a mark', (tester) async {
    await tester.pumpWidget(MaterialApp(theme: buildAppTheme(Brightness.light), home: Scaffold(body: Column(children: [rejectedMark('blocked')!, rejectedMark('rejected')!]))));
    expect(find.text(Fa.catBlocked), findsOneWidget);
    expect(find.text(Fa.finalRejectedBadge), findsOneWidget);
    expect(rejectedMark('in_progress'), isNull);
  });
}
