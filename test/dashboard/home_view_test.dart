import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jibhr/core/localization/fa.dart';
import 'package:jibhr/core/theme/app_theme.dart';
import 'package:jibhr/features/attendance/attendance_calendar.dart';
import 'package:jibhr/features/attendance/attendance_repository.dart';
import 'package:jibhr/features/attendance/attendance_review.dart';
import 'package:jibhr/features/dashboard/dashboard_page.dart';
import 'package:jibhr/features/dashboard/widgets/home_parts.dart';
import 'package:jibhr/features/session/workspace_session.dart';
import 'package:jibhr/features/work/work_repository.dart';

import 'dashboard_rules_test.dart' show task;

final _now = DateTime.utc(2026, 11, 8, 8, 30);

const _employee = WorkspaceSession(
  profileId: 'e',
  firstName: 'سارا',
  lastName: 'احمدی',
  status: 'active',
  mustChangePassword: false,
  permissions: {'attendance.view.self', 'attendance.clock', 'attendance.correct.self', 'leave.request', 'leave.view.self', 'tasks.create.personal', 'reports.view.self'},
  teamName: 'تیم پشتیبانی',
);

const _manager = WorkspaceSession(
  profileId: 'm',
  firstName: 'مدیر',
  lastName: 'تیم',
  status: 'active',
  mustChangePassword: false,
  permissions: {'attendance.view.self', 'attendance.view.team', 'attendance.approve.team', 'leave.approve.team', 'tasks.create.project', 'projects.create'},
);

Map<String, dynamic> _personal() => {
      'open': false, 'incomplete': 1, 'approved_seconds': 3600, 'pending_seconds': 0, 'recorded_seconds': 3600,
      'rejected_seconds': 0, 'week_approved_seconds': 7200, 'month_approved_seconds': 10800, 'personal_tasks': 2,
      'project_tasks': 1, 'awaiting_review': 0, 'needs_revision': 0, 'leave_pending': 0, 'unread': 3, 'statuses': const [],
    };

Map<String, dynamic> _managerSummary() => {
      'personal': _personal(),
      'team': {
        'employees': 2, 'open_intervals': 1, 'pending_reports': 1, 'pending_corrections': 0, 'pending_leave': 2,
        'pending_disputes': 0, 'active_tasks': 3, 'review_tasks': 1, 'overdue_tasks': 1, 'complete_tasks': 1, 'people': const [],
      },
      'projects': {'active': 1, 'archived': 0, 'tasks': 3, 'awaiting_review': 0, 'overdue': 0, 'complete': 1, 'active_sprints': 1, 'upcoming_milestones': 0, 'reached_milestones': 0},
      'queues': {'attendance': 3, 'corrections': 0, 'leave': 2, 'disputes': 0, 'task_reviews': 0},
    };

const _zero = DurationTotals(recorded: 0, pending: 0, approved: 0, revision: 0, rejected: 0);

AttendanceBoard _board({bool open = false}) => AttendanceBoard(
      isOpen: open,
      today: const DurationTotals(recorded: 5400, pending: 1800, approved: 3600, revision: 0, rejected: 0),
      week: _zero,
      month: _zero,
      provisional: open ? [(start: DateTime.utc(2026, 11, 8, 4, 42), end: _now)] : const [],
    );

