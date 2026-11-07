import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jibhr/core/calendar/tehran_time.dart';
import 'package:jibhr/core/localization/fa.dart';
import 'package:jibhr/core/theme/app_theme.dart';
import 'package:jibhr/features/attendance/attendance_calendar.dart';
import 'package:jibhr/features/attendance/attendance_calendar_view.dart';
import 'package:jibhr/features/attendance/attendance_group_view.dart';
import 'package:jibhr/features/attendance/attendance_providers.dart';
import 'package:shamsi_date/shamsi_date.dart';

CalendarSlice _slice({
  required String id,
  required String date,
  required DateTime start,
  DateTime? end,
  String status = 'closed',
  String mode = 'report',
  String? decision,
  bool superseded = false,
  bool provisional = false,
  String profileId = 'p',
}) {
  return CalendarSlice(
    intervalId: id,
    profileId: profileId,
    tehranDate: date,
    startedAt: start,
    endedAt: end,
    intervalStatus: status,
    approvalMode: mode,
    decision: decision,
    superseded: superseded,
    provisional: provisional,
  );
}

void main() {
  test('Jalali month keeps Saturday in the first column and Friday in the last', () {
    expect(shiftJalaliMonth(Jalali(1405, 1, 1), -1), Jalali(1404, 12, 1));
    expect(shiftJalaliMonth(Jalali(1404, 12, 1), 1), Jalali(1405, 1, 1));
    final month = Jalali(1405, 8, 1);
    final cells = monthCells(month);
    expect(cells.length % 7, 0);
    expect(cells.whereType<Jalali>().length, month.monthLength);
    final first = cells.indexWhere((cell) => cell != null);
    expect(first, cells[first]!.weekDay - 1);
    expect(cells[first]!.weekDay, isNot(0));
    final friday = cells[first + (7 - cells[first]!.weekDay)];
    expect(friday!.weekDay, 7);
  });

  test('cross-midnight stays on the two Tehran dates and is not one range', () {
    final start = TehranTime.toUtcFromJalali(1405, 8, 15, 23, 30);
    final midnight = TehranTime.toUtcFromJalali(1405, 8, 16, 0, 0);
    final end = TehranTime.toUtcFromJalali(1405, 8, 16, 1, 30);
    final slices = [
      _slice(id: 'night', date: TehranTime.jalaliDayIso(1405, 8, 15), start: start, end: midnight, decision: 'approved'),
      _slice(id: 'night', date: TehranTime.jalaliDayIso(1405, 8, 16), start: midnight, end: end, decision: 'approved'),
    ];
    final days = buildMonth(Jalali(1405, 8, 1), slices);
    final first = days.firstWhere((day) => day.day.day == 15);
    final second = days.firstWhere((day) => day.day.day == 16);
    expect(first.slices, hasLength(1));
    expect(second.slices, hasLength(1));
    expect(first.slices.single.dailyCut, isTrue);
    expect(second.slices.single.dailyCut, isTrue);
    expect(first.tone, DayTone.approved);
    expect(second.tone, DayTone.approved);
  });

  test('a normal interval is not marked as a daily cut', () {
    final start = TehranTime.toUtcFromJalali(1405, 8, 2, 9, 0);
    final slice = _slice(id: 'a', date: TehranTime.jalaliDayIso(1405, 8, 2), start: start, end: start.add(const Duration(hours: 1)));
    expect(slice.dailyCut, isFalse);
  });

  test('a day keeps every visible interval and takes approved time only from the backend', () {
    final date = TehranTime.jalaliDayIso(1405, 8, 2);
    final morning = TehranTime.toUtcFromJalali(1405, 8, 2, 8, 0);
    final slices = [
      _slice(id: 'a', date: date, start: morning, end: morning.add(const Duration(hours: 2)), decision: 'approved'),
      _slice(id: 'b', date: date, start: morning.add(const Duration(hours: 3)), end: morning.add(const Duration(hours: 4)), decision: 'rejected'),
      _slice(id: 'c', date: date, start: morning, end: morning.add(const Duration(hours: 5)), decision: 'approved', superseded: true),
      _slice(id: 'd', date: date, start: morning, end: morning.add(const Duration(hours: 1)), status: 'void', decision: 'approved'),
      _slice(id: 'e', date: date, start: morning, end: morning.add(const Duration(minutes: 30)), mode: 'correction'),
      _slice(id: 'f', date: date, start: morning, end: morning.add(const Duration(minutes: 15)), decision: 'needs_revision'),
      _slice(id: 'g', date: date, start: morning, end: morning.add(const Duration(minutes: 10))),
    ];
    final month = Jalali(1405, 8, 1);
    final day = buildMonth(month, slices).firstWhere((item) => item.day.day == 2);
    expect(day.slices.map((slice) => slice.intervalId).toSet(), {'a', 'b', 'e', 'f', 'g'});
    expect(day.tone, DayTone.partial);
    // No backend figure means no figure. The slices are never summed instead.
    expect(day.approvedSeconds, 0);
    final fed = buildMonth(month, slices, approved: {date: 4242}).firstWhere((item) => item.day.day == 2);
    expect(fed.approvedSeconds, 4242);
  });

  test('incomplete and rejected days keep their own tone', () {
    final date = TehranTime.jalaliDayIso(1405, 8, 3);
    final start = TehranTime.toUtcFromJalali(1405, 8, 3, 9, 0);
    final incomplete = buildMonth(Jalali(1405, 8, 1), [
      _slice(id: 'stuck', date: date, start: start, status: 'incomplete'),
    ]).firstWhere((day) => day.day.day == 3);
    expect(incomplete.tone, DayTone.incomplete);

    final rejected = buildMonth(Jalali(1405, 8, 1), [
      _slice(id: 'no', date: date, start: start, end: start.add(const Duration(hours: 1)), decision: 'rejected'),
    ]).firstWhere((day) => day.day.day == 3);
    expect(rejected.tone, DayTone.rejected);
    expect(sliceLabel(rejected.slices.single), Fa.rejected);
  });

  test('an open slice is labeled open and has no clock-out', () {
    final start = TehranTime.toUtcFromJalali(1405, 8, 3, 9, 0);
    final open = _slice(id: 'o', date: TehranTime.jalaliDayIso(1405, 8, 3), start: start, status: 'open');
    expect(sliceLabel(open), Fa.openInterval);
    expect(sliceRange(open), contains('باز'));
  });

  test('team and employee filters narrow the group calendar', () {
    final people = [
      const PersonAttendance(id: '1', name: 'الف', teamId: 't1', totals: AttendanceCalendarModel.emptyTotals, days: []),
      const PersonAttendance(id: '2', name: 'ب', teamId: 't2', totals: AttendanceCalendarModel.emptyTotals, days: []),
    ];
    expect(filterPeople(people, teamId: 't1').map((person) => person.id), ['1']);
    expect(filterPeople(people, employeeId: '2').map((person) => person.id), ['2']);
    expect(filterPeople(people, teamId: 't1', employeeId: '2'), isEmpty);
  });

  test('a person tone comes from backend totals', () {
    DurationTotals totals({int approved = 0, int pending = 0, int revision = 0, int rejected = 0}) => DurationTotals(
          recorded: approved + pending + revision + rejected,
          pending: pending,
          approved: approved,
          revision: revision,
          rejected: rejected,
        );
    expect(personTone(totals()), DayTone.empty);
    expect(personTone(totals(approved: 60)), DayTone.approved);
    expect(personTone(totals(pending: 60)), DayTone.pending);
    expect(personTone(totals(rejected: 60)), DayTone.rejected);
    expect(personTone(totals(revision: 60)), DayTone.revision);
    expect(personTone(totals(approved: 60, rejected: 60)), DayTone.partial);
  });

  test('week range runs Saturday to Friday and shifts a whole week', () {
    final week = AttendanceRange.week(Jalali(1405, 8, 16));
    expect(week.from.weekDay, 1);
    expect(week.to.weekDay, 7);
    expect(week.days, hasLength(7));
    expect(week.contains(Jalali(1405, 8, 16)), isTrue);
    final back = week.shift(-1);
    expect(back.to.addDays(1), week.from);
    expect(back.kind, RangeKind.week);
  });

  test('month range follows the Jalali month, across a year change', () {
    final month = AttendanceRange.month(Jalali(1405, 8, 16));
    expect(month.days, hasLength(30));
    final next = AttendanceRange.month(Jalali(1404, 12, 5)).shift(1);
    expect(next.from, Jalali(1405, 1, 1));
    expect(next.days, hasLength(31));
  });

  test('custom range rejects a reversed or over-long span and crosses a month', () {
    expect(AttendanceRange.custom(Jalali(1405, 8, 10), Jalali(1405, 8, 9)), isNull);
    expect(AttendanceRange.custom(Jalali(1405, 7, 1), Jalali(1405, 8, 30)), isNull);
    final span = AttendanceRange.custom(Jalali(1405, 7, 28), Jalali(1405, 8, 3))!;
    expect(span.days, hasLength(6));
    expect(span.days.first, Jalali(1405, 7, 28));
    expect(span.days.last, Jalali(1405, 8, 3));
    expect(span.shift(1).from, Jalali(1405, 8, 4));
  });

  testWidgets('desktop shows the day detail beside the calendar', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final day = _sample().firstWhere((item) => item.day.day == 2);
    await tester.pumpWidget(_harness(days: _sample()));
    expect(find.byKey(const Key('attendance-layout-wide')), findsOneWidget);
    expect(find.text(Fa.selectDay), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('day-2')));
    await tester.tap(find.byKey(const ValueKey('day-2')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('attendance-detail')), findsOneWidget);
    expect(find.textContaining(TehranTime.formatTime(day.slices.first.startedAt!)), findsWidgets);
    expect(find.textContaining(TehranTime.formatTime(day.slices.last.startedAt!)), findsWidgets);
  });

  testWidgets('a day cell shows first in, last out and the backend approved time', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final days = _sample(approved: 7200);
    final day = days.firstWhere((item) => item.day.day == 2);
    await tester.pumpWidget(_harness(days: days));
    final cell = find.byKey(const ValueKey('day-2'));
    expect(find.descendant(of: cell, matching: find.text('${Fa.clockIn} ${TehranTime.formatTime(day.slices.first.startedAt!)}')), findsOneWidget);
    expect(find.descendant(of: cell, matching: find.text('${Fa.clockOut} ${TehranTime.formatTime(day.slices.last.endedAt!)}')), findsOneWidget);
    expect(find.descendant(of: cell, matching: find.text('تأیید ${formatHours(7200)}')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the day detail prints what attendance_totals returned, not a sum of slices', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_harness(days: _sample()));
    await tester.ensureVisible(find.byKey(const ValueKey('day-2')));
    await tester.tap(find.byKey(const ValueKey('day-2')));
    await tester.pumpAndSettle();
    final detail = find.byKey(const Key('attendance-detail'));
    // The sample slices would sum to 03:00. The stub backend says otherwise.
    expect(find.descendant(of: detail, matching: find.text(formatHours(_stubTotals.approved))), findsOneWidget);
    expect(find.descendant(of: detail, matching: find.text(formatHours(_stubTotals.recorded))), findsOneWidget);
    expect(find.descendant(of: detail, matching: find.text(formatHours(3 * 3600))), findsNothing);
  });

  testWidgets('tablet keeps the detail under the calendar', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_harness(days: _sample()));
    expect(find.byKey(const Key('attendance-layout-medium')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('day-2')));
    await tester.tap(find.byKey(const ValueKey('day-2')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('attendance-detail')), findsOneWidget);
  });

  testWidgets('phone opens the day on a sheet and keeps both intervals', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_harness(days: _sample()));
    expect(find.byKey(const Key('attendance-layout-compact')), findsOneWidget);
    expect(find.byKey(const Key('attendance-detail')), findsNothing);
    await tester.ensureVisible(find.byKey(const ValueKey('day-2')));
    await tester.tap(find.byKey(const ValueKey('day-2')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('attendance-detail')), findsOneWidget);
    expect(find.text(Fa.approved), findsWidgets);
    expect(find.text(Fa.pending), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('status is a word in both themes', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final approved = TehranTime.jalaliDayIso(1405, 8, 2);
    final pending = TehranTime.jalaliDayIso(1405, 8, 3);
    final start = TehranTime.toUtcFromJalali(1405, 8, 2, 9, 0);
    final later = TehranTime.toUtcFromJalali(1405, 8, 3, 9, 0);
    final days = buildMonth(Jalali(1405, 8, 1), [
      _slice(id: 'a', date: approved, start: start, end: start.add(const Duration(hours: 1)), decision: 'approved'),
      _slice(id: 'b', date: pending, start: later, end: later.add(const Duration(hours: 1))),
    ]);
    for (final brightness in [Brightness.light, Brightness.dark]) {
      await tester.pumpWidget(_harness(days: days, brightness: brightness));
      expect(find.text('تأیید'), findsWidgets);
      expect(find.text('انتظار'), findsWidgets);
    }
  });

  testWidgets('wide group shows people side by side with every day and opens a day', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_groupHarness());
    expect(find.byKey(const Key('attendance-matrix')), findsOneWidget);
    expect(find.byKey(const ValueKey('person-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('person-2')), findsOneWidget);
    final iso = TehranTime.jalaliDayIso(1405, 8, 10);
    final cell = find.byKey(ValueKey('cell-1-$iso'));
    expect(cell, findsOneWidget);
    expect(find.byKey(ValueKey('cell-2-$iso')), findsOneWidget);
    expect(find.text(formatHours(5400)), findsOneWidget);
    await tester.ensureVisible(cell);
    await tester.tap(cell);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('attendance-detail')), findsOneWidget);
    expect(find.text('آرش تست'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone group lists people on one day instead of a shrunken matrix', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_groupHarness());
    expect(find.byKey(const Key('attendance-matrix')), findsNothing);
    expect(find.byKey(const Key('attendance-phone-day')), findsOneWidget);
    expect(find.byKey(const ValueKey('person-day-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('person-day-2')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the group view opens a person calendar from the name', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    String? opened;
    await tester.pumpWidget(_groupHarness(onPerson: (id) => opened = id));
    await tester.tap(find.byKey(const ValueKey('person-2')));
    expect(opened, '2');
  });
}

const _stubTotals = DurationTotals(recorded: 1234, pending: 660, approved: 3660, revision: 0, rejected: 0);

List<DayAttendance> _sample({int approved = 0}) {
  final date = TehranTime.jalaliDayIso(1405, 8, 2);
  final start = TehranTime.toUtcFromJalali(1405, 8, 2, 9, 0);
  return buildMonth(
    Jalali(1405, 8, 1),
    [
      _slice(id: 'a', date: date, start: start, end: start.add(const Duration(hours: 2)), decision: 'approved'),
      _slice(id: 'b', date: date, start: start.add(const Duration(hours: 3)), end: start.add(const Duration(hours: 4))),
    ],
    approved: approved == 0 ? const {} : {date: approved},
  );
}

Widget _harness({required List<DayAttendance> days, Brightness brightness = Brightness.light}) {
  return ProviderScope(
    overrides: [attendanceDayTotalsProvider.overrideWith((ref, key) async => _stubTotals)],
    child: MaterialApp(
      theme: buildAppTheme(brightness),
      home: Scaffold(body: _Host(days: days)),
    ),
  );
}

Widget _groupHarness({ValueChanged<String>? onPerson}) {
  final range = AttendanceRange.week(Jalali(1405, 8, 10));
  final date = TehranTime.jalaliDayIso(1405, 8, 10);
  final start = TehranTime.toUtcFromJalali(1405, 8, 10, 9, 0);
  PersonAttendance person(String id, String name) => PersonAttendance(
        id: id,
        name: name,
        teamId: 't',
        totals: DurationTotals(recorded: 5400, pending: 0, approved: id == '1' ? 5400 : 0, revision: 0, rejected: 0),
        days: buildDays(range.days, [
          _slice(id: 'a$id', date: date, start: start, end: start.add(const Duration(hours: 1)), decision: 'approved', profileId: id),
        ]),
      );
  return ProviderScope(
    overrides: [attendanceDayTotalsProvider.overrideWith((ref, key) async => _stubTotals)],
    child: MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: Scaffold(
        body: SingleChildScrollView(
          child: AttendanceGroupView(
            range: range,
            today: Jalali(1405, 8, 10),
            group: GroupAttendance(people: [person('1', 'آرش تست'), person('2', 'بهار تست')]),
            onPerson: onPerson ?? (_) {},
          ),
        ),
      ),
    ),
  );
}

class _Host extends StatefulWidget {
  const _Host({required this.days});

  final List<DayAttendance> days;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  int? selected;

  @override
  Widget build(BuildContext context) {
    return AttendanceCalendarView(
      month: Jalali(1405, 8, 1),
      today: Jalali(1405, 8, 16),
      profileId: 'p',
      model: AttendanceCalendarModel(days: widget.days, totals: AttendanceCalendarModel.emptyTotals),
      loading: false,
      selectedDay: selected,
      onMonth: (_) {},
      onSelect: (day) => setState(() => selected = day.day.day),
    );
  }
}
