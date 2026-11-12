import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/calendar/tehran_time.dart';
import '../../core/design_system/state_views.dart';
import '../../core/localization/fa.dart';
import '../../core/theme/app_tokens.dart';
import '../attendance/attendance_page.dart';
import '../attendance/attendance_repository.dart';
import '../reports/report_repository.dart';
import '../reports/report_rules.dart';
import '../session/workspace_session.dart';
import '../shell/navigation.dart';
import '../work/project_pages.dart';
import '../work/work_repository.dart';
import 'dashboard_providers.dart';
import 'dashboard_rules.dart';
import 'widgets/home_parts.dart';
import 'widgets/home_sections.dart';
import 'widgets/people_panel.dart';

/// A provider's state as a section state. A failed refresh keeps the previous
/// value (Riverpod does), which then shows as stale instead of an error.
SectionData<T> _section<T>(AsyncValue<T?> value) {
  final data = value.hasValue ? value.value : null;
  return SectionData<T>(
    value: data,
    loading: value.isLoading && data == null && !value.hasError,
    error: value.hasError && data == null ? value.error : null,
    stale: value.hasError && data != null,
  );
}

/// The four dashboard sources. Refreshed together, failing separately.
void invalidateDashboardSections(WidgetRef ref) {
  ref.invalidate(dashboardPersonalProvider);
  ref.invalidate(dashboardQueuesProvider);
  ref.invalidate(dashboardTeamProvider);
  ref.invalidate(dashboardProjectsProvider);
}

class DashboardPage extends ConsumerStatefulWidget {
  const DashboardPage({super.key});

  @override
  ConsumerState<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends ConsumerState<DashboardPage> {
  bool _punching = false;

  Future<void> _punch(bool isOpen) async {
    if (_punching) return;
    setState(() => _punching = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await punchAttendance(ref, isOpen: isOpen);
      // Clocking changes personal figures and, for approvers, the queues.
      ref.invalidate(dashboardPersonalProvider);
      ref.invalidate(dashboardQueuesProvider);
      ref.invalidate(dashboardTeamProvider);
      messenger.showSnackBar(SnackBar(content: Text(isOpen ? Fa.homeClockedOutDone : Fa.homeClockedInDone)));
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text(Fa.network)));
    } finally {
      if (mounted) setState(() => _punching = false);
    }
  }

  void _refresh() {
    invalidateDashboardSections(ref);
    ref.invalidate(attendanceBoardProvider);
    ref.invalidate(homeTasksProvider);
    ref.invalidate(projectListProvider);
    ref.invalidate(homePeopleProvider);
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(workspaceSessionProvider);
    final value = session.asData?.value;
    if (value == null) {
      if (session.hasError) {
        return ErrorView(message: Fa.network, onRetry: () => ref.invalidate(workspaceSessionProvider));
      }
      return const HomeSkeleton();
    }

    final personal = _section<Map<String, dynamic>>(ref.watch(dashboardPersonalProvider));
    final queues = _section<Map<String, dynamic>>(ref.watch(dashboardQueuesProvider));
    final teamState = ref.watch(dashboardTeamProvider);
    final projectsState = ref.watch(dashboardProjectsProvider);

    // A section is shown when its function returned data. While it loads or
    // after it failed, it is shown only to people whose permissions mean it
    // could exist, so others never see a skeleton or error for it.
    final teamLoaded = teamState.hasValue;
    final team = teamLoaded
        ? (teamState.value == null ? null : _section<Map<String, dynamic>>(teamState))
        : (mayHaveTeamSection(value) ? _section<Map<String, dynamic>>(teamState) : null);
    final projectsLoaded = projectsState.hasValue;
    final projectsSummary = projectsLoaded
        ? (projectsState.value == null ? null : _section<Map<String, dynamic>>(projectsState))
        : (mayHaveProjectsSection(value) ? _section<Map<String, dynamic>>(projectsState) : null);

    final showAttendance = value.can('attendance.view.self');
    final attendance = showAttendance ? _section<AttendanceBoard>(ref.watch(attendanceBoardProvider)) : const SectionData<AttendanceBoard>();
    final showAgenda = canSeeWork(value);
    final tasks = showAgenda ? _section<List<TaskRow>>(ref.watch(homeTasksProvider)) : const SectionData<List<TaskRow>>();
    final projects = projectsSummary != null && projectsSummary.hasValue
        ? _section<List<ProjectRow>>(ref.watch(projectListProvider((archived: false, page: 0))).whenData((v) => v.projects))
        : const SectionData<List<ProjectRow>>(loading: true);

    return HomeView(
      session: value,
      now: DateTime.now().toUtc(),
      personal: personal,
      queues: queues,
      team: team,
      projectsSummary: projectsSummary,
      attendance: showAttendance ? attendance : null,
      tasks: showAgenda ? tasks : null,
      projects: projects,
      punching: _punching,
      onPunch: _punch,
      onNavigate: (path) => context.go(path),
      onRefresh: _refresh,
      onRetryPersonal: () => ref.invalidate(dashboardPersonalProvider),
      onRetryQueues: () {
        ref.invalidate(dashboardQueuesProvider);
        ref.invalidate(dashboardPersonalProvider);
      },
      onRetryTeam: () => ref.invalidate(dashboardTeamProvider),
      onRetryProjectsSummary: () => ref.invalidate(dashboardProjectsProvider),
      onRetryAttendance: () => ref.invalidate(attendanceBoardProvider),
      onRetryTasks: () => ref.invalidate(homeTasksProvider),
      onRetryProjects: () => ref.invalidate(projectListProvider),
      people: PeoplePanel(
        canOpenPerson: canOpenAttendance(value.permissions),
        onOpenPerson: (id) => context.go('/reports/attendance?profile=$id'),
      ),
    );
  }
}

