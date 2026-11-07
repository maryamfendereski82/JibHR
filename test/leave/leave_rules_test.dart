import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jibhr/features/leave/leave_pages.dart';
import 'package:jibhr/features/leave/leave_rules.dart';
import 'package:shamsi_date/shamsi_date.dart';

void main() {
  test('daily and hourly leave follow the stored bounds', () {
    final today = DateTime.utc(2026, 3, 21);
    final tomorrow = DateTime.utc(2026, 3, 22);
    expect(leaveProblem(LeaveDraft(kind: 'daily', start: today, end: tomorrow)), isNull);
    expect(inclusiveDays(today, tomorrow), 2);
    expect(
      leaveProblem(LeaveDraft(kind: 'daily', start: tomorrow, end: today)),
      'invalid_range',
    );
    expect(
      leaveProblem(LeaveDraft(kind: 'hourly', start: today, startMinute: 9 * 60, endMinute: 11 * 60)),
      isNull,
    );
    expect(hourlyMinutes(9 * 60, 11 * 60), 120);
    expect(
      leaveProblem(LeaveDraft(kind: 'hourly', start: today, startMinute: 12 * 60, endMinute: 11 * 60)),
      'invalid_range',
    );
    expect(
      leaveProblem(LeaveDraft(kind: 'hourly', start: today, startMinute: 9 * 60, endMinute: 9 * 60)),
      'invalid_range',
    );
  });

  test('pending leave stays visible and is not treated as approved', () {
    expect(countsAsApprovedLeave('pending'), isFalse);
    expect(countsAsApprovedLeave('approved'), isTrue);
    expect(visibleOnCalendar('pending'), isTrue);
    expect(visibleOnCalendar('approved'), isTrue);
    expect(visibleOnCalendar('rejected'), isFalse);
  });

  test('calendar coverage keeps hourly leave on its own day', () {
    final first = DateTime.utc(2026, 3, 21);
    final second = DateTime.utc(2026, 3, 22);
    final daily = CalendarLeave(
      id: 'daily',
      kind: 'daily',
      status: 'approved',
      label: 'کارمند',
      start: first,
      end: second,
    );
    final hourly = CalendarLeave(
      id: 'hourly',
      kind: 'hourly',
      status: 'pending',
      label: 'کارمند',
      hoursDate: first,
    );
    expect(daily.covers(first), isTrue);
    expect(daily.covers(second), isTrue);
    expect(daily.covers(DateTime.utc(2026, 3, 23)), isFalse);
    expect(hourly.covers(first), isTrue);
    expect(hourly.covers(second), isFalse);
    expect(leaveOverlaps(daily, DateTime.utc(2026, 3, 22), DateTime.utc(2026, 3, 23)), isTrue);
    expect(leaveOverlaps(hourly, DateTime.utc(2026, 3, 22), DateTime.utc(2026, 3, 23)), isFalse);
  });

  test('jalali month opens on saturday and keeps seven-day rows', () {
    final month = Jalali(1405, 1, 1);
    final cells = leaveMonthCells(month);
    expect(month.weekDay, 1);
    expect(cells.takeWhile((cell) => cell == null).length, month.weekDay - 1);
    expect(cells.whereType<Jalali>().length, month.monthLength);
    expect(cells.length % 7, 0);
    expect(cells.first?.day, 1);
  });

  testWidgets('month grid marks approved and pending leave on different days', (tester) async {
    final third = _noon(Jalali(1405, 1, 3));
    final fourth = _noon(Jalali(1405, 1, 4));
    final fifth = _noon(Jalali(1405, 1, 5));
    final shown = [
      CalendarLeave(id: 'a', kind: 'daily', status: 'approved', label: 'کارمند', start: third, end: fourth),
      CalendarLeave(id: 'b', kind: 'hourly', status: 'pending', label: 'کارمند', hoursDate: fifth),
      CalendarLeave(id: 'c', kind: 'daily', status: 'rejected', label: 'کارمند', start: third, end: third),
    ].where((leave) => visibleOnCalendar(leave.status)).toList();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LeaveMonthGrid(
            month: Jalali(1405, 1, 1),
            leaves: shown,
            selected: null,
            onMonth: (_) {},
            onDay: (_) {},
          ),
        ),
      ),
    );

    expect(find.textContaining('فروردین'), findsOneWidget);
    expect(find.byKey(const ValueKey('day-3-approved-1-pending-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('day-4-approved-1-pending-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('day-5-approved-0-pending-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('approved-3')), findsOneWidget);
    expect(find.byKey(const ValueKey('pending-5')), findsOneWidget);
  });
}

DateTime _noon(Jalali day) {
  final gregorian = day.toGregorian();
  return DateTime.utc(gregorian.year, gregorian.month, gregorian.day, 12);
}
