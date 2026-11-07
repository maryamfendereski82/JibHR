import 'package:shamsi_date/shamsi_date.dart';

/// Asia/Tehran has no daylight-saving time, so UTC+03:30 is the whole rule.
/// Report boundaries in Postgres use the same zone.
class TehranTime {
  static const offset = Duration(hours: 3, minutes: 30);

  static DateTime wallClock(DateTime instant) {
    final utc = instant.toUtc().add(offset);
    return DateTime.utc(utc.year, utc.month, utc.day, utc.hour, utc.minute, utc.second);
  }

  /// A Tehran wall-clock time, stored as UTC. The date arguments are Jalali.
  static DateTime toUtcFromJalali(int year, int month, int day, int hour, int minute) {
    final gregorian = Jalali(year, month, day).toGregorian();
    return DateTime.utc(gregorian.year, gregorian.month, gregorian.day, hour, minute).subtract(offset);
  }

  static String jalaliDayIso(int year, int month, int day) {
    final gregorian = Jalali(year, month, day).toGregorian();
    return formatDateIso(DateTime.utc(gregorian.year, gregorian.month, gregorian.day));
  }

  static DateTime dateOnly(DateTime instant) {
    final wall = wallClock(instant);
    return DateTime.utc(wall.year, wall.month, wall.day);
  }

  static Jalali jalali(DateTime instant) {
    final day = dateOnly(instant);
    return Jalali.fromGregorian(Gregorian(day.year, day.month, day.day));
  }

  /// Saturday through Friday, matching `app.week_start`.
  static DateTime weekStart(DateTime instant) {
    final day = dateOnly(instant);
    final sinceSaturday = (day.weekday % 7 + 1) % 7;
    return day.subtract(Duration(days: sinceSaturday));
  }

  static DateTime weekEnd(DateTime instant) => weekStart(instant).add(const Duration(days: 6));

  static (DateTime start, DateTime end) jalaliMonth(DateTime instant) {
    final j = jalali(instant);
    final start = Jalali(j.year, j.month, 1).toGregorian();
    final end = Jalali(j.year, j.month, j.monthLength).toGregorian();
    return (
      DateTime.utc(start.year, start.month, start.day),
      DateTime.utc(end.year, end.month, end.day),
    );
  }

  static String formatDate(DateTime instant) {
    final j = jalali(instant);
    final f = j.formatter;
    return persianDigits('${f.wN} ${f.d} ${f.mN} ${f.yyyy}');
  }

  static String formatTime(DateTime instant) {
    final wall = wallClock(instant);
    final hh = wall.hour.toString().padLeft(2, '0');
    final mm = wall.minute.toString().padLeft(2, '0');
    return persianDigits('$hh:$mm');
  }

  static String formatDateIso(DateTime day) {
    final y = day.year.toString().padLeft(4, '0');
    final m = day.month.toString().padLeft(2, '0');
    final d = day.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }
}

String persianDigits(Object value) {
  const digits = '۰۱۲۳۴۵۶۷۸۹';
  return value.toString().replaceAllMapped(RegExp('[0-9]'), (match) {
    return digits[int.parse(match.group(0)!)];
  });
}

String formatHours(int seconds) {
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final hh = hours.toString().padLeft(2, '0');
  final mm = minutes.toString().padLeft(2, '0');
  return persianDigits('$hh:$mm');
}