/// The shape of Home while the session (and so the permissions) loads, so
/// the page does not start as a lone spinner and then jump.
class HomeSkeleton extends StatelessWidget {
  const HomeSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      final gutter = AppSpace.gutter(width);
      final content = math.min(width - gutter * 2, 1320.0);
      final twoColumn = content >= 880;
      Widget card(double height) => SkeletonBlock(height: height, radius: AppRadius.panel);
      return Semantics(
        label: Fa.loading,
        child: ListView(
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.symmetric(horizontal: gutter + (width - gutter * 2 - content) / 2, vertical: AppSpace.xxl),
          children: [
            // ListView stretches its children; Align keeps the title widths.
            const Align(alignment: AlignmentDirectional.centerStart, child: SkeletonBlock(height: 34, width: 260)),
            const SizedBox(height: AppSpace.s),
            const Align(alignment: AlignmentDirectional.centerStart, child: SkeletonBlock(height: 18, width: 200)),
            const SizedBox(height: AppSpace.xl),
            if (twoColumn)
              Row(children: [Expanded(flex: 5, child: card(260)), const SizedBox(width: AppSpace.l), Expanded(flex: 7, child: card(260))])
            else ...[card(240), const SizedBox(height: AppSpace.l), card(200)],
            const SizedBox(height: AppSpace.l),
            card(220),
          ],
        ),
      );
    });
  }
}

/// Home layout, provider-free. Every section gets its own [SectionData];
/// sections fed by `dashboard_summary` share one, so they fail together but
/// each shows its own error and retry.
class HomeView extends StatelessWidget {
  const HomeView({
    super.key,
    required this.session,
    required this.now,
    required this.personal,
    required this.queues,
    required this.team,
    required this.projectsSummary,
    required this.attendance,
    required this.tasks,
    required this.projects,
    required this.punching,
    required this.onPunch,
    required this.onNavigate,
    required this.onRefresh,
    required this.onRetryPersonal,
    required this.onRetryQueues,
    required this.onRetryTeam,
    required this.onRetryProjectsSummary,
    required this.onRetryAttendance,
    required this.onRetryTasks,
    required this.onRetryProjects,
    this.people,
  });

  final WorkspaceSession session;
  final DateTime now;

  /// `dashboard_personal`.
  final SectionData<Map<String, dynamic>> personal;

  /// `dashboard_queues`.
  final SectionData<Map<String, dynamic>> queues;

  /// `dashboard_team`; null when the section is not shown at all.
  final SectionData<Map<String, dynamic>>? team;

  /// `dashboard_projects`; null when the section is not shown at all.
  final SectionData<Map<String, dynamic>>? projectsSummary;

  /// Null when the person has no attendance of their own to show.
  final SectionData<AttendanceBoard>? attendance;

  /// Null when the person has no access to work.
  final SectionData<List<TaskRow>>? tasks;
  final SectionData<List<ProjectRow>> projects;
  final bool punching;
  final ValueChanged<bool> onPunch;
  final ValueChanged<String> onNavigate;
  final VoidCallback onRefresh;
  final VoidCallback onRetryPersonal;
  final VoidCallback onRetryQueues;
  final VoidCallback onRetryTeam;
  final VoidCallback onRetryProjectsSummary;
  final VoidCallback onRetryAttendance;
  final VoidCallback onRetryTasks;
  final VoidCallback onRetryProjects;