/// [summary] is split into the four sections the way the server wrapper
/// builds them; a section can be overridden to fail or load on its own.
Widget _app(
  WorkspaceSession session, {
  required SectionData<Map<String, dynamic>> summary,
  SectionData<AttendanceBoard>? attendance,
  SectionData<List<TaskRow>>? tasks,
  Brightness brightness = Brightness.light,
  ValueChanged<bool>? onPunch,
  ValueChanged<String>? onNavigate,
  SectionData<Map<String, dynamic>>? personal,
  SectionData<Map<String, dynamic>>? queues,
  SectionData<Map<String, dynamic>>? team,
}) {
  SectionData<Map<String, dynamic>> part(String key) => SectionData(
        value: asMap(summary.value?[key]),
        loading: summary.loading,
        error: summary.error,
        stale: summary.stale,
      );
  return MaterialApp(
    theme: buildAppTheme(brightness),
    locale: const Locale('fa', 'IR'),
    supportedLocales: const [Locale('fa', 'IR')],
    localizationsDelegates: const [GlobalMaterialLocalizations.delegate, GlobalWidgetsLocalizations.delegate, GlobalCupertinoLocalizations.delegate],
    builder: (context, child) => Directionality(textDirection: TextDirection.rtl, child: child!),
    home: Scaffold(
      body: HomeView(
        session: session,
        now: _now,
        personal: personal ?? part('personal'),
        queues: queues ?? part('queues'),
        team: team ?? (asMap(summary.value?['team']) != null ? part('team') : null),
        projectsSummary: asMap(summary.value?['projects']) != null ? part('projects') : null,
        attendance: attendance,
        tasks: tasks,
        projects: const SectionData(value: []),
        punching: false,
        onPunch: onPunch ?? (_) {},
        onNavigate: onNavigate ?? (_) {},
        onRefresh: () {},
        onRetryPersonal: () {},
        onRetryQueues: () {},
        onRetryTeam: () {},
        onRetryProjectsSummary: () {},
        onRetryAttendance: () {},
        onRetryTasks: () {},
        onRetryProjects: () {},
      ),
    ),
  );
}

