import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jibhr/core/design_system/app_select.dart';
import 'package:jibhr/core/localization/fa.dart';
import 'package:jibhr/core/theme/app_theme.dart';
import 'package:jibhr/features/session/workspace_session.dart';
import 'package:jibhr/features/work/project_pages.dart';
import 'package:jibhr/features/work/task_detail.dart';
import 'package:jibhr/features/work/task_form.dart';
import 'package:jibhr/features/work/widgets/kanban_board.dart';
import 'package:jibhr/features/work/widgets/task_card.dart';
import 'package:jibhr/features/work/widgets/work_ui.dart';
import 'package:jibhr/features/work/work_repository.dart';
import 'package:jibhr/features/work/work_rules.dart';

final _now = DateTime.utc(2026, 11, 8, 9);

({String id, String priority, DateTime? due, DateTime created}) _t(String id, String priority, DateTime? due, {int createdMinute = 0}) =>
    (id: id, priority: priority, due: due, created: DateTime.utc(2026, 11, 1, 8, createdMinute));

List<String> _sorted(List<({String id, String priority, DateTime? due, DateTime created})> rows) {
  final copy = [...rows]..sort((a, b) => compareBoardOrder(priorityA: a.priority, dueA: a.due, createdA: a.created, idA: a.id, priorityB: b.priority, dueB: b.due, createdB: b.created, idB: b.id));
  return [for (final r in copy) r.id];
}

TaskRow _row({
  String id = 't1',
  String category = 'todo',
  String? projectId = 'p1',
  String? assigneeId = 'me',
  String? reviewerId,
  bool approval = false,
  String state = 'not_required',
  int submissions = 0,
  List<ReviewRoundRow> rounds = const [],
}) => TaskRow(
  id: id,
  title: 'بازطراحی داشبورد',
  description: '',
  priority: 'medium',
  approvalRequired: approval,
  approvalState: state,
  requiredSubtask: false,
  assigneeName: 'کارمند',
  assigneeId: assigneeId,
  reviewerId: reviewerId,
  projectId: projectId,
  statusId: category,
  statusName: category,
  statusKey: category,
  statusCategory: category,
  collaborators: const [],
  labels: const [],
  createdAt: _now,
  updatedAt: _now,
  submissions: submissions,
  rounds: rounds,
);

WorkspaceSession _session(String id, Set<String> permissions) =>
    WorkspaceSession(profileId: id, firstName: 'مدیر', lastName: 'پروژه', status: 'active', mustChangePassword: false, permissions: permissions);

ProjectRow _project(List<MemberRow> members) =>
    ProjectRow(id: 'p1', name: 'QA', description: '', visibility: 'project_wide', approvalRequired: true, status: 'active', createdAt: _now, creatorName: '', members: members, labels: const []);

