import 'package:flutter/material.dart';

import '../../core/design_system/app_icons.dart';
import '../../core/design_system/brand_mark.dart';
import '../../core/design_system/side_tooltip.dart';
import '../../core/design_system/state_views.dart';
import '../../core/design_system/surfaces.dart';
import '../../core/localization/fa.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/app_tokens.dart';
import 'navigation.dart';

/// Layout of the signed-in app: sidebar, rail or bottom bar around [child].
///
/// Pure layout: it knows nothing about Supabase or Riverpod, so it can be
/// tested at every width. [AppShell] feeds it.
class ShellScaffold extends StatefulWidget {
  const ShellScaffold({
    super.key,
    required this.destinations,
    required this.active,
    required this.onNavigate,
    required this.child,
    required this.bell,
    this.railBell,
    this.notices = const [],
    this.userName,
    this.userDetail,
    this.sidebarExpanded = true,
    this.onSidebarExpanded,
    this.navLoading = false,
  });

  /// The session (and so the permissions) is not known yet. Navigation keeps
  /// its exact geometry but shows placeholders instead of a partial menu.
  final bool navLoading;

  final List<NavDestination> destinations;
  final NavDestination? active;
  final ValueChanged<String> onNavigate;
  final Widget child;

  /// The notification button. Passed in so this widget stays provider-free.
  final Widget bell;

  /// The same button without Material's own tooltip, for the collapsed rail,
  /// where a side tooltip replaces it. Falls back to [bell].
  final Widget? railBell;

  /// Offline, environment and similar banners shown above the page.
  final List<Widget> notices;
  final String? userName;
  final String? userDetail;

  /// Large screens only: the person's choice between full sidebar and rail.
  final bool sidebarExpanded;
  final ValueChanged<bool>? onSidebarExpanded;

  @override
  State<ShellScaffold> createState() => _ShellScaffoldState();
}

class _ShellScaffoldState extends State<ShellScaffold> {
  /// Medium screens: the full sidebar shown over the content.
  bool _overlay = false;

