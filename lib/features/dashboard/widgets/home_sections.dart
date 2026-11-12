import 'package:flutter/material.dart';

import '../../../core/calendar/tehran_time.dart';
import '../../../core/design_system/app_icons.dart';
import '../../../core/design_system/state_views.dart';
import '../../../core/design_system/surfaces.dart';
import '../../../core/localization/fa.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../attendance/attendance_repository.dart';
import '../../attendance/attendance_review.dart';
import '../../reports/report_rules.dart';
import '../../work/work_repository.dart';
import '../../work/work_rules.dart';
import '../../work/workflow_presentation.dart';
import '../dashboard_rules.dart';
import 'home_parts.dart';

// ---------------------------------------------------------------- Hero

/// The greeting sits on the canvas, not in a card: it introduces the page,
/// it is not a datum. Shortcuts sit beside it on wide screens.
class HomeHero extends StatelessWidget {
  const HomeHero({
    super.key,
    required this.greeting,
    required this.name,
    required this.dateLine,
    required this.actions,
    required this.onNavigate,
    required this.onRefresh,
    required this.compact,
    this.team,
  });

  final String greeting;
  final String name;
  final String dateLine;
  final String? team;
  final List<QuickAction> actions;
  final ValueChanged<String> onNavigate;
  final VoidCallback onRefresh;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text.rich(
            TextSpan(children: [
              TextSpan(text: '$greeting، ', style: TextStyle(color: p.muted, fontWeight: FontWeight.w500)),
              TextSpan(text: name),
            ]),
            style: (compact ? text.headlineSmall : text.headlineMedium)?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(height: 2),
        Wrap(
          spacing: AppSpace.s,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            AppIconView(AppIcons.calendar, size: AppIconSize.inline, color: p.muted),
            Text(dateLine, style: text.bodyMedium?.copyWith(color: p.muted)),
            if (team != null && team!.isNotEmpty) ...[
              Text('·', style: text.bodyMedium?.copyWith(color: p.muted)),
              AppIconView(AppIcons.team, size: AppIconSize.inline, color: p.muted),
              Text(team!, style: text.bodyMedium?.copyWith(color: p.muted)),
            ],
          ],
        ),
      ],
    );
    final chips = [
      for (final action in actions)
        _QuickChip(key: ValueKey('quick-${action.id}'), action: action, onTap: () => onNavigate(action.path)),
    ];
    final refresh = IconButton(
      key: const Key('home-refresh'),
      tooltip: Fa.refresh,
      onPressed: onRefresh,
      icon: const AppIconView(AppIcons.retry),
    );
    // Title line with the refresh button at its end, shortcuts on one line
    // under it, aligned with the title so the hero reads as one block.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: title), refresh]),
        const SizedBox(height: AppSpace.m),
        if (compact)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [for (final chip in chips) Padding(padding: const EdgeInsetsDirectional.only(end: AppSpace.s), child: chip)]),
          )
        else
          Wrap(spacing: AppSpace.s, runSpacing: AppSpace.s, children: chips),
      ],
    );
  }
}

class _QuickChip extends StatelessWidget {
  const _QuickChip({super.key, required this.action, required this.onTap});

