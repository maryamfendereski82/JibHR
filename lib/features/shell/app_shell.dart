import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/calendar/tehran_time.dart';
import '../../core/design_system/app_icons.dart';
import '../../core/design_system/state_views.dart';
import '../../core/localization/fa.dart';
import '../../core/networking/supabase_provider.dart';
import '../../core/offline/offline_cache.dart';
import '../../core/theme/app_theme.dart';
import '../notifications/notification_pages.dart';
import '../notifications/notification_repository.dart';
import '../reports/report_repository.dart';
import '../session/workspace_session.dart';
import 'navigation.dart';
import 'shell_scaffold.dart';

/// Large screens: whether the sidebar is shown in full or as a rail.
final sidebarExpandedProvider = NotifierProvider<SidebarExpanded, bool>(SidebarExpanded.new);

class SidebarExpanded extends Notifier<bool> {
  static const _key = 'sidebar_expanded';

  @override
  bool build() {
    _restore();
    return true;
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getBool(_key);
      if (saved != null) state = saved;
    } catch (_) {
      // Preference storage unavailable: keep the default.
    }
  }

  Future<void> set(bool value) async {
    state = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_key, value);
    } catch (_) {}
  }
}

class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.shell});

  /// The router's per-section navigators. Switching sections goes through
  /// [StatefulNavigationShell.goBranch], so each section keeps its own stack.
  final StatefulNavigationShell shell;

  void _navigate(String path, List<NavDestination> destinations) {
    final target = destinations.where((item) => item.path == path).firstOrNull;
    if (target == null) return;
    final index = branchIndexOf(target.id);
    // Choosing the section already open returns it to its first page.
    shell.goBranch(index, initialLocation: index == shell.currentIndex);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(connectionTickProvider);
    final hub = ref.watch(connectionHubProvider);
    final config = ref.watch(appConfigProvider);
    final sessionState = ref.watch(workspaceSessionProvider);
    final session = sessionState.asData?.value;
    // Only the first load hides the menu; a refresh keeps the known items.
    final navLoading = session == null && sessionState.isLoading;
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
        ref.invalidate(dashboardPersonalProvider);
        ref.invalidate(dashboardQueuesProvider);
        ref.invalidate(dashboardTeamProvider);
        ref.invalidate(dashboardProjectsProvider);
        ref.read(inboxReconnectProvider.notifier).bump();
      }
    });

    final palette = paletteOf(context);
    final destinations = navDestinations(session);
    final location = GoRouterState.of(context).uri.path;
    final stamp = hub.validatedAt == null ? Fa.neverSynced : TehranTime.formatDate(hub.validatedAt!);
    final fullName = session == null ? null : '${session.firstName} ${session.lastName}'.trim();

    return ShellScaffold(
      destinations: destinations,
      active: navLoading ? null : activeDestination(location, destinations),
      navLoading: navLoading,
      onNavigate: (path) => _navigate(path, destinations),
      bell: const NotificationBell(),
      railBell: const NotificationBell(materialTooltip: false),
      userName: fullName,
      userDetail: session?.teamName,
      sidebarExpanded: ref.watch(sidebarExpandedProvider),
      onSidebarExpanded: (value) => ref.read(sidebarExpandedProvider.notifier).set(value),
      notices: [
        if (config.showEnvironment)
          NoticeBar(message: '${Fa.environment}: ${config.environment}', tone: palette.info, subtle: true),
        if (hub.offline)
          NoticeBar(
            message: hub.locked ? Fa.offlineExpired : '${Fa.offlineBanner} $stamp. ${Fa.offlineStale}',
            tone: hub.locked ? palette.danger : palette.warning,
            icon: AppIcons.offline,
          ),
      ],
      child: shell,
    );
  }
}