void main() {
  group('board order: priority, due, created_at, id', () {
    final tomorrow = _now.add(const Duration(days: 1));
    final today = _now.add(const Duration(hours: 3));
    final past = _now.subtract(const Duration(days: 2));
    final soon = _now.add(const Duration(days: 2));

    test('critical first, dated before undated, then high, medium, low', () {
      final order = _sorted([
        _t('low-soon', 'low', soon),
        _t('medium-past', 'medium', past),
        _t('critical-undated', 'critical', null),
        _t('high-today', 'high', today),
        _t('critical-tomorrow', 'critical', tomorrow),
      ]);
      expect(order, ['critical-tomorrow', 'critical-undated', 'high-today', 'medium-past', 'low-soon']);
    });

    test('equal priority and due fall back to created_at, then id; stable', () {
      final rows = [_t('b', 'high', today, createdMinute: 5), _t('c', 'high', today, createdMinute: 1), _t('a', 'high', today, createdMinute: 5)];
      expect(_sorted(rows), ['c', 'a', 'b']);
      expect(_sorted(rows.reversed.toList()), ['c', 'a', 'b'], reason: 'input order must not matter');
    });

    test('raising a task to critical moves it to the top of its column', () {
      final rows = [_t('x', 'high', today), _t('y', 'medium', null), _t('z', 'low', soon)];
      expect(_sorted(rows).first, 'x');
      rows[2] = _t('z', 'critical', soon);
      expect(_sorted(rows).first, 'z');
    });

    test('changing a due date reorders within the same priority', () {
      final rows = [_t('x', 'medium', tomorrow), _t('y', 'medium', soon)];
      expect(_sorted(rows), ['x', 'y']);
      rows[1] = _t('y', 'medium', past);
      expect(_sorted(rows), ['y', 'x']);
    });

    test('priority never carries a status: create and update send none', () {
      final create = createTaskParams(title: 'فوری', description: '', projectId: 'p1', assigneeId: 'me', priority: 'critical');
      expect(create.keys.where((k) => k.contains('status')), isEmpty);
      expect(create['p_priority'], 'critical');
      final update = updateTaskParams(_row(category: 'todo'));
      expect(update.keys.where((k) => k.contains('status')), isEmpty);
    });

    test('order inside a column is by priority and due only; the status of a task is not an input', () {
      // Same rows, read in any column (any status, any custom workflow): same order.
      final rows = [_t('a', 'low', today), _t('b', 'critical', null), _t('c', 'critical', tomorrow)];
      expect(_sorted(rows), ['c', 'b', 'a']);
    });

    test('ranks match the generated priority_rank column', () {
      expect(
        [
          for (final p in ['critical', 'high', 'medium', 'low']) priorityRank(p),
        ],
        [4, 3, 2, 1],
      );
    });
  });

  group('kanban geometry: whole columns only', () {
    test('columns that fit share the width; never narrower than the minimum', () {
      final g = kanbanGeometry(1376, 9);
      expect(g.visible, 4);
      expect(g.width * g.visible + kanbanGap * (g.visible - 1), closeTo(1376, 0.01));
      expect(g.width, greaterThanOrEqualTo(kanbanMinColumn));
    });

    test('few columns are capped at the maximum width', () {
      final g = kanbanGeometry(1376, 2);
      expect(g.visible, 2);
      expect(g.width, kanbanMaxColumn);
    });

    test('a narrow viewport still shows one whole column', () {
      final g = kanbanGeometry(300, 9);
      expect(g.visible, 1);
      expect(g.width, 300);
    });
  });

  group('review cycle on the card', () {
    test('awaiting a decision only after a real submission', () {
      expect(reviewState(_row(approval: true, state: 'pending', category: 'backlog'))!.label, Fa.needsApprovalBadge);
      final inReview = reviewState(_row(approval: true, state: 'pending', category: 'in_review', submissions: 2))!;
      expect(inReview.label, '${Fa.inReviewBadge} · v2');
      // "Needs revision" is a decision, not a state: back in the queue it reads as "needs approval".
      expect(reviewState(_row(approval: true, state: 'changes_requested', category: 'changes_requested', submissions: 1))!.label, Fa.needsApprovalBadge);
      expect(reviewState(_row()), isNull);
    });

    test('version label is a badge, never part of the title', () {
      expect(versionLabel(3), 'v3');
      expect(_row(submissions: 3).title, 'بازطراحی داشبورد');
    });

    test('decisions only for an open round', () {
      final open = [ReviewRoundRow(number: 1, openedAt: _now)];
      final decided = [ReviewRoundRow(number: 1, openedAt: _now, decision: 'approved', decidedAt: _now)];
      expect(awaitingDecision(_row(approval: true, state: 'pending', rounds: open)), isTrue);
      expect(awaitingDecision(_row(approval: true, state: 'pending')), isFalse, reason: 'marked for approval but never sent');
      expect(awaitingDecision(_row(approval: true, state: 'approved', rounds: decided)), isFalse);
    });

    test('revision request keeps what and why apart', () {
      final reason = composeRevision(what: 'نمودار ماهانه اضافه شود', why: 'گزارش مدیریت به آن نیاز دارد');
      final parts = parseRevision(reason);
      expect(parts.what, 'نمودار ماهانه اضافه شود');
      expect(parts.why, 'گزارش مدیریت به آن نیاز دارد');
      expect(parseRevision('متن آزاد قدیمی').why, isNull);
    });
  });

  test('one-to-one review embed (object or null) is read, not dropped', () {
    expect(embeddedRows({'decision': 'revision_requested'}).single['decision'], 'revision_requested');
    expect(embeddedRows(null), isEmpty);
    expect(
      embeddedRows([
        {'decision': 'approved'},
      ]).single['decision'],
      'approved',
    );
  });

  group('who may decide or edit', () {
    final members = [
      const MemberRow(profileId: 'pm', name: 'مدیر', role: 'manager'),
      const MemberRow(profileId: 'rev', name: 'بررسی', role: 'reviewer'),
      const MemberRow(profileId: 'me', name: '', role: 'member'),
    ];
    final project = _project(members);

    test('project reviewers and managers decide; plain members do not', () {
      final task = _row(approval: true, state: 'pending');
      expect(canDecideTask(_session('rev', {}), task, project), isTrue);
      expect(canDecideTask(_session('pm', {}), task, project), isTrue);
      expect(canDecideTask(_session('me', {}), task, project), isFalse);
    });

    test('a named reviewer is the only project-level decider', () {
      final task = _row(approval: true, state: 'pending', reviewerId: 'rev');
      expect(canDecideTask(_session('rev', {}), task, project), isTrue);
      expect(canDecideTask(_session('pm', {}), task, project), isFalse);
    });

    test('edit follows update_task: assignee or manage permission', () {
      expect(canEditTask(_session('me', {}), _row()), isTrue);
      expect(canEditTask(_session('rev', {}), _row()), isFalse);
      expect(canEditTask(_session('pm', {'tasks.manage.project'}), _row()), isTrue);
    });
  });

  group('member names, never ids', () {
    final session = _session('pm', {});
    test('hidden profile shows role, not uuid', () {
      const hidden = MemberRow(profileId: '77e789aa-c5af-45d1-92ef-7734c9f9e43d', name: '', role: 'member');
      final label = memberDisplayName(hidden, session);
      expect(label, contains(Fa.projectMemberFallback));
      expect(label, isNot(contains('77e789aa')));
    });
    test('self is labelled', () {
      expect(memberDisplayName(const MemberRow(profileId: 'pm', name: 'مدیر پروژه', role: 'manager'), session), contains(Fa.selfSuffix));
    });
  });

  group('task form assignee list (dropdown bug)', () {
    final session = _session('pm', {'tasks.create.project'});
    final members = [
      const MemberRow(profileId: 'pm', name: 'مدیرپروژه آزمون', role: 'manager'),
      const MemberRow(profileId: 'emp', name: 'کارمند آزمون', role: 'member'),
      const MemberRow(profileId: 'peer', name: 'همکار آزمون', role: 'member'),
    ];
    final project = _project(members);

    Widget app(Widget child, {ProjectRow? fresh, Object? error}) => ProviderScope(
      overrides: [
        projectProvider.overrideWith((ref, id) async {
          if (error != null) throw error;
          return fresh ?? project;
        }),
      ],
      child: MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: MediaQuery(
            data: const MediaQueryData(size: Size(1200, 900)),
            child: Scaffold(body: child),
          ),
        ),
      ),
    );

    Future<List<String>> openAssignee(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('task-form-assignee')));
      await tester.pumpAndSettle();
      final labels = [for (final w in tester.widgetList<Text>(find.descendant(of: find.byType(ListView).last, matching: find.byType(Text)))) w.data ?? ''];
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      return labels;
    }

    Future<void> pumpForm(WidgetTester tester, {ProjectRow? fresh, Object? error, bool personal = false}) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        app(
          TaskForm(session: session, personal: personal, compact: false, project: personal ? null : project),
          fresh: fresh,
          error: error,
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('1: open the list before typing a title: every member', (tester) async {
      await pumpForm(tester);
      final labels = await openAssignee(tester);
      expect(labels, containsAll(['کارمند آزمون', 'همکار آزمون']));
      expect(labels.where((l) => l.contains(Fa.selfSuffix)), isNotEmpty);
    });

    testWidgets('2-4: typing, editing and clearing the title never shrinks the list', (tester) async {
      await pumpForm(tester);
      final title = find.byKey(const Key('task-form-title'));
      await tester.enterText(title, 'بازطراحی');
      await tester.pump();
      expect(await openAssignee(tester), containsAll(['کارمند آزمون', 'همکار آزمون']));
      await tester.enterText(title, 'بازطراحی داشبورد');
      await tester.enterText(title, '');
      await tester.enterText(title, 'دوباره');
      await tester.pump();
      expect(await openAssignee(tester), containsAll(['کارمند آزمون', 'همکار آزمون']));
    });

    testWidgets('5: search by name, pick, the field shows the name', (tester) async {
      await pumpForm(tester);
      await tester.enterText(find.byKey(const Key('task-form-title')), 'عنوان');
      await tester.tap(find.byKey(const Key('task-form-assignee')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('select-search')), 'همکار');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('option-emp')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('option-peer')));
      await tester.pumpAndSettle();
      expect(find.descendant(of: find.byKey(const Key('task-form-assignee')), matching: find.text('همکار آزمون')), findsOneWidget);
    });

    testWidgets('6: personal task: fixed assignee, no picker', (tester) async {
      await pumpForm(tester, personal: true);
      expect(find.byType(FixedAssignee), findsOneWidget);
      expect(find.byType(AppSelectField<String>), findsNothing);
      expect(find.textContaining(Fa.selfSuffix), findsWidgets);
    });

    testWidgets('7: the fresh project read decides the list', (tester) async {
      await pumpForm(
        tester,
        fresh: _project([...members, const MemberRow(profileId: 'new', name: 'عضو جدید', role: 'member')]),
      );
      expect(await openAssignee(tester), contains('عضو جدید'));
    });

    testWidgets('a failed member read is an error with retry, not a one-person list', (tester) async {
      await pumpForm(tester, error: Exception('network'));
      await tester.tap(find.byKey(const Key('task-form-assignee')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('select-error')), findsOneWidget);
      expect(find.text(Fa.retry), findsOneWidget);
    });
  });
}
