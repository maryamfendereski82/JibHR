import 'package:flutter_test/flutter_test.dart';
import 'package:jibhr/core/localization/fa.dart';
import 'package:jibhr/features/dashboard/dashboard_rules.dart';
import 'package:jibhr/features/session/workspace_session.dart';
import 'package:jibhr/features/work/work_repository.dart';

// 2026-11-08 08:30 UTC is 12:00 in Tehran, Saturday 17 Aban 1405.
final _now = DateTime.utc(2026, 11, 8, 8, 30);

TaskRow task(String id, {DateTime? due, String category = 'in_progress', bool approval = false, String state = 'not_required'}) => TaskRow(
      id: id,
      title: 'تسک $id',
      description: '',
      priority: 'medium',
      approvalRequired: approval,
      approvalState: state,
      requiredSubtask: false,
      assigneeName: 'سارا',
      statusId: 's',
      statusName: 'در حال انجام',
      statusKey: 'doing',
      statusCategory: category,
      collaborators: const [],
      labels: const [],
      createdAt: _now,
      updatedAt: _now,
      dueAt: due,
    );

void main() {
  group('greeting follows the Tehran clock', () {
    test('morning, noon, afternoon, night', () {
      expect(greetingFor(DateTime.utc(2026, 11, 8, 4, 0)), Fa.greetMorning); // 07:30
      expect(greetingFor(DateTime.utc(2026, 11, 8, 9, 0)), Fa.greetNoon); // 12:30
      expect(greetingFor(DateTime.utc(2026, 11, 8, 13, 0)), Fa.greetAfternoon); // 16:30
      expect(greetingFor(DateTime.utc(2026, 11, 8, 18, 0)), Fa.greetNight); // 21:30
    });
  });

  group('relative due dates', () {
    test('near days are words, others count, far ones are dates', () {
      expect(relativeDue(DateTime.utc(2026, 11, 8, 15), _now), Fa.agendaToday);
      expect(relativeDue(DateTime.utc(2026, 11, 9, 10), _now), Fa.dueTomorrow);
      expect(relativeDue(DateTime.utc(2026, 11, 7, 10), _now), Fa.dueYesterday);
      expect(relativeDue(DateTime.utc(2026, 11, 11, 10), _now), '۳ ${Fa.daysLeft}');
      expect(relativeDue(DateTime.utc(2026, 11, 6, 10), _now), '۲ ${Fa.daysPast}');
      expect(relativeDue(DateTime.utc(2027, 3, 1, 10), _now), contains('۱۴۰۵'));
    });

    test('days are counted on the Tehran calendar, not UTC', () {
      // 21:00 UTC on 8 Nov is 00:30 on 9 Nov in Tehran: tomorrow.
      expect(relativeDue(DateTime.utc(2026, 11, 8, 21), _now), Fa.dueTomorrow);
    });
  });

  group('open tasks', () {
    test('completed tasks never reach the agenda', () {
      final rows = [
        task('a', category: 'done'),
        task('b', category: 'approved'),
        task('c', category: 'done', approval: true, state: 'pending'),
        task('d'),
      ];
      expect(openTasks(rows).map((t) => t.id), ['c', 'd']);
    });

    test('grouping keeps server order and skips empty groups', () {
      final rows = [
        task('late', due: DateTime.utc(2026, 11, 5)),
        task('today', due: DateTime.utc(2026, 11, 8, 12)),
        task('soon', due: DateTime.utc(2026, 11, 12)),
        task('none'),
      ];
      final groups = groupAgenda(rows, _now);
      expect(groups.map((g) => g.$1), [AgendaGroup.overdue, AgendaGroup.today, AgendaGroup.week, AgendaGroup.undated]);
    });
  });

  group('home actions', () {
    test('zero counts are left out and decisions come first', () {
      final items = homeActions({
        'queues': {'attendance': 2, 'corrections': 0, 'leave': 5, 'disputes': 0, 'task_reviews': 0},
        'personal': {'needs_revision': 1, 'incomplete': 0, 'awaiting_review': 0, 'leave_pending': 1, 'unread': 0},
      });
      expect(items.map((a) => a.id), ['leave', 'attendance', 'needs_revision', 'leave_pending']);
      expect(items.first.kind, ActionKind.decide);
      expect(items.last.kind, ActionKind.waiting);
    });

    test('an empty summary gives nothing', () {
      expect(homeActions(const {}), isEmpty);
    });
  });

  test('team completion uses only server counts', () {
    expect(teamCompletion({'active_tasks': 3, 'complete_tasks': 1}), 0.25);
    expect(teamCompletion({'active_tasks': 0, 'complete_tasks': 0}), isNull);
  });

  test('a team or projects section may exist only with the permissions the functions check', () {
    WorkspaceSession s(Set<String> p) => WorkspaceSession(profileId: 'p', firstName: 'a', lastName: 'b', status: 'active', mustChangePassword: false, permissions: p);
    expect(mayHaveTeamSection(s({})), isFalse);
    expect(mayHaveTeamSection(s({'attendance.view.self', 'leave.request'})), isFalse);
    for (final key in ['employees.view.team', 'employees.view.all', 'attendance.view.team', 'attendance.view.all']) {
      expect(mayHaveTeamSection(s({key})), isTrue, reason: key);
    }
    expect(mayHaveProjectsSection(s({'tasks.create.personal'})), isFalse);
    expect(mayHaveProjectsSection(s({'projects.create'})), isTrue);
  });

  test('shortcuts follow permissions', () {
    WorkspaceSession s(Set<String> p) => WorkspaceSession(profileId: 'p', firstName: 'a', lastName: 'b', status: 'active', mustChangePassword: false, permissions: p);
    expect(quickActions(s({})).map((a) => a.id), ['reports']);
    expect(quickActions(s({'tasks.create.personal', 'leave.request', 'attendance.correct.self', 'reports.export.all'})).map((a) => a.id),
        ['task', 'leave', 'correction', 'reports', 'export']);
  });
}
