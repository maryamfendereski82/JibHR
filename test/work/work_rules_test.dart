import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jibhr/core/calendar/tehran_time.dart';
import 'package:jibhr/core/localization/fa.dart';
import 'package:jibhr/features/work/sprint_pages.dart';
import 'package:jibhr/features/work/task_board.dart';
import 'package:jibhr/features/work/work_repository.dart';
import 'package:jibhr/features/work/work_rules.dart';
import 'package:shamsi_date/shamsi_date.dart';

void main() {
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
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: PlanProgressBar(label: Fa.currentProgress, complete: 1, total: 2))));
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

    await tester.pumpWidget(MaterialApp(home: Scaffold(body: TaskTile(task: task, onTap: () {}))));

    expect(find.text('پیاده‌سازی'), findsOneWidget);
    expect(find.textContaining(Fa.priorityCritical), findsOneWidget);
    expect(find.textContaining('کارمند یک'), findsOneWidget);
    expect(find.textContaining('همکار'), findsOneWidget);
    expect(find.textContaining('باگ'), findsOneWidget);
    expect(find.textContaining(Fa.pending), findsOneWidget);
    expect(find.textContaining('در حال انجام'), findsOneWidget);
  });
}