  final QuickAction action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Material(
      color: Color.alphaBlend(p.surface.withValues(alpha: 0.7), p.canvas),
      shape: StadiumBorder(side: BorderSide(color: p.stroke)),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40),
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(AppSpace.m, 0, AppSpace.l, 0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppIconView(action.icon, size: 18, color: p.jade),
                const SizedBox(width: AppSpace.s),
                Text(action.label, style: Theme.of(context).textTheme.labelLarge),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- Attendance

/// Today's attendance and the clock action. The only blurred card on Home.
///
/// Reads `attendanceBoardProvider` (the attendance page's own source) and so
/// keeps working when `dashboard_summary` fails. All durations come from the
/// backend `attendance_totals`; nothing is summed here.
class AttendancePanel extends StatelessWidget {
  const AttendancePanel({
    super.key,
    required this.data,
    required this.canClock,
    required this.busy,
    required this.onPunch,
    required this.onRetry,
    required this.onOpen,
  });

  final SectionData<AttendanceBoard> data;
  final bool canClock;
  final bool busy;
  final ValueChanged<bool> onPunch;
  final VoidCallback onRetry;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return AppSurface(
      key: const Key('home-attendance'),
      level: SurfaceLevel.glass,
      radius: AppRadius.panel,
      padding: const EdgeInsets.all(AppSpace.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HomeSectionHeader(
            title: Fa.homeAttendance,
            icon: AppIcons.attendance,
            trailing: TextButton(onPressed: onOpen, child: const Text(Fa.homeOpenAttendance)),
          ),
          const SizedBox(height: AppSpace.m),
          SectionStates<AttendanceBoard>(
            data: data,
            onRetry: onRetry,
            skeleton: const Column(children: [
              SkeletonBlock(height: 28, width: 180),
              SizedBox(height: AppSpace.l),
              SkeletonRows(rows: 1, height: 64),
            ]),
            builder: (board) => _AttendanceBody(board: board, canClock: canClock, busy: busy, onPunch: onPunch, palette: p),
          ),
        ],
      ),
    );
  }
}

class _AttendanceBody extends StatelessWidget {
  const _AttendanceBody({required this.board, required this.canClock, required this.busy, required this.onPunch, required this.palette});