  void _go(String path) {
    if (_overlay) setState(() => _overlay = false);
    widget.onNavigate(path);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = AppBreakpoints.of(constraints.maxWidth);
        final page = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ...widget.notices,
            Expanded(child: widget.child),
          ],
        );
        return switch (size) {
          SizeClass.compact => _compact(page),
          SizeClass.medium || SizeClass.expanded => _medium(page),
          SizeClass.large => _large(page),
        };
      },
    );
  }

  Widget _compact(Widget page) {
    final split = splitForBottomBar(widget.destinations);
    return AppCanvas(
      child: Scaffold(
        key: const Key('shell-compact'),
        backgroundColor: Colors.transparent,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              _Header(title: widget.active?.label ?? Fa.appName, bell: widget.bell, showBrand: true),
              Expanded(child: page),
            ],
          ),
        ),
        bottomNavigationBar: _BottomBar(
          loading: widget.navLoading,
          items: split.bar,
          overflow: split.overflow,
          active: widget.active,
          onNavigate: _go,
        ),
      ),
    );
  }

  Widget _medium(Widget page) {
    return AppCanvas(
      child: Scaffold(
        key: const Key('shell-medium'),
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Stack(
            children: [
              Row(
                children: [
                  _Sidebar(
                    expanded: false,
                    showBell: false,
                    destinations: widget.destinations,

                    loading: widget.navLoading,
                    active: widget.active,
                    onNavigate: _go,
                    bell: widget.bell,
                    userName: widget.userName,
                    userDetail: widget.userDetail,
                    onToggle: () => setState(() => _overlay = true),
                  ),
                  Expanded(
                    child: Column(
                      children: [
                        _Header(title: widget.active?.label ?? Fa.appName, bell: widget.bell),
                        Expanded(child: page),
                      ],
                    ),
                  ),
                ],
              ),
              if (_overlay) ...[
                Positioned.fill(
                  child: GestureDetector(
                    key: const Key('shell-scrim'),
                    onTap: () => setState(() => _overlay = false),
                    child: ColoredBox(color: paletteOf(context).scrim),
                  ),
                ),
                PositionedDirectional(
                  start: 0,
                  top: 0,
                  bottom: 0,
                  child: _Sidebar(
                    expanded: true,
                    destinations: widget.destinations,

                    loading: widget.navLoading,
                    active: widget.active,
                    onNavigate: _go,
                    bell: widget.bell,
                    userName: widget.userName,
                    userDetail: widget.userDetail,
                    onToggle: () => setState(() => _overlay = false),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _large(Widget page) {
    return AppCanvas(
      child: Scaffold(
        key: const Key('shell-large'),
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Row(
            children: [
              _Sidebar(
                expanded: widget.sidebarExpanded,
                destinations: widget.destinations,

                loading: widget.navLoading,
                active: widget.active,
                onNavigate: _go,
                bell: widget.bell,
                railBell: widget.railBell,
                userName: widget.userName,
                userDetail: widget.userDetail,
                onToggle: widget.onSidebarExpanded == null ? null : () => widget.onSidebarExpanded!(!widget.sidebarExpanded),
              ),
              Expanded(child: page),
            ],
          ),
        ),
      ),
    );
  }
}

String _groupLabel(NavGroup group) => switch (group) {
      NavGroup.daily => Fa.navDaily,
      NavGroup.insight => Fa.navInsight,
      NavGroup.account => Fa.navAccount,
    };

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.expanded,
    required this.destinations,
    required this.active,
    required this.onNavigate,
    required this.bell,
    this.userName,
    this.userDetail,
    this.onToggle,
    this.showBell = true,
    this.railBell,
    this.loading = false,
  });

  /// Permissions not known yet: placeholders instead of a partial menu.
  final bool loading;

  /// False where a header already shows the bell.
  final bool showBell;

  /// The bell without its own tooltip, for the rail's side tooltip.
  final Widget? railBell;
  final bool expanded;
  final List<NavDestination> destinations;
  final NavDestination? active;
  final ValueChanged<String> onNavigate;
  final Widget bell;
  final String? userName;
  final String? userDetail;
  final VoidCallback? onToggle;

  static const expandedWidth = 264.0;
  static const railWidth = 76.0;

  /// The shape of a full menu (4 daily items, one insight, two account) at
  /// the real item height, so nothing moves when the real items arrive.
  List<Widget> _placeholders(BuildContext context) {
    Widget item() => Padding(
          padding: const EdgeInsets.only(bottom: AppSpace.xs),
          child: SizedBox(
            height: 44,
            child: Row(
              mainAxisAlignment: expanded ? MainAxisAlignment.start : MainAxisAlignment.center,
              children: [
                if (expanded) const SizedBox(width: AppSpace.m),
                const SkeletonBlock(width: 24, height: 24, radius: AppRadius.chip),
                if (expanded) ...[const SizedBox(width: AppSpace.m), const SkeletonBlock(width: 96, height: 14)],
              ],
            ),
          ),
        );
    Widget gap() => expanded
        ? const Padding(
            padding: EdgeInsetsDirectional.only(start: AppSpace.m, top: AppSpace.l, bottom: AppSpace.s),
            child: Align(alignment: AlignmentDirectional.centerStart, child: SkeletonBlock(width: 56, height: 10)),
          )
        : const SizedBox(height: AppSpace.l);
    return [
      KeyedSubtree(key: const Key('nav-loading'), child: gap()),
      for (var i = 0; i < 4; i++) item(),
      gap(),
      item(),
      gap(),
      item(),
      item(),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    final groups = <NavGroup, List<NavDestination>>{};
    for (final item in destinations) {
      groups.putIfAbsent(item.group, () => []).add(item);
    }
    final children = <Widget>[];
    if (loading) children.addAll(_placeholders(context));
    var first = true;
    for (final entry in loading ? const <MapEntry<NavGroup, List<NavDestination>>>[] : groups.entries) {
      if (!first) children.add(const SizedBox(height: AppSpace.l));
      if (expanded) {
        children.add(Padding(
          padding: const EdgeInsetsDirectional.only(start: AppSpace.m, bottom: AppSpace.xs),
          child: Text(_groupLabel(entry.key), style: text.labelSmall?.copyWith(color: p.muted)),
        ));
      } else if (!first) {
        children.add(Divider(indent: AppSpace.l, endIndent: AppSpace.l, color: p.hairline));
        children.add(const SizedBox(height: AppSpace.s));
      }
      for (final item in entry.value) {
        children.add(Padding(
          padding: const EdgeInsets.only(bottom: AppSpace.xs),
          child: _NavItem(
            destination: item,
            selected: item == active,
            expanded: expanded,
            onTap: () => onNavigate(item.path),
          ),
        ));
      }
      first = false;
    }

    return AnimatedContainer(
      duration: AppMotion.of(context, AppMotion.state),
      curve: AppMotion.enter,
      width: expanded ? expandedWidth : railWidth,
      decoration: BoxDecoration(border: BorderDirectional(end: BorderSide(color: p.hairline))),
      child: AppSurface(
        level: SurfaceLevel.deep,
        radius: 0,
        shadow: false,
        border: false,
        padding: EdgeInsets.symmetric(horizontal: expanded ? AppSpace.m : AppSpace.s, vertical: AppSpace.l),
        child: Semantics(
          container: true,
          label: Fa.mainNavigation,
          explicitChildNodes: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _brandRow(context),
              const SizedBox(height: AppSpace.xxl),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
                ),
              ),
              const SizedBox(height: AppSpace.m),
              if (!expanded && showBell) Center(child: SideTooltip(message: Fa.inbox, child: railBell ?? bell)),
              if (userName != null) ...[
                const SizedBox(height: AppSpace.s),
                _UserCard(name: userName!, detail: userDetail, expanded: expanded, bell: expanded ? bell : null),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _brandRow(BuildContext context) {
    final label = expanded ? Fa.sidebarCollapse : Fa.sidebarExpand;
    final toggle = onToggle == null
        ? null
        : SideTooltip(
            message: label,
            child: IconButton(
              key: const Key('sidebar-toggle'),
              onPressed: onToggle,
              icon: AppIconView(expanded ? AppIcons.sidebarCollapse : AppIcons.sidebarExpand, semanticLabel: label),
            ),
          );
    if (!expanded) {
      return Column(
        children: [
          const BrandMark(size: 40),
          if (toggle != null) ...[const SizedBox(height: AppSpace.s), toggle],
        ],
      );
    }
    return Row(
      children: [
        const BrandMark(size: 36),
        const SizedBox(width: AppSpace.m),
        Expanded(
          child: Text(Fa.appName, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        ),
        ?toggle,
      ],
    );
  }
}

class _NavItem extends StatefulWidget {
  const _NavItem({required this.destination, required this.selected, required this.expanded, required this.onTap});

  final NavDestination destination;
  final bool selected;
  final bool expanded;
  final VoidCallback onTap;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _hover = false;
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final scheme = Theme.of(context).colorScheme;
    final selected = widget.selected;
    final background = selected
        ? scheme.primaryContainer
        : _hover
            ? p.ink.withValues(alpha: 0.05)
            : Colors.transparent;
    final label = Text(
      widget.destination.label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? p.ink : p.muted,
          ),
    );
    final icon = AppIconView(
      widget.destination.icon,
      selected: selected,
      size: AppIconSize.nav,
      color: selected ? p.jade : p.muted,
    );
    final content = SizedBox(
      height: 44,
      child: Stack(
        children: [
          if (selected)
            PositionedDirectional(
              start: 0,
              top: 10,
              bottom: 10,
              child: Container(
                width: 3,
                decoration: BoxDecoration(color: p.jade, borderRadius: BorderRadius.circular(2)),
              ),
            ),
          Positioned.fill(
            child: Padding(
              padding: EdgeInsetsDirectional.only(start: widget.expanded ? AppSpace.m : 0),
              child: widget.expanded
                  ? Row(children: [icon, const SizedBox(width: AppSpace.m), Expanded(child: label)])
                  : Center(child: icon),
            ),
          ),
        ],
      ),
    );
    final item = Semantics(
      button: true,
      selected: selected,
      label: widget.destination.label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: ValueKey('nav-${widget.destination.id}'),
          borderRadius: BorderRadius.circular(AppRadius.control),
          onTap: widget.onTap,
          onHover: (value) => setState(() => _hover = value),
          onFocusChange: (value) => setState(() => _focus = value),
          child: AnimatedContainer(
            duration: AppMotion.of(context, AppMotion.state),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(AppRadius.control),
              border: Border.all(color: _focus ? p.jade : Colors.transparent, width: 2),
            ),
            child: ExcludeSemantics(child: content),
          ),
        ),
      ),
    );
    if (widget.expanded) return item;
    // The item already carries its label; the tooltip is for sighted users only.
    return SideTooltip(message: widget.destination.label, child: item);
  }
}

class _UserCard extends StatelessWidget {
  const _UserCard({required this.name, required this.expanded, this.detail, this.bell});

  final String name;
  final String? detail;
  final bool expanded;
  final Widget? bell;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final initial = name.trim().isEmpty ? '؟' : name.trim().characters.first;
    final avatar = CircleAvatar(
      radius: 18,
      backgroundColor: Color.alphaBlend(p.jade.withValues(alpha: 0.18), p.surface),
      child: Text(initial, style: TextStyle(color: p.ink, fontWeight: FontWeight.w700)),
    );
    if (!expanded) {
      return Center(child: SideTooltip(message: name, child: Semantics(label: name, child: avatar)));
    }
    return Container(
      padding: const EdgeInsets.all(AppSpace.s),
      decoration: BoxDecoration(
        color: p.ink.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(AppRadius.control),
      ),
      child: Row(
        children: [
          avatar,
          const SizedBox(width: AppSpace.s),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.labelLarge),
                if (detail != null && detail!.isNotEmpty)
                  Text(detail!, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          ?bell,
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.title, required this.bell, this.showBrand = false});

  final String title;
  final Widget bell;
  final bool showBrand;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Container(
      height: 56,
      padding: const EdgeInsetsDirectional.only(start: AppSpace.l, end: AppSpace.s),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: p.hairline))),
      child: Row(
        children: [
          if (showBrand) ...[const BrandMark(size: 28), const SizedBox(width: AppSpace.m)],
          Expanded(
            child: Semantics(
              header: true,
              child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleLarge),
            ),
          ),
          bell,
        ],
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.items, required this.overflow, required this.active, required this.onNavigate, this.loading = false});

  final bool loading;

  final List<NavDestination> items;
  final List<NavDestination> overflow;
  final NavDestination? active;
  final ValueChanged<String> onNavigate;

  @override
  Widget build(BuildContext context) {
    final moreSelected = active != null && overflow.contains(active);
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(AppSpace.m, 0, AppSpace.m, AppSpace.m),
      child: AppSurface(
        level: SurfaceLevel.glass,
        radius: AppRadius.pill,
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.xs, vertical: AppSpace.xs),
        child: Semantics(
          container: true,
          label: Fa.mainNavigation,
          explicitChildNodes: true,
          child: SizedBox(
            height: 60,
            child: Row(
              children: [
                if (loading)
                  for (var i = 0; i < 5; i++)
                    Expanded(
                      key: i == 0 ? const Key('nav-loading') : null,
                      child: const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SkeletonBlock(width: 22, height: 22, radius: AppRadius.chip),
                          SizedBox(height: 6),
                          SkeletonBlock(width: 34, height: 10),
                        ],
                      ),
                    ),
                for (final item in loading ? const <NavDestination>[] : items)
                  Expanded(
                    child: _BarItem(
                      key: ValueKey('nav-${item.id}'),
                      label: item.label,
                      icon: item.icon,
                      selected: item == active,
                      onTap: () => onNavigate(item.path),
                    ),
                  ),
                if (overflow.isNotEmpty && !loading)
                  Expanded(
                    child: _BarItem(
                      key: const ValueKey('nav-more'),
                      label: Fa.navMore,
                      icon: AppIcons.more,
                      selected: moreSelected,
                      onTap: () => _openMore(context),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openMore(BuildContext context) async {
    final p = paletteOf(context);
    final path = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppSpace.l, 0, AppSpace.l, AppSpace.l),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final item in overflow)
                ListTile(
                  key: ValueKey('more-${item.id}'),
                  selected: item == active,
                  leading: AppIconView(item.icon, selected: item == active, color: item == active ? p.jade : p.muted),
                  title: Text(item.label),
                  onTap: () => Navigator.pop(context, item.path),
                ),
            ],
          ),
        ),
      ),
    );
    if (path != null) onNavigate(path);
  }
}

class _BarItem extends StatelessWidget {
  const _BarItem({super.key, required this.label, required this.icon, required this.selected, required this.onTap});

  final String label;
  final AppIcon icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.panel),
        onTap: onTap,
        child: ExcludeSemantics(child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedContainer(
              duration: AppMotion.of(context, AppMotion.state),
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.m, vertical: 3),
              decoration: BoxDecoration(
                color: selected ? scheme.primaryContainer : Colors.transparent,
                borderRadius: BorderRadius.circular(AppRadius.control),
              ),
              child: AppIconView(icon, selected: selected, size: 22, color: selected ? p.jade : p.muted),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: selected ? p.ink : p.muted,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
            ),
          ],
        )),
      ),
    );
  }
}
