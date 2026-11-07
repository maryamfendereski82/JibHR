import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/design_system/brand_mark.dart';
import '../../core/localization/fa.dart';
import '../../core/networking/supabase_provider.dart';
import '../../core/offline/offline_cache.dart';
import '../../core/calendar/tehran_time.dart';
import '../../core/theme/app_theme.dart';
import '../notifications/notification_repository.dart';
import '../notifications/notification_pages.dart';
import '../reports/report_repository.dart';
import '../session/workspace_session.dart';

class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(connectionTickProvider);
    final hub = ref.watch(connectionHubProvider);
    final config = ref.watch(appConfigProvider);
    final session = ref.watch(workspaceSessionProvider).asData?.value;
    ref.listen(workspaceSessionProvider, (previous, next) {
      final current = next.asData?.value;
      final previousId = previous?.asData?.value?.profileId;
      if (current == null && previousId != null && previousId.isNotEmpty) {
        ref.read(offlineCacheProvider).clearUser(previousId);
      }
      if (current != null && previousId != null && previousId != current.profileId) {
        ref.read(offlineCacheProvider).clearUser(previousId);
      }
      hub.noteSession(userId: current?.profileId, workspaceId: current?.workspaceId);
    });
    ref.listen(connectionTickProvider, (previous, next) {
      if (!hub.offline) {
        ref.invalidate(workspaceSessionProvider);
        ref.invalidate(dashboardSummaryProvider);
        ref.read(inboxReconnectProvider.notifier).bump();
      }
    });
    final destinations = <_Destination>[
      const _Destination(Fa.dashboard, Icons.space_dashboard_outlined, '/'),
      if (session != null &&
          (session.can('attendance.view.self') ||
              session.can('attendance.clock') ||
              session.can('attendance.approve.team') ||
              session.can('attendance.approve.all') ||
              session.can('attendance.correct.self')))
        const _Destination(Fa.attendance, Icons.schedule, '/attendance'),
      if (session != null &&
          (session.can('leave.view.self') ||
              session.can('leave.request') ||
              session.can('leave.view.team') ||
              session.can('leave.view.all') ||
              session.can('leave.approve.team') ||
              session.can('leave.approve.all') ||
              session.can('absence.view.self') ||
              session.can('absence.view.team') ||
              session.can('absence.view.all') ||
              session.can('absence.record.team') ||
              session.can('absence.record.all')))
        const _Destination(Fa.leave, Icons.event_available_outlined, '/leave'),
      if (session != null &&
          (session.can('tasks.create.personal') ||
              session.can('tasks.create.project') ||
              session.can('tasks.manage.project') ||
              session.can('tasks.view.all') ||
              session.can('projects.create') ||
              session.can('projects.view.all')))
        const _Destination(Fa.work, Icons.account_tree_outlined, '/work'),
      const _Destination(Fa.settings, Icons.settings_outlined, '/settings'),
    ];
    final location = GoRouterState.of(context).uri.path;
    final match = destinations.indexWhere((item) {
      if (item.path == '/') return location == '/';
      return location == item.path || location.startsWith('${item.path}/');
    });
    final selected = match < 0 ? 0 : match;
    final wide = MediaQuery.sizeOf(context).width >= 1080;

    final framed = _OfflineFrame(
      offline: hub.offline,
      locked: hub.locked,
      validatedAt: hub.validatedAt,
      environment: config.showEnvironment ? config.environment : null,
      child: child,
    );
    if (wide) {
      return Scaffold(
        body: Row(
          children: [
            _Sidebar(destinations: destinations, selected: selected),
            Expanded(child: framed),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text(Fa.appName),
        actions: const [NotificationBell()],
      ),
      body: framed,
      bottomNavigationBar: NavigationBar(
        selectedIndex: selected,
        onDestinationSelected: (index) => context.go(destinations[index].path),
        destinations: [
          for (final item in destinations) NavigationDestination(icon: Icon(item.icon), label: item.label),
        ],
      ),
    );
  }
}

class _OfflineFrame extends StatelessWidget {
  const _OfflineFrame({
    required this.offline,
    required this.locked,
    required this.child,
    this.validatedAt,
    this.environment,
  });

  final bool offline;
  final bool locked;
  final DateTime? validatedAt;
  final String? environment;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final palette = paletteOf(context);
    final stamp = validatedAt == null ? Fa.neverSynced : TehranTime.formatDate(validatedAt!);
    return Column(
      children: [
        if (environment != null)
          Material(color: palette.card, child: Padding(padding: const EdgeInsets.all(8), child: Text('${Fa.environment}: $environment'))),
        if (offline)
          Material(
            color: palette.card,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(locked ? Fa.offlineExpired : '${Fa.offlineBanner} $stamp. ${Fa.offlineStale}'),
            ),
          ),
        Expanded(child: child),
      ],
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.destinations, required this.selected});

  final List<_Destination> destinations;
  final int selected;

  @override
  Widget build(BuildContext context) {
    final palette = paletteOf(context);
    return Container(
      width: 248,
      color: palette.card,
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              BrandMark(size: 40),
              SizedBox(width: 12),
              Expanded(child: Text(Fa.appName, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 20))),
              NotificationBell(),
            ],
          ),
          const SizedBox(height: 28),
          for (var i = 0; i < destinations.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: ListTile(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                selected: i == selected,
                leading: Icon(destinations[i].icon),
                title: Text(destinations[i].label),
                onTap: () => context.go(destinations[i].path),
              ),
            ),
          const Spacer(),
          Text(Fa.signature, style: TextStyle(color: palette.muted, fontSize: 12)),
        ],
      ),
    );
  }
}

class _Destination {
  const _Destination(this.label, this.icon, this.path);
  final String label;
  final IconData icon;
  final String path;
}
