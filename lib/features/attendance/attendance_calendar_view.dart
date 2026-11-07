import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shamsi_date/shamsi_date.dart';

import '../../core/calendar/tehran_time.dart';
import '../../core/localization/fa.dart';
import '../../core/theme/app_theme.dart';
import 'attendance_calendar.dart';
import 'attendance_providers.dart';
import 'jalali_fields.dart';

const _wideFrom = 1000.0;
const compactBelow = 700.0;

class AttendanceCalendarView extends StatelessWidget {
  const AttendanceCalendarView({
    super.key,
    required this.month,
    required this.today,
    required this.profileId,
    required this.model,
    required this.loading,
    required this.selectedDay,
    required this.onMonth,
    required this.onSelect,
    this.leading,
  });

  final Jalali month;
  final Jalali today;
  final String profileId;
  final AttendanceCalendarModel model;
  final bool loading;
  final int? selectedDay;
  final ValueChanged<int> onMonth;
  final ValueChanged<DayAttendance> onSelect;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final wide = width >= _wideFrom;
        final compact = width < compactBelow;
        final selected = _selected(model, selectedDay);
        final grid = _MonthGrid(
          month: month,
          today: today,
          days: model.days,
          loading: loading,
          selectedDay: selectedDay,
          compact: compact,
          onMonth: onMonth,
          onSelect: (day) {
            onSelect(day);
            if (compact) showDayDetail(context, day: day, profileId: profileId);
          },
        );
        final detail = AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: selected == null
              ? const AttendancePanel(key: ValueKey('no-day'), child: Text(Fa.selectDay))
              : AttendancePanel(
                  key: ValueKey('day-${selected.iso}'),
                  child: AttendanceDayDetail(day: selected, profileId: profileId),
                ),
        );
        final strip = _TotalsStrip(totals: model.totals, compact: compact);

        if (wide) {
          return Row(
            key: const Key('attendance-layout-wide'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    ?leading,
                    strip,
                    const SizedBox(height: 12),
                    grid,
                  ],
                ),
              ),
              SizedBox(
                width: 340,
                child: ListView(
                  padding: const EdgeInsetsDirectional.fromSTEB(0, 16, 16, 16),
                  children: [detail],
                ),
              ),
            ],
          );
        }
        return ListView(
          key: Key(compact ? 'attendance-layout-compact' : 'attendance-layout-medium'),
          padding: const EdgeInsets.all(16),
          children: [
            ?leading,
            strip,
            const SizedBox(height: 12),
            grid,
            if (!compact) ...[
              const SizedBox(height: 12),
              detail,
            ],
          ],
        );
      },
    );
  }

  DayAttendance? _selected(AttendanceCalendarModel model, int? day) {
    if (day == null) return null;
    for (final item in model.days) {
      if (item.day.day == day) return item;
    }
    return null;
  }
}

class _TotalsStrip extends StatelessWidget {
  const _TotalsStrip({required this.totals, required this.compact});