  final AttendanceBoard board;
  final bool canClock;
  final bool busy;
  final ValueChanged<bool> onPunch;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final text = Theme.of(context).textTheme;
    final open = board.isOpen;
    DateTime? since;
    for (final span in board.provisional) {
      if (since == null || span.start.isBefore(since)) since = span.start;
    }
    final status = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        StatusPill(
          label: open ? Fa.homeWorking : Fa.homeNoOpen,
          tone: open ? p.success : p.muted,
          icon: open ? AppIcons.clockIn : AppIcons.clockOut,
        ),
        if (open && since != null) ...[
          const SizedBox(height: AppSpace.s),
          Text('${Fa.homeOpenSince} ${TehranTime.formatTime(since)}', style: text.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        ],
      ],
    );
    final button = canClock
        ? SizedBox(
            height: 48,
            child: FilledButton.icon(
              key: const Key('home-punch'),
              onPressed: busy ? null : () => onPunch(open),
              icon: busy
                  ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: p.onJade))
                  : AppIconView(open ? AppIcons.clockOut : AppIcons.clockIn, color: p.onJade),
              label: Text(open ? Fa.homeClockOutAction : Fa.homeClockInAction),
            ),
          )
        : null;
    final figures = Wrap(
      spacing: AppSpace.xxl,
      runSpacing: AppSpace.m,
      children: [
        Kpi(label: Fa.homeRecorded, value: formatHours(board.today.recorded), unit: Fa.homeHoursUnit, emphasis: true),
        Kpi(label: Fa.homeApprovedToday, value: formatHours(board.today.approved), unit: Fa.homeHoursUnit, tone: p.success),
        Kpi(label: Fa.homePendingToday, value: formatHours(board.today.pending), unit: Fa.homeHoursUnit),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 420;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (narrow) ...[status, if (button != null) ...[const SizedBox(height: AppSpace.m), button]]
            else
              Row(children: [Expanded(child: status), if (button != null) ...[const SizedBox(width: AppSpace.m), button]]),
            const SizedBox(height: AppSpace.l),
            Divider(color: p.hairline),
            const SizedBox(height: AppSpace.m),
            figures,
            if (open) ...[
              const SizedBox(height: AppSpace.m),
              Row(children: [
                AppIconView(AppIcons.info, size: AppIconSize.inline, color: p.info),
                const SizedBox(width: AppSpace.xs),
                Expanded(child: Text(Fa.homeProvisionalHint, style: text.bodySmall)),
              ]),
            ],
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------- Actions

/// What waits for this person, grouped by what it asks of them.
class ActionQueue extends StatelessWidget {
  const ActionQueue({super.key, required this.data, required this.onNavigate, required this.onRetry, this.partialError = false});

  final SectionData<List<HomeAction>> data;

  /// One of the two sources failed: show what arrived, never "all clear".
  final bool partialError;
  final ValueChanged<String> onNavigate;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final total = data.value?.where((a) => a.kind != ActionKind.waiting).fold<int>(0, (sum, a) => sum + a.count) ?? 0;
    return Container(
      key: const Key('home-actions'),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.panel),
        boxShadow: AppElevation.e1(p.ink),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.panel),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: p.surface,
            border: Border.all(color: p.stroke),
            borderRadius: BorderRadius.circular(AppRadius.panel),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The accent: a thin jade band, not a red alarm.
              Container(height: 3, color: total > 0 ? p.jade : p.hairline),
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpace.xl, AppSpace.l, AppSpace.xl, AppSpace.l),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    HomeSectionHeader(
                      title: Fa.homeAttention,
                      icon: AppIcons.approve,
                      trailing: total > 0 ? StatusPill(label: '${persianDigits(total)} ${Fa.homeItems}', tone: p.jade) : null,
                    ),
                    const SizedBox(height: AppSpace.m),
                    SectionStates<List<HomeAction>>(
                      data: data,
                      onRetry: onRetry,
                      skeleton: const SkeletonRows(rows: 3, height: 48),
                      builder: (items) => Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (items.isNotEmpty) _list(context, items) else if (!partialError) _allClear(context),
                          if (partialError) ...[
                            if (items.isNotEmpty) const SizedBox(height: AppSpace.s),
                            InlineError(key: const Key('actions-partial-error'), message: Fa.homePartialError, onRetry: onRetry),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _allClear(BuildContext context) {
    final p = paletteOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.m),
      child: Row(children: [
        AppIconView(AppIcons.approve, color: p.success),
        const SizedBox(width: AppSpace.s),
        Expanded(child: Text(Fa.homeAllClear, style: Theme.of(context).textTheme.bodyMedium)),
      ]),
    );
  }

  Widget _list(BuildContext context, List<HomeAction> items) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    final children = <Widget>[];
    ActionKind? last;
    for (final item in items) {
      if (item.kind != last) {
        if (last != null) children.add(const SizedBox(height: AppSpace.s));
        children.add(Padding(
          padding: const EdgeInsets.only(bottom: AppSpace.xs),
          child: Text(
            switch (item.kind) {
              ActionKind.decide => Fa.homeDecide,
              ActionKind.fix => Fa.homeFix,
              ActionKind.waiting => Fa.homeWaiting,
            },
            style: text.labelMedium?.copyWith(color: p.muted),
          ),
        ));
        last = item.kind;
      }
      children.add(_ActionRow(item: item, onTap: () => onNavigate(item.path)));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.item, required this.onTap});

  final HomeAction item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    final tone = switch (item.kind) {
      ActionKind.decide => p.jade,
      ActionKind.fix => p.warning,
      ActionKind.waiting => p.muted,
    };
    final strong = item.kind != ActionKind.waiting;
    return Semantics(
      button: true,
      label: '${item.title}: ${persianDigits(item.count)} ${Fa.homeItems}',
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey('action-${item.id}'),
        borderRadius: BorderRadius.circular(AppRadius.control),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.s, vertical: AppSpace.s),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: Color.alphaBlend(tone.withValues(alpha: 0.13), p.surface),
                  borderRadius: BorderRadius.circular(AppRadius.control),
                ),
                child: Center(child: AppIconView(item.icon, size: 18, color: tone)),
              ),
              const SizedBox(width: AppSpace.m),
              Expanded(
                child: Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: text.bodyMedium?.copyWith(fontWeight: strong ? FontWeight.w600 : FontWeight.w400)),
              ),
              const SizedBox(width: AppSpace.s),
              Text(
                persianDigits(item.count),
                style: (strong ? text.titleLarge : text.titleMedium)?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(width: AppSpace.s),
              AppIconView(AppIcons.open, size: AppIconSize.inline, color: p.muted),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- Agenda

/// Open tasks grouped by deadline: one list for "my tasks" and "deadlines",
/// so the same task never appears twice.
class AgendaPanel extends StatelessWidget {
  const AgendaPanel({
    super.key,
    required this.data,
    required this.now,
    required this.onOpenTask,
    required this.onSeeAll,
    required this.onRetry,
    this.onCreate,
  });

  final SectionData<List<TaskRow>> data;
  final DateTime now;
  final ValueChanged<String> onOpenTask;
  final VoidCallback onSeeAll;
  final VoidCallback onRetry;
  final VoidCallback? onCreate;

  @override
  Widget build(BuildContext context) {
    return AppSurface(
      key: const Key('home-agenda'),
      radius: AppRadius.panel,
      padding: const EdgeInsets.all(AppSpace.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HomeSectionHeader(
            title: Fa.homeAgenda,
            icon: AppIcons.due,
            trailing: TextButton(onPressed: onSeeAll, child: const Text(Fa.homeAgendaAll)),
          ),
          const SizedBox(height: AppSpace.m),
          SectionStates<List<TaskRow>>(
            data: data,
            onRetry: onRetry,
            skeleton: const SkeletonRows(rows: 4, height: 52),
            builder: (tasks) => tasks.isEmpty ? _empty(context) : _groups(context, tasks),
          ),
        ],
      ),
    );
  }

  /// Compact: an empty list should not become a tall empty card.
  Widget _empty(BuildContext context) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    final message = Row(children: [
      Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(color: p.ink.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(AppRadius.control)),
        child: Center(child: AppIconView(AppIcons.checklist, color: p.muted)),
      ),
      const SizedBox(width: AppSpace.m),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(Fa.homeAgendaEmpty, style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
          if (onCreate != null) Text(Fa.homeAgendaEmptyHint, style: text.bodySmall),
        ]),
      ),
    ]);
    final button = onCreate == null
        ? null
        : OutlinedButton.icon(onPressed: onCreate, icon: const AppIconView(AppIcons.addBoxed), label: const Text(Fa.quickPersonalTask));
    return LayoutBuilder(builder: (context, constraints) {
      if (button == null) return message;
      if (constraints.maxWidth < 460) {
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [message, const SizedBox(height: AppSpace.m), button]);
      }
      return Row(children: [Expanded(child: message), const SizedBox(width: AppSpace.m), button]);
    });
  }

  Widget _groups(BuildContext context, List<TaskRow> tasks) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    final children = <Widget>[];
    for (final (group, rows) in groupAgenda(tasks, now)) {
      if (children.isNotEmpty) children.add(const SizedBox(height: AppSpace.s));
      final tone = group == AgendaGroup.overdue ? p.danger : p.muted;
      children.add(Padding(
        padding: const EdgeInsets.only(bottom: AppSpace.xs),
        child: Row(children: [
          if (group == AgendaGroup.overdue) ...[AppIconView(AppIcons.warning, size: 14, color: tone), const SizedBox(width: AppSpace.xs)],
          Text('${agendaGroupLabel(group)} · ${persianDigits(rows.length)}', style: text.labelMedium?.copyWith(color: tone, fontWeight: FontWeight.w600)),
        ]),
      ));
      for (var i = 0; i < rows.length; i++) {
        if (i > 0) children.add(Divider(height: 1, color: p.hairline));
        children.add(_TaskRow(task: rows[i], now: now, onTap: () => onOpenTask(rows[i].id)));
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({required this.task, required this.now, required this.onTap});

  final TaskRow task;
  final DateTime now;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    final priorityTone = switch (task.priority) {
      'critical' => p.danger,
      'high' => p.warning,
      'low' => p.muted,
      _ => p.info,
    };
    final due = task.dueAt;
    final days = due == null ? null : daysUntil(due, now);
    final dueTone = days == null
        ? p.muted
        : days < 0
            ? p.danger
            : days == 0
                ? p.warning
                : p.muted;
    final where = task.projectName ?? Fa.personalTasks;
    return Semantics(
      button: true,
      child: InkWell(
        key: ValueKey('agenda-${task.id}'),
        borderRadius: BorderRadius.circular(AppRadius.control),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.xs, vertical: AppSpace.m),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: AppIconView(AppIcons.priority, selected: task.priority == 'critical' || task.priority == 'high', size: 18, color: priorityTone),
              ),
              const SizedBox(width: AppSpace.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(task.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: text.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(
                      '${priorityLabel(task.priority)} · ${groupLabel(groupOf(task))} · $where',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpace.m),
              if (due != null)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      AppIconView(AppIcons.due, size: 14, color: dueTone),
                      const SizedBox(width: AppSpace.xs),
                      Text(relativeDue(due, now), style: text.labelMedium?.copyWith(color: dueTone == p.muted ? p.ink : dueTone, fontWeight: FontWeight.w600)),
                    ]),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- Mine

/// A small cluster of the person's own figures from `dashboard_summary`.
class MineCluster extends StatelessWidget {
  const MineCluster({super.key, required this.data, required this.onRetry, required this.columns});

  final SectionData<Map<String, dynamic>> data;
  final VoidCallback onRetry;
  final int columns;

  @override
  Widget build(BuildContext context) {
    return AppSurface(
      key: const Key('home-mine'),
      level: SurfaceLevel.raised,
      radius: AppRadius.panel,
      padding: const EdgeInsets.all(AppSpace.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const HomeSectionHeader(title: Fa.homeMine, icon: AppIcons.profile),
          const SizedBox(height: AppSpace.l),
          SectionStates<Map<String, dynamic>>(
            data: data,
            onRetry: onRetry,
            skeleton: const SkeletonRows(rows: 2, height: 56),
            builder: (personal) {
              final personalTasks = asInt(personal['personal_tasks']);
              final projectTasks = asInt(personal['project_tasks']);
              final kpis = [
                Kpi(label: Fa.personalTaskCount, value: persianDigits(personalTasks), unit: Fa.unitOpenTasks, emphasis: true),
                Kpi(label: Fa.projectTasks, value: persianDigits(projectTasks), unit: Fa.unitOpenTasks, emphasis: true),
                Kpi(label: Fa.homeWeekApproved, value: formatHours(asInt(personal['week_approved_seconds'])), unit: Fa.homeHoursUnit),
                Kpi(label: Fa.homeMonthApproved, value: formatHours(asInt(personal['month_approved_seconds'])), unit: Fa.homeHoursUnit),
              ];
              return _KpiGrid(columns: columns, children: kpis);
            },
          ),
        ],
      ),
    );
  }
}

class _KpiGrid extends StatelessWidget {
  const _KpiGrid({required this.columns, required this.children});

  final int columns;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i += columns) {
      if (rows.isNotEmpty) rows.add(const SizedBox(height: AppSpace.l));
      rows.add(Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var j = i; j < i + columns; j++) Expanded(child: j < children.length ? children[j] : const SizedBox.shrink()),
        ],
      ));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
  }
}

