import 'package:flutter/material.dart';
import 'package:shamsi_date/shamsi_date.dart';

import '../../core/calendar/tehran_time.dart';
import '../../core/localization/fa.dart';
import '../../core/theme/app_theme.dart';
import 'attendance_calendar.dart';
import 'attendance_calendar_view.dart';
import 'jalali_fields.dart';

const _nameWidth = 216.0;
const _dayWidth = 118.0;
const _headerHeight = 54.0;
const _rowHeight = 104.0;
const _rangesInCell = 2;

/// Wide screens compare people across days. A phone compares them on one day,
/// because a shrunken matrix would not leave a time readable.
class AttendanceGroupView extends StatelessWidget {
  const AttendanceGroupView({
    super.key,
    required this.range,
    required this.today,
    required this.group,
    required this.onPerson,
  });

  final AttendanceRange range;
  final Jalali today;
  final GroupAttendance group;
  final ValueChanged<String> onPerson;

  @override
  Widget build(BuildContext context) {
    if (group.people.isEmpty) return const AttendancePanel(child: Text(Fa.empty));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) => constraints.maxWidth < compactBelow
              ? _PhoneDayList(range: range, today: today, people: group.people, onPerson: onPerson)
              : _Matrix(range: range, today: today, people: group.people, onPerson: onPerson),
        ),
        if (group.truncated) ...[
          const SizedBox(height: 8),
          Text(Fa.peopleTruncated, style: TextStyle(color: paletteOf(context).warning)),
        ],
        const SizedBox(height: 10),
        const AttendanceLegend(),
      ],
    );
  }
}

class _Matrix extends StatefulWidget {
  const _Matrix({required this.range, required this.today, required this.people, required this.onPerson});

  final AttendanceRange range;
  final Jalali today;
  final List<PersonAttendance> people;
  final ValueChanged<String> onPerson;

  @override
  State<_Matrix> createState() => _MatrixState();
}

class _MatrixState extends State<_Matrix> {
  final _horizontal = ScrollController();

  @override
  void dispose() {
    _horizontal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final days = widget.range.days;
    return AttendancePanel(
      key: const Key('attendance-matrix'),
      padding: const EdgeInsets.all(8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: _nameWidth,
            child: Column(
              children: [
                const SizedBox(height: _headerHeight),
                for (final person in widget.people) _NameCell(person: person, onPerson: widget.onPerson),
              ],
            ),
          ),
          Expanded(
            child: Scrollbar(
              controller: _horizontal,
              thumbVisibility: true,
              child: SingleChildScrollView(
                controller: _horizontal,
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [for (final day in days) _DayHeader(day: day, today: widget.today)]),
                    for (final person in widget.people)
                      Row(
                        children: [
                          for (final day in person.days) _MatrixCell(person: person, day: day),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.day, required this.today});

  final Jalali day;
  final Jalali today;

  @override
  Widget build(BuildContext context) {
    final palette = paletteOf(context);
    final isToday = isoOf(day) == isoOf(today);
    final formatter = day.formatter;
    return Container(
      width: _dayWidth,
      height: _headerHeight,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: isToday ? palette.jade.withValues(alpha: 0.14) : null,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(formatter.wN, style: TextStyle(color: palette.muted, fontSize: 12)),
          Text(
            persianDigits('${formatter.d} ${formatter.mN}'),
            style: Theme.of(context).textTheme.titleSmall?.copyWith(color: isToday ? palette.jade : null),
          ),
        ],
      ),
    );
  }
}

class _NameCell extends StatelessWidget {
  const _NameCell({required this.person, required this.onPerson});

  final PersonAttendance person;
  final ValueChanged<String> onPerson;

  @override
  Widget build(BuildContext context) {
    final palette = paletteOf(context);
    final totals = person.totals;
    final tone = personTone(totals);
    final name = person.name.isEmpty ? Fa.employee : person.name;
    return SizedBox(
      height: _rowHeight,
      child: Semantics(
        button: true,
        label: '$name، ${Fa.openPersonCalendar}',
        child: InkWell(
          key: ValueKey('person-${person.id}'),
          borderRadius: BorderRadius.circular(12),
          onTap: () => onPerson(person.id),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(border: Border(top: BorderSide(color: palette.hairline))),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleSmall),
                    ),
                    if (tone != DayTone.empty) TonePill(label: dayToneLabel(tone), tone: tone),
                  ],
                ),
                const SizedBox(height: 4),
                _Figure(Fa.approved, totals.approved, palette.jade, bold: true),
                _Figure(Fa.pending, totals.pending, palette.warning),
                if (totals.revision > 0) _Figure(Fa.needsRevision, totals.revision, palette.revision),
                if (totals.rejected > 0) _Figure(Fa.rejected, totals.rejected, palette.danger),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure(this.label, this.seconds, this.color, {this.bold = false});

  final String label;
  final int seconds;
  final Color color;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12))),
        Text(formatHours(seconds), style: TextStyle(color: color, fontSize: 12, fontWeight: bold ? FontWeight.w700 : FontWeight.w500)),
      ],
    );
  }
}