Future<void> _size(WidgetTester tester, double width, [double height = 2600]) async {
  await tester.binding.setSurfaceSize(Size(width, height));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

void main() {
  testWidgets('employee: no team, no projects, no empty queue; stale is a warning', (tester) async {
    await _size(tester, 1400);
    await tester.pumpWidget(_app(
      _employee,
      summary: SectionData(value: {
        'personal': _personal(),
        'team': null,
        'projects': null,
        'queues': {'attendance': 0, 'corrections': 0, 'leave': 0, 'disputes': 0, 'task_reviews': 0},
      }, stale: true),
      attendance: SectionData(value: _board()),
      tasks: SectionData(value: [task('a', due: DateTime.utc(2026, 11, 9))]),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('سارا'), findsWidgets);
    expect(find.text(Fa.staleDashboard), findsWidgets);
    expect(find.byKey(const Key('home-team')), findsNothing);
    expect(find.byKey(const Key('home-projects')), findsNothing);
    expect(find.text(Fa.homeDecide), findsNothing);
    // Personal follow-ups still show: one incomplete interval, three unread.
    expect(find.byKey(const ValueKey('action-incomplete')), findsOneWidget);
    expect(find.byKey(const ValueKey('action-unread')), findsOneWidget);
    expect(find.text('عملکرد بالا'), findsNothing);
  });

  testWidgets('manager: team without a score, queue first, no export without permission', (tester) async {
    await _size(tester, 1400);
    await tester.pumpWidget(_app(_manager, summary: SectionData(value: _managerSummary()), attendance: SectionData(value: _board())));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-team')), findsOneWidget);
    expect(find.byKey(const Key('home-projects')), findsOneWidget);
    expect(find.textContaining(Fa.noRanking), findsOneWidget);
    expect(find.text(Fa.homeDecide), findsOneWidget);
    expect(find.byKey(const ValueKey('quick-export')), findsNothing);
    expect(find.text('۲۵٪'), findsOneWidget);
  });

  testWidgets('clock action follows the open interval and the permission', (tester) async {
    await _size(tester, 1400);
    bool? asked;
    await tester.pumpWidget(_app(_employee, summary: SectionData(value: _managerSummary()), attendance: SectionData(value: _board(open: true)), onPunch: (v) => asked = v));
    await tester.pumpAndSettle();
    expect(find.text(Fa.homeClockOutAction), findsOneWidget);
    expect(find.textContaining('${Fa.homeOpenSince} ۰۸:۱۲'), findsOneWidget);
    await tester.tap(find.byKey(const Key('home-punch')));
    expect(asked, isTrue);

    const noClock = WorkspaceSession(profileId: 'x', firstName: 'x', lastName: 'y', status: 'active', mustChangePassword: false, permissions: {'attendance.view.self'});
    await tester.pumpWidget(_app(noClock, summary: SectionData(value: _managerSummary()), attendance: SectionData(value: _board())));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-punch')), findsNothing);
  });

  testWidgets('a failed summary keeps attendance and tasks working, with errors in place', (tester) async {
    await _size(tester, 1400);
    await tester.pumpWidget(_app(
      _employee,
      summary: SectionData(error: Exception('timeout')),
      attendance: SectionData(value: _board()),
      tasks: SectionData(value: [task('a', due: DateTime.utc(2026, 11, 9))]),
    ));
    await tester.pumpAndSettle();
    expect(find.text(Fa.retry), findsNWidgets(2)); // actions and my figures, each in its own card
    expect(find.text(Fa.homeClockInAction), findsOneWidget);
    expect(find.byKey(const ValueKey('agenda-a')), findsOneWidget);
  });

  testWidgets('queues fail, personal works: personal items stay, error in place, never "all clear"', (tester) async {
    await _size(tester, 1400);
    await tester.pumpWidget(_app(
      _manager,
      summary: SectionData(value: _managerSummary()),
      queues: SectionData(error: Exception('timeout')),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('action-incomplete')), findsOneWidget); // from personal
    expect(find.byKey(const ValueKey('action-attendance')), findsNothing); // from the failed queues
    expect(find.byKey(const Key('actions-partial-error')), findsOneWidget);
    expect(find.text(Fa.homeAllClear), findsNothing);
    expect(find.byKey(const Key('home-team')), findsOneWidget);
  });

  testWidgets('queues fail and personal has nothing: still no "all clear"', (tester) async {
    await _size(tester, 1400);
    final quiet = Map<String, dynamic>.from(_personal())..addAll({'incomplete': 0, 'unread': 0});
    await tester.pumpWidget(_app(
      _manager,
      summary: SectionData(value: _managerSummary()),
      personal: SectionData(value: quiet),
      queues: SectionData(error: Exception('timeout')),
    ));
    await tester.pumpAndSettle();
    expect(find.text(Fa.homeAllClear), findsNothing);
    expect(find.byKey(const Key('actions-partial-error')), findsOneWidget);
  });

  testWidgets('team fails alone: other sections keep their data', (tester) async {
    await _size(tester, 1400);
    await tester.pumpWidget(_app(
      _manager,
      summary: SectionData(value: _managerSummary()),
      team: SectionData(error: Exception('timeout')),
      attendance: SectionData(value: _board()),
    ));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byKey(const Key('home-team')), matching: find.text(Fa.retry)), findsOneWidget);
    expect(find.byKey(const ValueKey('action-attendance')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('home-mine')), matching: find.text(Fa.retry)), findsNothing);
  });

  testWidgets('loading shows skeletons, not a page spinner', (tester) async {
    await _size(tester, 1400);
    await tester.pumpWidget(_app(_employee, summary: const SectionData(loading: true), attendance: const SectionData(loading: true), tasks: const SectionData(loading: true)));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byKey(const Key('home-attendance')), findsOneWidget);
  });

  testWidgets('tapping a task opens it', (tester) async {
    await _size(tester, 1400);
    String? went;
    await tester.pumpWidget(_app(_employee, summary: SectionData(value: _managerSummary()), tasks: SectionData(value: [task('t1', due: DateTime.utc(2026, 11, 9))]), onNavigate: (p) => went = p));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('agenda-t1')));
    expect(went, '/work/t/t1');
  });

  for (final brightness in Brightness.values) {
    for (final width in [390.0, 768.0, 1080.0, 1440.0]) {
      testWidgets('${width.toInt()} ${brightness.name}: manager home lays out without overflow', (tester) async {
        await _size(tester, width, 3200);
        await tester.pumpWidget(_app(
          _manager,
          brightness: brightness,
          summary: SectionData(value: _managerSummary()),
          attendance: SectionData(value: _board(open: true)),
          tasks: SectionData(value: [
            task('late', due: DateTime.utc(2026, 11, 5)),
            task('long', due: DateTime.utc(2026, 11, 12)),
          ]),
        ));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('home-attendance')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