  final DurationTotals totals;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final palette = paletteOf(context);
    final items = [
      (Fa.approved, totals.approved, palette.jade),
      (Fa.pending, totals.pending, palette.warning),
      (Fa.needsRevision, totals.revision, palette.revision),
      (Fa.rejected, totals.rejected, palette.danger),
      (Fa.recorded, totals.recorded, palette.muted),
    ];
    return LayoutBuilder(
      key: const Key('attendance-summary'),
      builder: (context, constraints) {
        const gap = 8.0;
        final columns = compact ? 2 : 5;
        final tile = (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final (index, item) in items.indexed)
              SizedBox(
                // On a phone the approved figure leads on its own row.
                width: compact && index == 0 ? constraints.maxWidth : tile,
                child: AttendancePanel(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: compact ? 6 : 10),
                  child: compact
                      // One line per figure, so the calendar stays near the top of a phone.
                      ? Row(
                          children: [
                            Expanded(
                              child: Text(item.$1, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: palette.muted, fontSize: 12)),
                            ),
                            Text(
                              formatHours(item.$2),
                              style: Theme.of(context).textTheme.titleSmall?.copyWith(color: item.$3, fontWeight: FontWeight.w700),
                            ),
                          ],
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(item.$1, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: palette.muted, fontSize: 12)),
                            const SizedBox(height: 2),
                            Text(
                              formatHours(item.$2),
                              style: Theme.of(context).textTheme.titleLarge?.copyWith(color: item.$3, fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _MonthGrid extends StatelessWidget {
  const _MonthGrid({
    required this.month,
    required this.today,
    required this.days,
    required this.loading,
    required this.selectedDay,
    required this.compact,
    required this.onMonth,
    required this.onSelect,
  });

  final Jalali month;
  final Jalali today;
  final List<DayAttendance> days;
  final bool loading;
  final int? selectedDay;
  final bool compact;
  final ValueChanged<int> onMonth;
  final ValueChanged<DayAttendance> onSelect;

  @override
  Widget build(BuildContext context) {
    final byDay = {for (final day in days) day.day.day: day};
    final cells = monthCells(month);
    return AttendancePanel(
      key: const Key('attendance-calendar'),
      padding: EdgeInsets.all(compact ? 8 : 16),
      child: Column(
        children: [
          Row(
            children: [
              IconButton(tooltip: Fa.previousMonth, onPressed: () => onMonth(-1), icon: const Icon(Icons.chevron_right)),
              Expanded(
                child: Text(
                  '${jalaliMonths[month.month - 1]} ${persianDigits(month.year)}',
                  key: const Key('attendance-month'),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton(tooltip: Fa.nextMonth, onPressed: () => onMonth(1), icon: const Icon(Icons.chevron_left)),
            ],
          ),
          SizedBox(height: 2, child: loading ? const LinearProgressIndicator() : null),
          const SizedBox(height: 6),
          const Row(children: [
            _WeekLabel('ش'),
            _WeekLabel('ی'),
            _WeekLabel('د'),
            _WeekLabel('س'),
            _WeekLabel('چ'),
            _WeekLabel('پ'),
            _WeekLabel('ج'),
          ]),
          const SizedBox(height: 6),
          AnimatedOpacity(
            opacity: loading ? 0.5 : 1,
            duration: const Duration(milliseconds: 150),
            child: GridView.builder(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 7,
                mainAxisExtent: compact ? 72 : 108,
              ),
              itemCount: cells.length,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemBuilder: (context, index) {
                final cell = cells[index];
                final day = cell == null ? null : byDay[cell.day];
                if (day == null) return const SizedBox.shrink();
                return _DayCell(
                  day: day,
                  today: today,
                  selected: selectedDay == day.day.day,
                  compact: compact,
                  onSelect: onSelect,
                );
              },
            ),
          ),
          const SizedBox(height: 10),
          const AttendanceLegend(),
        ],
      ),
    );
  }
}

class _WeekLabel extends StatelessWidget {
  const _WeekLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Expanded(child: Text(text, textAlign: TextAlign.center, style: TextStyle(color: paletteOf(context).muted)));
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.today,
    required this.selected,
    required this.compact,
    required this.onSelect,
  });

  final DayAttendance day;
  final Jalali today;
  final bool selected;
  final bool compact;
  final ValueChanged<DayAttendance> onSelect;

  @override
  Widget build(BuildContext context) {
    final palette = paletteOf(context);
    final tone = toneColor(palette, day.tone);
    final isToday = isoOf(day.day) == isoOf(today);
    final future = isoOf(day.day).compareTo(isoOf(today)) > 0;
    final friday = day.day.weekDay == 7;
    final first = day.slices.isEmpty ? null : day.slices.first;
    final last = day.slices.isEmpty ? null : day.slices.last;
    final small = TextStyle(fontSize: compact ? 10 : 11.5, height: 1.25);
    final fill = selected
        ? palette.jade.withValues(alpha: 0.16)
        : day.tone == DayTone.empty
            ? (friday ? palette.muted.withValues(alpha: 0.05) : Colors.transparent)
            : tone.withValues(alpha: 0.09);
    return Padding(
      padding: const EdgeInsets.all(2),
      child: Semantics(
        button: true,
        selected: selected,
        label: dayCellLabel(day),
        excludeSemantics: true,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: selected ? palette.jade : palette.hairline, width: selected ? 1.5 : 1),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              key: ValueKey('day-${day.day.day}'),
              borderRadius: BorderRadius.circular(12),
              onTap: () => onSelect(day),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: compact ? 2 : 6, vertical: compact ? 3 : 5),
                child: Column(
                  crossAxisAlignment: compact ? CrossAxisAlignment.center : CrossAxisAlignment.start,
                  children: [
                    if (compact)
                      _DayNumber(day: day.day.day, today: isToday, friday: friday, tight: true)
                    else
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          _DayNumber(day: day.day.day, today: isToday, friday: friday),
                          if (day.slices.length > 1)
                            Flexible(
                              child: Text(
                                '${persianDigits(day.slices.length)} ${Fa.intervalsWord}',
                                maxLines: 1,
                                overflow: TextOverflow.clip,
                                style: small.copyWith(color: palette.muted, fontSize: 10.5),
                              ),
                            ),
                        ],
                      ),
                    if (day.tone != DayTone.empty)
                      Text(dayToneLabel(day.tone), style: small.copyWith(color: tone, fontWeight: FontWeight.w600))
                    else if (!future && !friday)
                      Text('—', style: small.copyWith(color: palette.muted)),
                    if (first != null && !compact) ...[
                      Text('${Fa.clockIn} ${_short(first.startedAt)}', style: small, maxLines: 1, overflow: TextOverflow.clip),
                      Text('${Fa.clockOut} ${_endShort(last!)}', style: small, maxLines: 1, overflow: TextOverflow.clip),
                    ],
                    if (first != null && compact)
                      Text(_short(first.startedAt), style: small, maxLines: 1, overflow: TextOverflow.clip),
                    if (!compact && day.approvedSeconds > 0)
                      Text(
                        '${dayToneLabel(DayTone.approved)} ${formatHours(day.approvedSeconds)}',
                        style: small.copyWith(color: palette.jade, fontWeight: FontWeight.w600),
                        maxLines: 1,
                        overflow: TextOverflow.clip,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DayNumber extends StatelessWidget {
  const _DayNumber({required this.day, required this.today, required this.friday, this.tight = false});

  final int day;
  final bool today;
  final bool friday;
  final bool tight;

  @override
  Widget build(BuildContext context) {
    final palette = paletteOf(context);
    final style = Theme.of(context).textTheme.titleSmall;
    final text = persianDigits(day);
    if (!today) return Text(text, style: style?.copyWith(color: friday ? palette.muted : null));
    return Container(
      padding: EdgeInsets.symmetric(horizontal: tight ? 4 : 7),
      decoration: BoxDecoration(color: palette.jade, borderRadius: BorderRadius.circular(10)),
      child: Text(text, style: style?.copyWith(color: palette.canvas, fontWeight: FontWeight.w700)),
    );
  }
}

class AttendanceLegend extends StatelessWidget {
  const AttendanceLegend({super.key});

  @override
  Widget build(BuildContext context) {
    final palette = paletteOf(context);
    return Wrap(
      spacing: 12,
      runSpacing: 4,
      children: [
        for (final tone in const [
          DayTone.approved,
          DayTone.pending,
          DayTone.partial,
          DayTone.revision,
          DayTone.rejected,
          DayTone.incomplete,
          DayTone.open,
        ])
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: toneColor(palette, tone), shape: BoxShape.circle),
              ),
              const SizedBox(width: 4),
              Text(dayToneLabel(tone), style: TextStyle(color: palette.muted, fontSize: 11.5)),
            ],
          ),
      ],
    );
  }
}

class TonePill extends StatelessWidget {
  const TonePill({super.key, required this.label, required this.tone});

  final String label;
  final DayTone tone;

  @override
  Widget build(BuildContext context) {
    final color = toneColor(paletteOf(context), tone);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.13), borderRadius: BorderRadius.circular(999)),
      child: Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }
}

/// Every duration here is backend output. Without it, the line stays a dash.
class AttendanceDayDetail extends ConsumerWidget {
  const AttendanceDayDetail({super.key, required this.day, required this.profileId, this.personName});