// ---------------------------------------------------------------- Team

/// Team figures from `dashboard_summary`, in three meaningful groups. No
/// ranking, and no one is called absent for lacking an attendance record.
class TeamOverview extends StatelessWidget {
  const TeamOverview({super.key, required this.data, required this.onRetry, required this.onNavigate, required this.wide});

  final SectionData<Map<String, dynamic>> data;
  final VoidCallback onRetry;
  final ValueChanged<String> onNavigate;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    return AppSurface(
      key: const Key('home-team'),
      radius: AppRadius.panel,
      padding: const EdgeInsets.all(AppSpace.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const HomeSectionHeader(title: Fa.homeTeam, subtitle: Fa.homeTeamScope, icon: AppIcons.team),
          const SizedBox(height: AppSpace.l),
          SectionStates<Map<String, dynamic>>(
            data: data,
            onRetry: onRetry,
            skeleton: const SkeletonRows(rows: 2, height: 72),
            builder: (team) => _body(context, team),
          ),
        ],
      ),
    );
  }

  Widget _body(BuildContext context, Map<String, dynamic> team) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    final completion = teamCompletion(team);
    final overdue = asInt(team['overdue_tasks']);
    final presence = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _GroupTitle(icon: AppIcons.attendance, title: Fa.teamPresence),
        const SizedBox(height: AppSpace.m),
        Kpi(label: Fa.teamActive, value: persianDigits(asInt(team['employees'])), unit: Fa.unitPeople, emphasis: true),
        const SizedBox(height: AppSpace.m),
        Kpi(label: Fa.teamWorkingNow, value: persianDigits(asInt(team['open_intervals'])), unit: Fa.teamWorkingNowHint),
      ],
    );
    final requests = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _GroupTitle(icon: AppIcons.pending, title: Fa.teamRequests),
        const SizedBox(height: AppSpace.s),
        _CountRow(label: Fa.pendingReports, count: asInt(team['pending_reports'])),
        _CountRow(label: Fa.pendingCorrections, count: asInt(team['pending_corrections'])),
        _CountRow(label: Fa.leavePending, count: asInt(team['pending_leave'])),
        _CountRow(label: Fa.pendingDisputes, count: asInt(team['pending_disputes'])),
      ],
    );
    final tasks = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _GroupTitle(icon: AppIcons.work, title: Fa.teamTasks),
        const SizedBox(height: AppSpace.m),
        if (completion != null) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text('${persianDigits((completion * 100).round())}٪', style: text.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(width: AppSpace.s),
              Flexible(child: Text(Fa.teamDone, style: text.bodySmall)),
            ],
          ),
          const SizedBox(height: AppSpace.s),
          Semantics(
            label: '${Fa.teamDone} ${persianDigits((completion * 100).round())}٪',
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(value: completion, minHeight: 8),
            ),
          ),
          const SizedBox(height: AppSpace.m),
        ],
        _CountRow(label: Fa.activeTasks, count: asInt(team['active_tasks'])),
        _CountRow(label: Fa.reviewTasks, count: asInt(team['review_tasks'])),
        _CountRow(label: Fa.overdueTasks, count: overdue, tone: overdue > 0 ? p.danger : null, icon: overdue > 0 ? AppIcons.warning : null),
      ],
    );
    final groups = [presence, requests, tasks];
    final body = wide
        ? IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < groups.length; i++) ...[
                  if (i > 0) VerticalDivider(width: AppSpace.x4, color: p.hairline),
                  Expanded(child: groups[i]),
                ],
              ],
            ),
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < groups.length; i++) ...[
                if (i > 0) Padding(padding: const EdgeInsets.symmetric(vertical: AppSpace.l), child: Divider(color: p.hairline)),
                groups[i],
              ],
            ],
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        body,
        const SizedBox(height: AppSpace.l),
        Row(children: [
          AppIconView(AppIcons.info, size: AppIconSize.inline, color: p.muted),
          const SizedBox(width: AppSpace.xs),
          Expanded(child: Text('${Fa.noRanking} ${Fa.teamNoAbsence}', style: text.bodySmall)),
        ]),
      ],
    );
  }
}

