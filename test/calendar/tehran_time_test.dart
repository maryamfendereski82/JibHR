import 'package:flutter_test/flutter_test.dart';
import 'package:jibhr/core/calendar/tehran_time.dart';
import 'package:shamsi_date/shamsi_date.dart';

void main() {
  test('tehran offset and saturday week match the database rule', () {
    final nowruz = DateTime.utc(2026, 3, 20, 20, 30);
    final jalali = TehranTime.jalali(nowruz);
    expect(jalali.year, 1405);
    expect(jalali.month, 1);
    expect(jalali.day, 1);

    final day = DateTime.utc(2026, 11, 5, 12);
    final start = TehranTime.weekStart(day);
    expect(start.weekday, DateTime.saturday);
    expect(TehranTime.weekStart(start.add(const Duration(days: 6))), start);
    expect(TehranTime.weekEnd(day), start.add(const Duration(days: 6)));
    expect(TehranTime.weekStart(start.add(const Duration(days: 7))), start.add(const Duration(days: 7)));
  });

  test('jalali month bounds use shamsi_date', () {
    final instant = DateTime.utc(2026, 11, 5, 8);
    final (start, end) = TehranTime.jalaliMonth(instant);
    final month = TehranTime.jalali(instant);
    final expectedStart = Jalali(month.year, month.month, 1).toGregorian();
    final expectedEnd = Jalali(month.year, month.month, month.monthLength).toGregorian();
    expect(start, DateTime.utc(expectedStart.year, expectedStart.month, expectedStart.day));
    expect(end, DateTime.utc(expectedEnd.year, expectedEnd.month, expectedEnd.day));
  });

  test('jalali wall clock converts back to the same tehran instant', () {
    final utc = TehranTime.toUtcFromJalali(1405, 1, 1, 0, 0);
    expect(utc, DateTime.utc(2026, 3, 20, 20, 30));
    expect(TehranTime.jalaliDayIso(1405, 1, 1), '2026-03-21');
  });

  test('persian digits and duration formatting', () {
    expect(persianDigits(1405), '۱۴۰۵');
    expect(formatHours(5400), '۰۱:۳۰');
    expect(formatHours(1800), '۰۰:۳۰');
  });
}
