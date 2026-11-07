import 'package:flutter/material.dart';
import 'package:shamsi_date/shamsi_date.dart';

import '../../core/calendar/tehran_time.dart';

const jalaliMonths = [
  'فروردین',
  'اردیبهشت',
  'خرداد',
  'تیر',
  'مرداد',
  'شهریور',
  'مهر',
  'آبان',
  'آذر',
  'دی',
  'بهمن',
  'اسفند',
];

class JalaliStamp {
  const JalaliStamp({required this.year, required this.month, required this.day, this.hour = 9, this.minute = 0});

  final int year;
  final int month;
  final int day;
  final int hour;
  final int minute;

  DateTime toUtc() => TehranTime.toUtcFromJalali(year, month, day, hour, minute);

  String get isoDay => TehranTime.jalaliDayIso(year, month, day);

  JalaliStamp copyWith({int? year, int? month, int? day, int? hour, int? minute}) {
    final nextYear = year ?? this.year;
    final nextMonth = month ?? this.month;
    final length = Jalali(nextYear, nextMonth).monthLength;
    return JalaliStamp(
      year: nextYear,
      month: nextMonth,
      day: (day ?? this.day).clamp(1, length),
      hour: hour ?? this.hour,
      minute: minute ?? this.minute,
    );
  }

  static JalaliStamp today() {
    final now = TehranTime.jalali(DateTime.now().toUtc());
    final wall = TehranTime.wallClock(DateTime.now().toUtc());
    return JalaliStamp(year: now.year, month: now.month, day: now.day, hour: wall.hour, minute: wall.minute);
  }
}

class JalaliStampField extends StatelessWidget {
  const JalaliStampField({
    super.key,
    required this.value,
    required this.onChanged,
    this.withTime = true,
    this.showDate = true,
  });

  final JalaliStamp value;
  final ValueChanged<JalaliStamp> onChanged;
  final bool withTime;
  final bool showDate;

  @override
  Widget build(BuildContext context) {
    final length = Jalali(value.year, value.month).monthLength;
    final years = [value.year - 1, value.year, value.year + 1];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (showDate) ...[
          _menu<int>(
            value: value.year,
            items: years,
            label: (item) => persianDigits(item),
            onChanged: (item) => onChanged(value.copyWith(year: item)),
          ),
          _menu<int>(
            value: value.month,
            items: [for (var month = 1; month <= 12; month++) month],
            label: (item) => jalaliMonths[item - 1],
            onChanged: (item) => onChanged(value.copyWith(month: item)),
          ),
          _menu<int>(
            value: value.day.clamp(1, length),
            items: [for (var day = 1; day <= length; day++) day],
            label: (item) => persianDigits(item),
            onChanged: (item) => onChanged(value.copyWith(day: item)),
          ),
        ],
        if (withTime) ...[
          _menu<int>(
            value: value.hour,
            items: [for (var hour = 0; hour < 24; hour++) hour],
            label: (item) => persianDigits(item.toString().padLeft(2, '0')),
            onChanged: (item) => onChanged(value.copyWith(hour: item)),
          ),
          _menu<int>(
            value: value.minute,
            items: [for (var minute = 0; minute < 60; minute++) minute],
            label: (item) => persianDigits(item.toString().padLeft(2, '0')),
            onChanged: (item) => onChanged(value.copyWith(minute: item)),
          ),
        ],
      ],
    );
  }

  Widget _menu<T>({
    required T value,
    required List<T> items,
    required String Function(T item) label,
    required ValueChanged<T> onChanged,
  }) {
    return DropdownButton<T>(
      value: items.contains(value) ? value : items.first,
      items: [for (final item in items) DropdownMenuItem(value: item, child: Text(label(item)))],
      onChanged: (item) {
        if (item != null) onChanged(item);
      },
    );
  }
}