class _GroupTitle extends StatelessWidget {
  const _GroupTitle({required this.icon, required this.title});

  final AppIcon icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Row(children: [
      AppIconView(icon, size: AppIconSize.inline, color: p.jade),
      const SizedBox(width: AppSpace.xs),
      Text(title, style: Theme.of(context).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700)),
    ]);
  }
}

class _CountRow extends StatelessWidget {
  const _CountRow({required this.label, required this.count, this.tone, this.icon});

  final String label;
  final int count;
  final Color? tone;
  final AppIcon? icon;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    return Semantics(
      label: '$label: ${persianDigits(count)}',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          if (icon != null) ...[AppIconView(icon!, size: 14, color: tone ?? p.muted), const SizedBox(width: AppSpace.xs)],
          Expanded(child: Text(label, style: text.bodyMedium?.copyWith(color: tone ?? p.muted))),
          Text(persianDigits(count), style: text.titleSmall?.copyWith(color: tone ?? p.ink, fontWeight: FontWeight.w700)),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------- Projects

class ProjectsOverview extends StatelessWidget {
  const ProjectsOverview({
    super.key,
    required this.summary,
    required this.projects,
    required this.onRetrySummary,
    required this.onRetryProjects,
    required this.onOpenProject,
    required this.onSeeAll,
    required this.columns,
  });

  final SectionData<Map<String, dynamic>> summary;
  final SectionData<List<ProjectRow>> projects;
  final VoidCallback onRetrySummary;
  final VoidCallback onRetryProjects;
  final ValueChanged<String> onOpenProject;
  final VoidCallback onSeeAll;
  final int columns;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return AppSurface(
      key: const Key('home-projects'),
      radius: AppRadius.panel,
      padding: const EdgeInsets.all(AppSpace.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HomeSectionHeader(
            title: Fa.homeProjects,
            icon: AppIcons.projects,
            trailing: TextButton(onPressed: onSeeAll, child: const Text(Fa.homeProjectsAll)),
          ),
          const SizedBox(height: AppSpace.l),
          SectionStates<Map<String, dynamic>>(
            data: summary,
            onRetry: onRetrySummary,
            skeleton: const SkeletonRows(rows: 1, height: 56),
            builder: (s) {
              final overdue = asInt(s['overdue']);
              return _KpiGrid(columns: columns, children: [
                Kpi(label: Fa.activeProjects, value: persianDigits(asInt(s['active'])), unit: Fa.unitProjects, emphasis: true),
                Kpi(label: Fa.activeSprints, value: persianDigits(asInt(s['active_sprints'])), unit: Fa.unitSprints),
                Kpi(label: Fa.upcomingMilestones, value: persianDigits(asInt(s['upcoming_milestones'])), unit: Fa.unitMilestones),
                Kpi(label: Fa.overdueTasks, value: persianDigits(overdue), unit: Fa.unitTasks, tone: overdue > 0 ? p.danger : null, icon: overdue > 0 ? AppIcons.warning : null),
              ]);
            },
          ),
          const SizedBox(height: AppSpace.l),
          SectionStates<List<ProjectRow>>(
            data: projects,
            onRetry: onRetryProjects,
            skeleton: const SkeletonRows(rows: 2, height: 56),
            builder: (rows) {
              if (rows.isEmpty) {
                return Text(Fa.homeProjectsEmpty, style: Theme.of(context).textTheme.bodySmall);
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < rows.length && i < 4; i++) ...[
                    if (i > 0) Divider(height: 1, color: p.hairline),
                    _ProjectRowTile(project: rows[i], onTap: () => onOpenProject(rows[i].id)),
                  ],
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _ProjectRowTile extends StatelessWidget {
  const _ProjectRowTile({required this.project, required this.onTap});

  final ProjectRow project;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    return InkWell(
      key: ValueKey('project-${project.id}'),
      borderRadius: BorderRadius.circular(AppRadius.control),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.xs, vertical: AppSpace.m),
        child: Row(children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(AppRadius.control),
            ),
            child: Center(child: AppIconView(AppIcons.projects, size: 18, color: p.jade)),
          ),
          const SizedBox(width: AppSpace.m),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(project.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
              Text(
                project.description.trim().isEmpty ? '${project.creatorName} · ${formatStamp(project.createdAt)}' : project.description,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.bodySmall,
              ),
            ]),
          ),
          AppIconView(AppIcons.open, size: AppIconSize.inline, color: p.muted),
        ]),
      ),
    );
  }
}