class _MatrixCell extends StatelessWidget {
  const _MatrixCell({required this.person, required this.day});

  final PersonAttendance person;
  final DayAttendance day;

  @override
  Widget build(BuildContext context) {
    final palette = paletteOf(context);
    final hasData = day.slices.isNotEmpty;
    final tone = toneColor(palette, day.tone);
    final name = person.name.isEmpty ? Fa.employee : person.name;
    final shown = day.slices.take(_rangesInCell).toList();
    final hidden = day.slices.length - shown.length;
    return Container(
      width: _dayWidth,
      height: _rowHeight,
      decoration: BoxDecoration(border: Border(top: BorderSide(color: palette.hairline))),
      padding: const EdgeInsets.all(2),
      child: Semantics(
        button: true,
        label: '$name، ${dayCellLabel(day)}',
        excludeSemantics: true,
        child: Material(
          color: hasData ? tone.withValues(alpha: 0.09) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            key: ValueKey('cell-${person.id}-${day.iso}'),
            borderRadius: BorderRadius.circular(10),
            onTap: () => showDayDetail(context, day: day, profileId: person.id, personName: name),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: !hasData
                  ? Center(child: Text('—', style: TextStyle(color: palette.muted)))
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(dayToneLabel(day.tone), style: TextStyle(color: tone, fontSize: 11.5, fontWeight: FontWeight.w600)),
                        for (final slice in shown)
                          Text(
                            sliceRange(slice),
                            maxLines: 1,
                            overflow: TextOverflow.clip,
                            textDirection: TextDirection.ltr,
                            style: TextStyle(fontSize: 11.5, color: toneColor(palette, sliceTone(slice))),
                          ),
                        if (hidden > 0)
                          Text('+${persianDigits(hidden)} ${Fa.intervalsWord}', style: TextStyle(fontSize: 11, color: palette.muted)),
                        if (day.approvedSeconds > 0)
                          Text(
                            '${dayToneLabel(DayTone.approved)} ${formatHours(day.approvedSeconds)}',
                            style: TextStyle(fontSize: 11.5, color: palette.jade, fontWeight: FontWeight.w700),
                          ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PhoneDayList extends StatefulWidget {
  const _PhoneDayList({required this.range, required this.today, required this.people, required this.onPerson});

  final AttendanceRange range;
  final Jalali today;
  final List<PersonAttendance> people;
  final ValueChanged<String> onPerson;

  @override
  State<_PhoneDayList> createState() => _PhoneDayListState();
}

class _PhoneDayListState extends State<_PhoneDayList> {
  late Jalali focus = _start();

  Jalali _start() => widget.range.contains(widget.today) ? widget.today : widget.range.from;

  @override
  void didUpdateWidget(_PhoneDayList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.range.contains(focus)) focus = _start();
  }

  @override
  Widget build(BuildContext context) {
    final palette = paletteOf(context);
    final iso = isoOf(focus);
    return Column(
      key: const Key('attendance-phone-day'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final day in widget.range.days)
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 6),
                  child: ChoiceChip(
                    key: ValueKey('focus-${isoOf(day)}'),
                    showCheckmark: false,
                    selected: isoOf(day) == iso,
                    onSelected: (_) => setState(() => focus = day),
                    label: Text(persianDigits('${day.formatter.wN} ${day.day} ${jalaliMonths[day.month - 1]}'), style: const TextStyle(fontSize: 12)),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        for (final person in widget.people)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _PersonDayCard(person: person, day: person.dayOn(iso), palette: palette, onPerson: widget.onPerson),
          ),
      ],
    );
  }
}

class _PersonDayCard extends StatelessWidget {
  const _PersonDayCard({required this.person, required this.day, required this.palette, required this.onPerson});

  final PersonAttendance person;
  final DayAttendance? day;
  final AppPalette palette;
  final ValueChanged<String> onPerson;

  @override
  Widget build(BuildContext context) {
    final name = person.name.isEmpty ? Fa.employee : person.name;
    final current = day;
    return AttendancePanel(
      padding: const EdgeInsets.all(12),
      child: InkWell(
        key: ValueKey('person-day-${person.id}'),
        onTap: current == null ? null : () => showDayDetail(context, day: current, profileId: person.id, personName: name),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(name, style: Theme.of(context).textTheme.titleSmall)),
                if (current != null && current.tone != DayTone.empty) TonePill(label: dayToneLabel(current.tone), tone: current.tone),
                IconButton(
                  tooltip: Fa.openPersonCalendar,
                  visualDensity: VisualDensity.compact,
                  onPressed: () => onPerson(person.id),
                  icon: const Icon(Icons.calendar_month_outlined, size: 20),
                ),
              ],
            ),
            if (current == null || current.slices.isEmpty)
              Text(Fa.noDayAttendance, style: TextStyle(color: palette.muted, fontSize: 12.5))
            else ...[
              for (final slice in current.slices)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Row(
                    children: [
                      Text(sliceRange(slice), textDirection: TextDirection.ltr, style: TextStyle(fontSize: 13, color: toneColor(palette, sliceTone(slice)))),
                      const SizedBox(width: 8),
                      Text(sliceLabel(slice), style: TextStyle(fontSize: 12, color: palette.muted)),
                    ],
                  ),
                ),
              if (current.approvedSeconds > 0)
                Text(
                  '${Fa.approved}: ${formatHours(current.approvedSeconds)}',
                  style: TextStyle(color: palette.jade, fontSize: 12.5, fontWeight: FontWeight.w700),
                ),
            ],
            const SizedBox(height: 4),
            Text(
              '${Fa.approved} ${formatHours(person.totals.approved)} · ${Fa.pending} ${formatHours(person.totals.pending)}',
              style: TextStyle(color: palette.muted, fontSize: 11.5),
            ),
          ],
        ),
      ),
    );
  }
}

