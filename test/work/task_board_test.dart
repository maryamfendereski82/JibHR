import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jibhr/core/calendar/tehran_time.dart';
import 'package:jibhr/core/localization/fa.dart';
import 'package:jibhr/core/theme/app_theme.dart';
import 'package:jibhr/features/attendance/jalali_fields.dart';
import 'package:jibhr/features/session/workspace_session.dart';
import 'package:jibhr/features/work/task_board.dart';
import 'package:jibhr/features/work/task_detail.dart';
import 'package:jibhr/features/work/widgets/kanban_board.dart';
import 'package:jibhr/features/work/widgets/task_card.dart';
import 'package:jibhr/features/work/widgets/work_ui.dart';
import 'package:jibhr/features/work/work_repository.dart';
import 'package:jibhr/features/work/workflow_presentation.dart';
import 'package:shamsi_date/shamsi_date.dart';

StatusRow _status(String id, String category, {bool active = true}) => StatusRow(id: id, key: id, name: 'S-$id', category: category, position: 0, requiresAuthority: false, active: active);

TaskRow _task(String id, {String statusId = 'todo', DateTime? due, String priority = 'medium', String title = 'T'}) => TaskRow(
  id: id,
  title: '$title $id',
  description: '',
  priority: priority,
  approvalRequired: false,
  approvalState: 'not_required',
  requiredSubtask: false,
  assigneeName: 'کارمند',
  statusId: statusId,
  statusName: 'S-$statusId',
  statusKey: statusId,
  statusCategory: 'todo',
  collaborators: const [],
  labels: const [],
  createdAt: DateTime.utc(2026, 11, 1),
  updatedAt: DateTime.utc(2026, 11, 1),
  dueAt: due,
);

final _flow = WorkflowRow(
  id: 'w',
  statuses: [_status('todo', 'todo'), _status('doing', 'in_progress'), _status('done', 'done'), _status('old', 'todo', active: false)],
  transitions: const [(from: 'todo', to: 'doing'), (from: 'doing', to: 'done'), (from: 'todo', to: 'old')],
);

Widget _app(Widget child) => ProviderScope(
  child: MaterialApp(
    theme: buildAppTheme(Brightness.light),
    home: Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(body: child),
    ),
  ),
);

