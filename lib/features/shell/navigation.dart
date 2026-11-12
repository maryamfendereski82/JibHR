import '../../core/design_system/app_icons.dart';
import '../../core/localization/fa.dart';
import '../session/workspace_session.dart';

enum NavGroup { daily, insight, account }

class NavDestination {
  const NavDestination({
    required this.id,
    required this.label,
    required this.icon,
    required this.path,
    required this.group,
  });

  final String id;
  final String label;
  final AppIcon icon;
  final String path;
  final NavGroup group;

  @override
  String toString() => id;
}

const _home = NavDestination(id: 'home', label: Fa.dashboard, icon: AppIcons.home, path: '/', group: NavGroup.daily);
const _attendance = NavDestination(id: 'attendance', label: Fa.attendance, icon: AppIcons.attendance, path: '/attendance', group: NavGroup.daily);
const _leave = NavDestination(id: 'leave', label: Fa.leave, icon: AppIcons.leave, path: '/leave', group: NavGroup.daily);
const _work = NavDestination(id: 'work', label: Fa.work, icon: AppIcons.work, path: '/work', group: NavGroup.daily);
const _reports = NavDestination(id: 'reports', label: Fa.reports, icon: AppIcons.reports, path: '/reports', group: NavGroup.insight);
const _notifications = NavDestination(id: 'notifications', label: Fa.inbox, icon: AppIcons.notifications, path: '/notifications', group: NavGroup.account);
const _settings = NavDestination(id: 'settings', label: Fa.settings, icon: AppIcons.settings, path: '/settings', group: NavGroup.account);

bool canSeeAttendance(WorkspaceSession s) =>
    s.can('attendance.view.self') ||
    s.can('attendance.clock') ||
    s.can('attendance.approve.team') ||
    s.can('attendance.approve.all') ||
    s.can('attendance.correct.self');

bool canSeeLeave(WorkspaceSession s) =>
    s.can('leave.view.self') ||
    s.can('leave.request') ||
    s.can('leave.view.team') ||
    s.can('leave.view.all') ||
    s.can('leave.approve.team') ||
    s.can('leave.approve.all') ||
    s.can('absence.view.self') ||
    s.can('absence.view.team') ||
    s.can('absence.view.all') ||
    s.can('absence.record.team') ||
    s.can('absence.record.all');

bool canSeeWork(WorkspaceSession s) =>
    s.can('tasks.create.personal') ||
    s.can('tasks.create.project') ||
    s.can('tasks.manage.project') ||
    s.can('tasks.view.all') ||
    s.can('projects.create') ||
    s.can('projects.view.all');

/// The destinations a person sees, in display order.
///
/// The conditions for attendance, leave and work are the ones the shell used
/// before the redesign. Reports, notifications and settings are open to every
/// signed-in person, as the report links on Home were; each report page still
/// applies its own server-side scope.
List<NavDestination> navDestinations(WorkspaceSession? session) {
  return [
    _home,
    if (session != null && canSeeAttendance(session)) _attendance,
    if (session != null && canSeeLeave(session)) _leave,
    if (session != null && canSeeWork(session)) _work,
    if (session != null) _reports,
    if (session != null) _notifications,
    _settings,
  ];
}

/// Router branches, in the order of `StatefulShellRoute.branches`.
///
/// Branches are fixed; which of them a person can reach is decided by
/// [navDestinations]. Keep this list in step with app_router.dart.
const branchOrder = ['home', 'attendance', 'leave', 'work', 'reports', 'notifications', 'settings'];

int branchIndexOf(String destinationId) {
  final index = branchOrder.indexOf(destinationId);
  if (index < 0) throw ArgumentError.value(destinationId, 'destinationId', 'no router branch');
  return index;
}

/// The destination that owns [location], or null when none does.
///
/// Null is deliberate: an unknown page must not light up Home.
NavDestination? activeDestination(String location, List<NavDestination> destinations) {
  NavDestination? best;
  for (final item in destinations) {
    final match = item.path == '/'
        ? location == '/'
        : location == item.path || location.startsWith('${item.path}/');
    if (match && (best == null || item.path.length > best.path.length)) best = item;
  }
  return best;
}

/// Phone bar: at most five slots. With more destinations, four stay in the
/// bar and the rest move behind "more".
({List<NavDestination> bar, List<NavDestination> overflow}) splitForBottomBar(List<NavDestination> all) {
  if (all.length <= 5) return (bar: all, overflow: const []);
  const preferred = ['home', 'attendance', 'work', 'leave'];
  final bar = <NavDestination>[
    for (final id in preferred) ...all.where((item) => item.id == id),
  ];
  for (final item in all) {
    if (bar.length >= 4) break;
    if (!bar.contains(item)) bar.add(item);
  }
  final overflow = all.where((item) => !bar.contains(item)).toList();
  return (bar: bar, overflow: overflow);
}
