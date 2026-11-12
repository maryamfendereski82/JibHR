import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jibhr/core/calendar/tehran_time.dart';
import 'package:jibhr/core/localization/fa.dart';
import 'package:jibhr/features/work/sprint_pages.dart';
import 'package:jibhr/core/theme/app_theme.dart';
import 'package:jibhr/features/work/widgets/task_card.dart';
import 'package:jibhr/features/work/work_repository.dart';
import 'package:jibhr/features/work/work_rules.dart';
import 'package:shamsi_date/shamsi_date.dart';

typedef _Row = ({String id, DateTime? due});

List<String> _merge(List<_Row> a, List<_Row> b, int limit) => mergeOrdered<_Row>(a, b, limit, id: (r) => r.id, due: (r) => r.due).map((r) => r.id).toList();

void main() {
  group('open task merge', () {
    DateTime d(int day) => DateTime.utc(2026, 11, day);
    test('interleaves by due date, undated last, and stops at the limit', () {
      final a = <_Row>[(id: 'a1', due: d(2)), (id: 'a2', due: d(5)), (id: 'a3', due: null)];
      final b = <_Row>[(id: 'b1', due: d(1)), (id: 'b2', due: d(9))];
      expect(_merge(a, b, 10), ['b1', 'a1', 'a2', 'b2', 'a3']);
      expect(_merge(a, b, 3), ['b1', 'a1', 'a2']);
    });

    test('equal dates fall back to id, as the server orders them', () {
      final a = <_Row>[(id: 'b', due: d(3))];
      final b = <_Row>[(id: 'a', due: d(3))];
      expect(_merge(a, b, 5), ['a', 'b']);
    });

    test('a row in both lists is kept once', () {
      final a = <_Row>[(id: 'x', due: d(3))];
      final b = <_Row>[(id: 'x', due: d(3)), (id: 'y', due: d(4))];
      expect(_merge(a, b, 5), ['x', 'y']);
    });

    test('empty inputs', () {
      expect(_merge(const [], const [], 5), isEmpty);
    });
  });

  test('checklist percent, pages, and rejected tasks stay closed for employees', () {
    expect(checklistPercent(0, 0), 0);
    expect(checklistPercent(1, 2), 50);
    expect(pageRange(0, 30), (start: 0, end: 29));
    expect(pageRange(2, 30), (start: 60, end: 89));
    expect(employeeCanReopenRejected(canManage: false, canViewAll: false), isFalse);
    expect(employeeCanReopenRejected(canManage: true, canViewAll: false), isTrue);
    expect(subtaskNestingAllowed(parentAlreadyHasParent: true), isFalse);
    expect(subtaskNestingAllowed(parentAlreadyHasParent: false), isTrue);
  });

  test('a due instant lands on its tehran jalali day', () {
    final due = TehranTime.toUtcFromJalali(1405, 1, 3, 9, 0);
    expect(dueOnJalaliDay(due, 1405, 1, 3), isTrue);
    expect(dueOnJalaliDay(due, 1405, 1, 4), isFalse);
    expect(dueOnJalaliDay(null, 1405, 1, 3), isFalse);
    final month = Jalali(1405, 1, 1);
    expect(month.weekDay, 1);
  });

  test('sprint and milestone progress counts approved work only', () {
    expect(progressPercent(0, 0), 0);
    expect(progressPercent(1, 2), 50);
    expect(progressPercent(1, 3), 33);
    expect(planPending(3, 1, 1), 1);
    expect(planPending(0, 0, 0), 0);
    expect(taskCountsComplete(category: 'done', approvalRequired: true, approvalState: 'pending'), isFalse);
    expect(taskCountsComplete(category: 'done', approvalRequired: false, approvalState: 'not_required'), isTrue);
    expect(taskCountsComplete(category: 'approved', approvalRequired: true, approvalState: 'approved'), isTrue);
    expect(taskCountsComplete(category: 'in_progress', approvalRequired: false, approvalState: 'not_required'), isFalse);
    expect(taskCountsComplete(category: 'done', approvalRequired: false, approvalState: 'not_required', archived: true), isFalse);
    expect(sprintRangeValid('2026-04-02', '2026-04-01'), isFalse);
    expect(sprintRangeValid('2026-04-01', '2026-04-01'), isTrue);
    expect(canManagePlan(manageTasks: true, editProject: true, viewAll: false, projectManager: false), isFalse);
    expect(canManagePlan(manageTasks: true, editProject: true, viewAll: false, projectManager: true), isTrue);
    expect(canManagePlan(manageTasks: false, editProject: true, viewAll: true, projectManager: true), isFalse);
    expect(formatPlanDate('2026-03-21'), TehranTime.formatDate(DateTime.utc(2026, 3, 21, 12)));
    expect(sprintStatusLabel('closed'), Fa.sprintClosed);
    expect(milestoneStatusLabel('upcoming'), Fa.upcoming);
  });

  testWidgets('plan progress shows percent', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: PlanProgressBar(label: Fa.currentProgress, complete: 1, total: 2)),
      ),
    );
    expect(find.textContaining(Fa.currentProgress), findsOneWidget);
    expect(find.textContaining('۵۰'), findsOneWidget);
  });

  testWidgets('task card shows priority, assignee and approval', (tester) async {
    final task = TaskRow(
      id: 't',
      title: 'پیاده‌سازی',
      description: '',
      priority: 'critical',
      approvalRequired: true,
      approvalState: 'pending',
      requiredSubtask: false,
      assigneeName: 'کارمند یک',
      statusId: 's',
      statusName: 'در حال انجام',
      statusKey: 'in_progress',
      statusCategory: 'in_progress',
      collaborators: const [NamedPerson(id: 'c', name: 'همکار')],
      labels: const [NamedPerson(id: 'l', name: 'باگ')],
      createdAt: DateTime.utc(2026, 3, 21),
      updatedAt: DateTime.utc(2026, 3, 21),
      dueAt: TehranTime.toUtcFromJalali(1405, 1, 3, 9, 0),
    );

    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: Scaffold(
          body: SizedBox(
            width: 300,
            child: TaskCard(task: task, now: DateTime.utc(2026, 3, 20), showStatus: true, onOpen: () {}),
          ),
        ),
      ),
    );

    expect(find.text('پیاده‌سازی'), findsOneWidget);
    expect(find.textContaining(Fa.priorityCritical), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('کارمند یک')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(Fa.collaboratorsCount)), findsOneWidget);
    // Labels are secondary: shown in the list view and the details, not on the card.
    expect(find.textContaining('باگ'), findsNothing);
    // Approval required but not yet sent: the policy, not a queue state.
    expect(find.textContaining(Fa.needsApprovalBadge), findsOneWidget);
    // «در حال انجام» is one of the five final statuses.
    expect(find.textContaining(Fa.groupInProgress), findsOneWidget);
    semantics.dispose();
  });
}