class AttendanceRangeBar extends StatelessWidget {
  const AttendanceRangeBar({super.key, required this.range, required this.today, required this.onChanged});

  final AttendanceRange range;
  final Jalali today;
  final ValueChanged<AttendanceRange> onChanged;

  Future<void> _custom(BuildContext context) async {
    final picked = await showDialog<AttendanceRange>(
      context: context,
      builder: (context) => _RangeDialog(initial: range),
    );
    if (picked != null) onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      key: const Key('attendance-range'),
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SegmentedButton<RangeKind>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: RangeKind.week, label: Text(Fa.rangeWeek)),
            ButtonSegment(value: RangeKind.month, label: Text(Fa.rangeMonth)),
            ButtonSegment(value: RangeKind.custom, label: Text(Fa.rangeCustom)),
          ],
          selected: {range.kind},
          onSelectionChanged: (value) {
            switch (value.first) {
              case RangeKind.week:
                onChanged(AttendanceRange.week(range.contains(today) ? today : range.from));
              case RangeKind.month:
                onChanged(AttendanceRange.month(range.contains(today) ? today : range.from));
              case RangeKind.custom:
                _custom(context);
            }
          },
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(tooltip: Fa.previousPeriod, onPressed: () => onChanged(range.shift(-1)), icon: const Icon(Icons.chevron_right)),
            Text(rangeLabel(range), key: const Key('attendance-range-label'), style: Theme.of(context).textTheme.titleSmall),
            IconButton(tooltip: Fa.nextPeriod, onPressed: () => onChanged(range.shift(1)), icon: const Icon(Icons.chevron_left)),
            if (range.kind == RangeKind.custom)
              IconButton(tooltip: Fa.rangeCustom, onPressed: () => _custom(context), icon: const Icon(Icons.edit_calendar_outlined)),
          ],
        ),
      ],
    );
  }
}

String rangeLabel(AttendanceRange range) {
  if (range.kind == RangeKind.month) {
    return '${jalaliMonths[range.from.month - 1]} ${persianDigits(range.from.year)}';
  }
  final from = '${persianDigits(range.from.day)} ${jalaliMonths[range.from.month - 1]}';
  final to = '${persianDigits(range.to.day)} ${jalaliMonths[range.to.month - 1]} ${persianDigits(range.to.year)}';
  return '$from تا $to';
}

class _RangeDialog extends StatefulWidget {
  const _RangeDialog({required this.initial});

  final AttendanceRange initial;

  @override
  State<_RangeDialog> createState() => _RangeDialogState();
}

class _RangeDialogState extends State<_RangeDialog> {
  late JalaliStamp from = _stamp(widget.initial.from);
  late JalaliStamp to = _stamp(widget.initial.to);
  bool invalid = false;

  JalaliStamp _stamp(Jalali day) => JalaliStamp(year: day.year, month: day.month, day: day.day);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text(Fa.rangeCustom),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(Fa.rangeFrom),
          JalaliStampField(value: from, withTime: false, onChanged: (value) => setState(() => from = value)),
          const SizedBox(height: 8),
          const Text(Fa.rangeTo),
          JalaliStampField(value: to, withTime: false, onChanged: (value) => setState(() => to = value)),
          if (invalid) ...[
            const SizedBox(height: 8),
            Text(Fa.rangeInvalid, style: TextStyle(color: paletteOf(context).danger)),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text(Fa.cancel)),
        FilledButton(
          onPressed: () {
            final picked = AttendanceRange.custom(
              Jalali(from.year, from.month, from.day),
              Jalali(to.year, to.month, to.day),
            );
            if (picked == null) {
              setState(() => invalid = true);
              return;
            }
            Navigator.of(context).pop(picked);
          },
          child: const Text(Fa.rangeApply),
        ),
      ],
    );
  }
}