  final DayAttendance day;
  final String profileId;
  final String? personName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = paletteOf(context);
    final totals = ref.watch(attendanceDayTotalsProvider((profileId: profileId, iso: day.iso)));
    final formatter = day.day.formatter;
    return Column(
      key: const Key('attendance-detail'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (personName != null) Text(personName!, style: Theme.of(context).textTheme.titleMedium),
        Row(
          children: [
            Expanded(
              child: Text(
                persianDigits('${formatter.wN} ${formatter.d} ${formatter.mN} ${formatter.yyyy}'),
                style: personName == null ? Theme.of(context).textTheme.titleMedium : TextStyle(color: palette.muted),
              ),
            ),
            if (day.tone != DayTone.empty) TonePill(label: dayToneLabel(day.tone), tone: day.tone),
          ],
        ),
        const SizedBox(height: 12),
        if (day.slices.isEmpty)
          const Text(Fa.noDayAttendance)
        else ...[
          for (final slice in day.slices) _SliceRow(slice: slice),
          Divider(color: palette.hairline, height: 20),
          Text(Fa.dayTotalsTitle, style: TextStyle(color: palette.muted, fontSize: 12)),
          const SizedBox(height: 6),
          if (totals.hasError && !totals.hasValue)
            Text(Fa.network, style: TextStyle(color: palette.danger))
          else ...[
            _DurationLine(Fa.approved, totals.asData?.value.approved, palette.jade, bold: true),
            _DurationLine(Fa.pending, totals.asData?.value.pending, palette.warning),
            _DurationLine(Fa.needsRevision, totals.asData?.value.revision, palette.revision),
            _DurationLine(Fa.rejected, totals.asData?.value.rejected, palette.danger),
            _DurationLine(Fa.recorded, totals.asData?.value.recorded, palette.muted),
          ],
        ],
      ],
    );
  }
}

