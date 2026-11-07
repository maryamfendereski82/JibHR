import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/calendar/tehran_time.dart';
import '../../core/design_system/glass_card.dart';
import '../../core/design_system/state_views.dart';
import '../../core/localization/fa.dart';
import '../../core/theme/app_theme.dart';
import 'notification_repository.dart';
import 'notification_rules.dart';

const _categories = ['attendance', 'leave', 'absence', 'task', 'project', 'sprint', 'milestone'];

class NotificationBell extends ConsumerWidget {
  const NotificationBell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(notificationRealtimeProvider);
    final count = ref.watch(unreadCountProvider).asData?.value ?? 0;
    return IconButton(
      tooltip: Fa.inbox,
      onPressed: () => context.go('/notifications'),
      icon: Badge(
        isLabelVisible: count > 0,
        label: Text(persianDigits(count)),
        child: const Icon(Icons.notifications_outlined),
      ),
    );
  }
}

class InboxPage extends ConsumerStatefulWidget {
  const InboxPage({super.key});

  @override
  ConsumerState<InboxPage> createState() => _InboxPageState();
}

class _InboxPageState extends ConsumerState<InboxPage> {
  List<NotificationRow> _rows = [];
  int _total = 0;
  int _page = 0;
  String? _category;
  bool _unreadOnly = false;
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    Future.microtask(_reload);
  }

  bool _shows(NotificationRow row) {
    if (_unreadOnly && !row.unread) return false;
    if (_category != null && row.category != _category) return false;
    return true;
  }

  Future<void> _reload() async {
    final repo = ref.read(notificationRepositoryProvider);
    if (repo == null) return;
    setState(() {
      _loading = true;
      _error = null;
      _page = 0;
    });
    try {
      final result = await repo.page(category: _category, unreadOnly: _unreadOnly);
      if (!mounted) return;
      setState(() {
        _rows = applyInbox(result.rows, null, reconnect: true);
        _total = result.total;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _more() async {
    final repo = ref.read(notificationRepositoryProvider);
    if (repo == null) return;
    final next = _page + 1;
    try {
      final result = await repo.page(category: _category, unreadOnly: _unreadOnly, page: next);
      if (!mounted) return;
      setState(() {
        _rows = appendPage(_rows, result.rows);
        _total = result.total;
        _page = next;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    }
  }

  Future<void> _markAll() async {
    final repo = ref.read(notificationRepositoryProvider);
    if (repo == null) return;
    await repo.markAll();
    ref.invalidate(unreadCountProvider);
    final now = DateTime.now().toUtc();
    setState(() {
      _rows = [for (final row in _rows) row.unread ? row.copyRead(now) : row];
      if (_unreadOnly) _rows = [];
    });
  }

  Future<void> _open(NotificationRow row) async {
    final repo = ref.read(notificationRepositoryProvider);
    if (repo == null) return;
    if (row.unread) {
      await repo.markRead(row.id);
      ref.invalidate(unreadCountProvider);
      setState(() {
        _rows = [
          for (final item in _rows)
            if (item.id == row.id) item.copyRead(DateTime.now().toUtc()) else item,
        ];
      });
    }
    if (!mounted) return;
    final path = await repo.openPath(row);
    if (!mounted) return;
    final current = _rows.where((item) => item.id == row.id).firstOrNull ?? row;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(current.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(categoryLabel(current.category)),
            const SizedBox(height: 8),
            Text(current.body),
            const SizedBox(height: 8),
            Text(relativeNoticeTime(current.createdAt, DateTime.now().toUtc())),
            if (path == null) ...[
              const SizedBox(height: 12),
              const Text(Fa.notificationUnavailable),
            ],
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text(Fa.markRead)),
          if (path != null)
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                context.go(path);
              },
              child: const Text(Fa.openItem),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(inboxArrivalProvider, (_, next) {
      if (next == null || !_shows(next)) return;
      setState(() => _rows = applyInbox(_rows, next, reconnect: false));
    });
    ref.listen(inboxReconnectProvider, (_, _) => _reload());

    final palette = paletteOf(context);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            Expanded(child: Text(Fa.inbox, style: Theme.of(context).textTheme.headlineMedium)),
            TextButton(onPressed: _markAll, child: const Text(Fa.markAllRead)),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilterChip(
              label: const Text(Fa.allItems),
              selected: _category == null,
              onSelected: (_) {
                setState(() => _category = null);
                _reload();
              },
            ),
            for (final category in _categories)
              FilterChip(
                label: Text(categoryLabel(category)),
                selected: _category == category,
                onSelected: (_) {
                  setState(() => _category = _category == category ? null : category);
                  _reload();
                },
              ),
            FilterChip(
              label: const Text(Fa.unreadOnly),
              selected: _unreadOnly,
              onSelected: (value) {
                setState(() => _unreadOnly = value);
                _reload();
              },
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (_loading && _rows.isEmpty)
          const LoadingView()
        else if (_error != null && _rows.isEmpty)
          ErrorView(message: Fa.network, onRetry: _reload)
        else if (_rows.isEmpty)
          const EmptyView()
        else
          for (final row in _rows) ...[
            NotificationCard(
              row: row,
              now: DateTime.now().toUtc(),
              accent: row.unread ? palette.jade : palette.muted,
              onTap: () => _open(row),
            ),
            const SizedBox(height: 10),
          ],
        if (_rows.length < _total)
          Align(
            child: TextButton(onPressed: _more, child: const Text(Fa.loadMore)),
          ),
      ],
    );
  }
}

class NotificationCard extends StatelessWidget {
  const NotificationCard({
    super.key,
    required this.row,
    required this.now,
    required this.accent,
    this.onTap,
  });

  final NotificationRow row;
  final DateTime now;
  final Color accent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: InkWell(
        onTap: onTap,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(_icon(row.category), color: accent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(row.title, style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(row.body, maxLines: 2, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 6),
                  Text(
                    '${categoryLabel(row.category)} · ${relativeNoticeTime(row.createdAt, now)}',
                    style: TextStyle(color: accent, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

IconData _icon(String category) => switch (category) {
      'attendance' => Icons.schedule,
      'leave' => Icons.event_available_outlined,
      'absence' => Icons.event_busy_outlined,
      'task' => Icons.task_alt,
      'project' => Icons.account_tree_outlined,
      'sprint' => Icons.timelapse,
      'milestone' => Icons.flag_outlined,
      _ => Icons.notifications_outlined,
    };