void main() {
  group('move targets', () {
    test('only transitions the workflow allows, active statuses only', () {
      expect(allowedTargets(_task('a'), _flow).map((s) => s.id), ['doing']);
      expect(allowedTargets(_task('a', statusId: 'doing'), _flow).map((s) => s.id), ['done']);
      expect(allowedTargets(_task('a', statusId: 'done'), _flow), isEmpty);
      expect(allowedTargets(_task('a'), null), isEmpty);
    });

    testWidgets('the card menu offers actions, never a status list', (tester) async {
      TaskAction? chosen;
      final task = _task('a');
      await tester.pumpWidget(
        _app(
          SizedBox(
            width: 300,
            child: TaskCard(task: task, now: DateTime.utc(2026, 11, 8), onOpen: () {}, actions: const [TaskAction.complete, TaskAction.block], onAction: (a) => chosen = a),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('card-menu-a')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('action-a-complete')), findsOneWidget);
      expect(find.text('S-doing'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('action-a-complete')));
      await tester.pumpAndSettle();
      expect(chosen, TaskAction.complete);
    });

    testWidgets('without actions the menu only opens the task', (tester) async {
      final task = _task('a', statusId: 'done');
      await tester.pumpWidget(_app(SizedBox(width: 300, child: TaskCard(task: task, now: DateTime.utc(2026, 11, 8), onOpen: () {}, onAction: (_) {}))));
      await tester.tap(find.byKey(const ValueKey('card-menu-a')));
      await tester.pumpAndSettle();
      expect(find.text(Fa.open), findsOneWidget);
      expect(find.textContaining(Fa.actionComplete), findsNothing);
    });
  });

  group('due date on save', () {
    // 1405/08/20 17:45:30 Tehran, with seconds, as the server may store it.
    final stored = TehranTime.toUtcFromJalali(1405, 8, 20, 17, 45).add(const Duration(seconds: 30));

    test('the editable stamp is the stored Tehran day and time', () {
      final stamp = stampOf(stored);
      expect([stamp.year, stamp.month, stamp.day, stamp.hour, stamp.minute], [1405, 8, 20, 17, 45]);
    });

    test('an untouched due date is sent back exactly, not reset to today', () {
      expect(dueToSend(original: stored, withDue: true, due: stampOf(stored)), stored);
    });

    test('a changed day is sent, a cleared due date is null, a new one is set', () {
      final changed = dueToSend(original: stored, withDue: true, due: stampOf(stored).copyWith(day: 22));
      expect(dueOnDay(changed!, 1405, 8, 22), isTrue);
      expect(dueToSend(original: stored, withDue: false, due: stampOf(stored)), isNull);
      final fresh = dueToSend(original: null, withDue: true, due: const JalaliStamp(year: 1405, month: 9, day: 1));
      expect(dueOnDay(fresh!, 1405, 9, 1), isTrue);
    });
  });

  testWidgets('task details: seeded due date, save bar only when dirty', (tester) async {
    tester.view.physicalSize = const Size(1300, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final stored = TehranTime.toUtcFromJalali(1405, 8, 20, 17, 45);
    final row = _task('d', due: stored);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          taskProvider('d').overrideWith((ref) async => row),
          personalWorkflowProvider.overrideWith((ref) async => _flow),
          // Editing needs a session the server would accept (manage permission).
          workspaceSessionProvider.overrideWith(
            (ref) async => const WorkspaceSession(profileId: 'pm', firstName: 'مدیر', lastName: 'آزمون', status: 'active', mustChangePassword: false, permissions: {'tasks.manage.project'}),
          ),
        ],
        child: MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: const Directionality(
            textDirection: TextDirection.rtl,
            child: Scaffold(body: TaskDetailPage(taskId: 'd')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('save-bar')), findsNothing);
    // The stored due date is shown, not today's.
    expect(find.textContaining('۲۰ آبان ۱۴۰۵'), findsOneWidget);
    // View-first: no input fields until "edit"; an empty description is a quiet line.
    expect(find.byKey(const Key('detail-title')), findsNothing);
    expect(find.byKey(const Key('detail-description')), findsNothing);
    expect(find.byKey(const Key('description-empty')), findsOneWidget);
    expect(find.text(Fa.noTaskDescription), findsOneWidget);
    await tester.tap(find.byKey(const Key('detail-edit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('detail-description')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('detail-title')), 'عنوان تازه');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('save-bar')), findsOneWidget);
    await tester.tap(find.byKey(const Key('discard-changes')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('save-bar')), findsNothing);
    await tester.tap(find.byKey(const Key('detail-cancel-edit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('detail-title')), findsNothing);
    expect(find.byKey(const Key('detail-edit')), findsOneWidget);
  });

  testWidgets('a person who may not edit a personal task gets no edit action', (tester) async {
    tester.view.physicalSize = const Size(1300, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final row = _task('r');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          taskProvider('r').overrideWith((ref) async => row),
          personalWorkflowProvider.overrideWith((ref) async => _flow),
          workspaceSessionProvider.overrideWith(
            (ref) async => const WorkspaceSession(profileId: 'other', firstName: 'دیگر', lastName: 'کاربر', status: 'active', mustChangePassword: false, permissions: {}),
          ),
        ],
        child: MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: const Directionality(
            textDirection: TextDirection.rtl,
            child: Scaffold(body: TaskDetailPage(taskId: 'r')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('detail-edit')), findsNothing);
    expect(find.byKey(const Key('detail-title-text')), findsOneWidget);
  });

  group('priority and status stay apart', () {
    testWidgets('each priority has its own card colour in both themes; status does not change it', (tester) async {
      for (final brightness in Brightness.values) {
        final colors = <String, Color>{};
        for (final priority in const ['critical', 'high', 'medium', 'low']) {
          late PriorityStyle style;
          await tester.pumpWidget(
            MaterialApp(
              theme: buildAppTheme(brightness),
              home: Builder(
                builder: (context) {
                  style = PriorityStyle.of(context, priority);
                  return const SizedBox();
                },
              ),
            ),
          );
          colors[priority] = style.fill;
          final p = brightness == Brightness.dark ? AppPalette.dark : AppPalette.light;
          // The chip label meets 4.5:1 on its own chip.
          expect(_contrast(style.tone, style.chip), greaterThanOrEqualTo(4.5), reason: '$priority $brightness');
          expect(style.fill, isNot(p.surface));
        }
        expect(colors.values.toSet().length, 4, reason: 'four distinct card tints ($brightness)');
      }
    });

    testWidgets('the card rail follows priority, not status', (tester) async {
      Future<Color> railOf(String priority, String status) async {
        final task = _task('z', priority: priority, statusId: status);
        await tester.pumpWidget(_app(SizedBox(width: 300, child: TaskCard(task: task, now: DateTime.utc(2026, 11, 8), onOpen: () {}))));
        return (tester.widget<ColoredBox>(find.byKey(const ValueKey('priority-rail-z')))).color;
      }

      final criticalTodo = await railOf('critical', 'todo');
      final criticalDone = await railOf('critical', 'done');
      final lowTodo = await railOf('low', 'todo');
      expect(criticalTodo, criticalDone);
      expect(criticalTodo, isNot(lowTodo));
      expect(find.byKey(const ValueKey('priority-badge-low')), findsOneWidget);
    });
  });

  group('board arrows', () {
    Future<KanbanNav> pumpBoard(WidgetTester tester, {required double width, required int columns}) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final nav = KanbanNav();
      addTearDown(nav.dispose);
      final statuses = [for (var i = 0; i < columns; i++) _status('c$i', 'todo')];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [taskPageProvider.overrideWith((ref, filter) async => TaskPage.empty)],
          child: _app(
            KanbanBoard(
              statuses: statuses,
              flow: WorkflowRow(id: 'w', statuses: statuses, transitions: const []),
              filterFor: (id) => (projectId: 'p', personal: false, assigneeId: null, statusId: id, priority: null, search: '', dueFrom: null, dueTo: null, page: 0, sort: 'board'),
              onPage: (_, _) {},
              onOpen: (_) {},
              onMove: (_, _) {},
              now: DateTime.utc(2026, 11, 8),
              nav: nav,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return nav;
    }

    testWidgets('no arrows and no range text when every column fits', (tester) async {
      final nav = await pumpBoard(tester, width: 1400, columns: 3);
      expect(nav.overflow, isFalse);
      expect(find.textContaining('ستون‌های'), findsNothing);
    });

    testWidgets('arrows only with hidden columns; disabled at the ends', (tester) async {
      final nav = await pumpBoard(tester, width: 1100, columns: 9);
      expect(nav.overflow, isTrue);
      expect(nav.canBack, isFalse);
      expect(nav.canForward, isTrue);
      for (var i = 0; i < 9; i++) {
        nav.forward();
        await tester.pumpAndSettle();
      }
      expect(nav.canForward, isFalse);
      expect(nav.canBack, isTrue);
    });

    testWidgets('an empty column is a short line, not a box', (tester) async {
      await pumpBoard(tester, width: 1400, columns: 2);
      expect(find.text(Fa.emptyQueue), findsNWidgets(2));
      final column = tester.getSize(find.byKey(const ValueKey('column-body-c0')));
      expect(column.height, lessThan(140));
    });
  });

  test('activity details are words, never ids', () {
    final names = {'s-done': 'انجام‌شده'};
    final moved = ActivityRow(action: 'task.transition', createdAt: DateTime.utc(2026), actor: 'مدیر', metadata: const {'to': 's-done'});
    expect(activityDetail(moved, names), contains('انجام‌شده'));
    final unknown = ActivityRow(action: 'task.transition', createdAt: DateTime.utc(2026), actor: 'مدیر', metadata: const {'to': '77e789aa-c5af-45d1-92ef-7734c9f9e43d'});
    expect(activityDetail(unknown, names), isNull);
    final priority = ActivityRow(action: 'task.priority', createdAt: DateTime.utc(2026), actor: 'مدیر', metadata: const {'from': 'medium', 'to': 'critical'});
    expect(activityDetail(priority, names), allOf(contains(Fa.priorityMedium), contains(Fa.priorityCritical)));
  });

  group('board filters', () {
    test('due windows are server bounds from a fixed anchor', () {
      final now = DateTime.utc(2026, 11, 8, 10);
      expect(dueBounds(DueWindow.any, now), (from: null, to: null));
      expect(dueBounds(DueWindow.week, now).to, DateTime.utc(2026, 11, 15, 10).toIso8601String());
      expect(dueBounds(DueWindow.past, now), (from: null, to: now.toIso8601String()));
    });

    test('search waits 300 ms', () => expect(searchDebounce, const Duration(milliseconds: 300)));
  });

  group('calendar', () {
    test('months start on Saturday and fill whole weeks', () {
      final cells = monthCells(Jalali(1405, 8, 1));
      expect(cells.length % 7, 0);
      final first = cells.indexWhere((c) => c != null);
      expect(first, Jalali(1405, 8, 1).weekDay - 1);
      expect(cells.whereType<Jalali>().length, Jalali(1405, 8, 1).monthLength);
    });

    testWidgets('two tasks on one day with the same priority both render', (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final due = TehranTime.toUtcFromJalali(1405, 8, 10, 12, 0);
      final tasks = [_task('x', due: due, priority: 'high'), _task('y', due: due, priority: 'high')];
      Jalali? tapped;
      await tester.pumpWidget(
        _app(
          TaskCalendarView(
            month: Jalali(1405, 8, 1),
            now: DateTime.utc(2026, 11, 1),
            selectedDay: null,
            data: AsyncData((tasks: tasks, truncated: false)),
            onMonth: (_) {},
            onDay: (d) => tapped = d,
            onRetry: () {},
            onOpen: (_) {},
            onMove: (_, _) {},
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('cal-x')), findsOneWidget);
      expect(find.byKey(const ValueKey('cal-y')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('day-10')));
      expect(tapped, Jalali(1405, 8, 10));
    });

    testWidgets('a truncated month says so', (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _app(
          TaskCalendarView(
            month: Jalali(1405, 8, 1),
            now: DateTime.utc(2026, 11, 1),
            selectedDay: null,
            data: const AsyncData((tasks: <TaskRow>[], truncated: true)),
            onMonth: (_) {},
            onDay: (_) {},
            onRetry: () {},
            onOpen: (_) {},
            onMove: (_, _) {},
          ),
        ),
      );
      expect(find.text(Fa.monthTruncated), findsOneWidget);
    });
  });
}

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

bool dueOnDay(DateTime instant, int y, int m, int d) {
  final j = TehranTime.jalali(instant.toUtc());
  return j.year == y && j.month == m && j.day == d;
}