class _DurationLine extends StatelessWidget {
  const _DurationLine(this.label, this.seconds, this.color, {this.bold = false});

  final String label;
  final int? seconds;
  final Color color;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final weight = bold ? FontWeight.w700 : FontWeight.w500;
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        children: [
          Expanded(child: Text(label, style: TextStyle(fontWeight: bold ? FontWeight.w600 : null))),
          Text(seconds == null ? '—' : formatHours(seconds!), style: TextStyle(color: color, fontWeight: weight)),
        ],
      ),
    );
  }
}

class _SliceRow extends StatelessWidget {
  const _SliceRow({required this.slice});

  final CalendarSlice slice;

  @override
  Widget build(BuildContext context) {
    final palette = paletteOf(context);
    final tone = sliceTone(slice);
    final end = slice.endedAt != null
        ? _clock(slice.endedAt!)
        : slice.intervalStatus == 'open'
            ? Fa.stillOpen
            : Fa.noClockOut;
    final platforms = [slice.startPlatform, slice.endPlatform].whereType<String>().join(' ← ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsetsDirectional.only(start: 10),
        decoration: BoxDecoration(
          border: BorderDirectional(start: BorderSide(color: toneColor(palette, tone), width: 3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 12,
              children: [
                Text('${Fa.clockIn} ${slice.startedAt == null ? '—' : _clock(slice.startedAt!)}', style: Theme.of(context).textTheme.titleSmall),
                Text('${Fa.clockOut} $end', style: Theme.of(context).textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: 3),
            Wrap(
              spacing: 6,
              runSpacing: 3,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TonePill(label: sliceLabel(slice), tone: tone),
                if (slice.dailyCut) Text(Fa.dailyCut, style: TextStyle(color: palette.muted, fontSize: 12)),
                if (slice.provisional) Text(Fa.preview, style: TextStyle(color: palette.warning, fontSize: 12)),
                if (platforms.isNotEmpty) Text(platforms, style: TextStyle(color: palette.muted, fontSize: 12)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class AttendancePanel extends StatelessWidget {
  const AttendancePanel({super.key, required this.child, this.padding = const EdgeInsets.all(16)});

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final palette = paletteOf(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.panel,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: palette.stroke),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 18, offset: const Offset(0, 6)),
        ],
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

/// A bottom sheet on a phone and a side dialog on anything wider.
Future<void> showDayDetail(
  BuildContext context, {
  required DayAttendance day,
  required String profileId,
  String? personName,
}) {
  final body = AttendanceDayDetail(day: day, profileId: profileId, personName: personName);
  if (MediaQuery.sizeOf(context).width < compactBelow) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
        child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), child: body),
      ),
    );
  }
  return showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      alignment: AlignmentDirectional.centerEnd,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      child: SizedBox(
        width: 400,
        child: SingleChildScrollView(padding: const EdgeInsets.all(20), child: body),
      ),
    ),
  );
}

String dayCellLabel(DayAttendance day) {
  final parts = <String>[persianDigits(day.day.day), jalaliMonths[day.day.month - 1]];
  if (day.tone != DayTone.empty) parts.add(dayToneLabel(day.tone));
  if (day.slices.isNotEmpty) {
    parts.add('${Fa.clockIn} ${_short(day.slices.first.startedAt)}');
    parts.add('${Fa.clockOut} ${_endShort(day.slices.last)}');
    parts.add('${persianDigits(day.slices.length)} ${Fa.intervalsWord}');
  }
  if (day.approvedSeconds > 0) parts.add('${Fa.approved} ${formatHours(day.approvedSeconds)}');
  return parts.join('، ');
}

String _short(DateTime? instant) => instant == null ? '—' : TehranTime.formatTime(instant);

String _endShort(CalendarSlice slice) {
  if (slice.endedAt != null) return TehranTime.formatTime(slice.endedAt!);
  return slice.intervalStatus == 'open' ? dayToneLabel(DayTone.open) : '؟';
}

/// A slice's range in the short form used by the group matrix.
String sliceRange(CalendarSlice slice) => '${_short(slice.startedAt)}–${_endShort(slice)}';

String _clock(DateTime instant) {
  final wall = TehranTime.wallClock(instant);
  final hh = wall.hour.toString().padLeft(2, '0');
  final mm = wall.minute.toString().padLeft(2, '0');
  final ss = wall.second.toString().padLeft(2, '0');
  return persianDigits('$hh:$mm:$ss');
}

String sliceLabel(CalendarSlice slice) {
  if (slice.intervalStatus == 'incomplete') return Fa.incomplete;
  if (slice.intervalStatus == 'open' || slice.provisional) return Fa.openInterval;
  if (slice.approvalMode == 'correction' || slice.decision == 'approved') return Fa.approved;
  if (slice.decision == 'needs_revision') return Fa.needsRevision;
  if (slice.decision == 'rejected') return Fa.rejected;
  if (slice.decision == null || slice.decision == 'pending') return Fa.pending;
  return Fa.partiallyApproved;
}

DayTone sliceTone(CalendarSlice slice) {
  if (slice.intervalStatus == 'incomplete') return DayTone.incomplete;
  if (slice.intervalStatus == 'open' || slice.provisional) return DayTone.open;
  return dayTone([slice]);
}

Color toneColor(AppPalette palette, DayTone tone) {
  return switch (tone) {
    DayTone.approved => palette.jade,
    DayTone.open => palette.info,
    DayTone.pending || DayTone.partial => palette.warning,
    DayTone.revision => palette.revision,
    DayTone.rejected => palette.danger,
    DayTone.incomplete => palette.alert,
    DayTone.empty => palette.muted,
  };
}