  /// The people table; it reads its own provider, so tests may leave it out.
  final Widget? people;

  /// Action items come from two sources: queues (what others wait on) and
  /// personal (the person's own follow-ups). Either can fail alone; the items
  /// of the other still show, with an error in place for the missing part.
  ({SectionData<List<HomeAction>> data, bool partial}) _actions() {
    final p = personal.value;
    final q = queues.value;
    if (p == null && q == null) {
      return (
        data: SectionData<List<HomeAction>>(
          loading: personal.loading || queues.loading,
          error: (personal.error != null && queues.error != null) ? (queues.error ?? personal.error) : null,
        ),
        partial: false,
      );
    }
    final partial = (q == null && !queues.loading) || (p == null && !personal.loading);
    return (
      data: SectionData<List<HomeAction>>(
        value: homeActions({'queues': q ?? const {}, 'personal': p ?? const {}}),
        stale: personal.stale || queues.stale,
      ),
      partial: partial,
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final gutter = AppSpace.gutter(width);
        final content = math.min(width - gutter * 2, 1320.0);
        final twoColumn = content >= 880;
        final compact = content < 600;
        const gap = AppSpace.l;

        final actions = _actions();

        Widget pair(Widget start, Widget end, {int startFlex = 5, int endFlex = 7}) {
          if (!twoColumn) return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [start, const SizedBox(height: gap), end]);
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: startFlex, child: start),
              const SizedBox(width: gap),
              Expanded(flex: endFlex, child: end),
            ],
          );
        }

        final hero = HomeHero(
          greeting: greetingFor(now),
          name: session.firstName,
          dateLine: TehranTime.formatDate(now),
          team: session.teamName,
          actions: quickActions(session),
          onNavigate: onNavigate,
          onRefresh: onRefresh,
          compact: compact,
        );
        final attendancePanel = attendance == null
            ? null
            : AttendancePanel(
                data: attendance!,
                canClock: session.can('attendance.clock'),
                busy: punching,
                onPunch: onPunch,
                onRetry: onRetryAttendance,
                onOpen: () => onNavigate('/attendance'),
              );
        final actionQueue = ActionQueue(data: actions.data, partialError: actions.partial, onNavigate: onNavigate, onRetry: onRetryQueues);
        final agenda = tasks == null
            ? null
            : AgendaPanel(
                data: tasks!,
                now: now,
                onOpenTask: (id) => onNavigate('/work/t/$id'),
                onSeeAll: () => onNavigate('/work/mine'),
                onRetry: onRetryTasks,
                onCreate: session.can('tasks.create.personal') ? () => onNavigate('/work/personal') : null,
              );
        final mine = MineCluster(
          data: personal,
          onRetry: onRetryPersonal,
          columns: twoColumn ? 2 : (content >= 520 ? 4 : 2),
        );

        final sections = <Widget>[
          hero,
          if (attendancePanel != null) pair(attendancePanel, actionQueue) else actionQueue,
          if (agenda != null) pair(agenda, mine, startFlex: 7, endFlex: 5) else mine,
          if (team != null) ...[
            TeamOverview(data: team!, onRetry: onRetryTeam, onNavigate: onNavigate, wide: content >= 760),
            if (team!.hasValue) ?people,
          ],
          if (projectsSummary != null)
            ProjectsOverview(
              summary: projectsSummary!,
              projects: projects,
              onRetrySummary: onRetryProjectsSummary,
              onRetryProjects: onRetryProjects,
              onOpenProject: (id) => onNavigate('/work/p/$id'),
              onSeeAll: () => onNavigate('/work'),
              columns: content >= 760 ? 4 : 2,
            ),
        ];

        return RefreshIndicator(
          onRefresh: () async => onRefresh(),
          child: ListView(
            key: const Key('home'),
            padding: EdgeInsets.symmetric(horizontal: gutter + (width - gutter * 2 - content) / 2, vertical: compact ? AppSpace.l : AppSpace.xxl),
            children: [
              for (var i = 0; i < sections.length; i++) ...[
                if (i > 0) SizedBox(height: i == 1 ? AppSpace.xl : gap),
                Reveal(order: i, child: sections[i]),
              ],
            ],
          ),
        );
      },
    );
  }
}
