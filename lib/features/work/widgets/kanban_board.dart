import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/calendar/tehran_time.dart';
import '../../../core/design_system/app_icons.dart';
import '../../../core/design_system/state_views.dart';
import '../../../core/localization/fa.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../task_board.dart';
import '../work_repository.dart';
import '../work_rules.dart';
import '../workflow_presentation.dart';
import 'task_card.dart';
import 'work_ui.dart';

/// Touch devices start a drag with a long press, so a normal swipe always
/// scrolls the board. Mouse and pen drag immediately.
bool get touchFirstPlatform => defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;

/// The board's horizontal position, for controls that live outside the
/// board (the page toolbar). [overflow] is true only while some columns are
/// out of view; the toolbar shows its arrows only then, disabled at the ends.
class KanbanNav extends ChangeNotifier {
  bool _overflow = false;
  bool _canBack = false;
  bool _canForward = false;
  VoidCallback? _back;
  VoidCallback? _forward;

  bool get overflow => _overflow;
  bool get canBack => _canBack;
  bool get canForward => _canForward;

  void back() => _back?.call();
  void forward() => _forward?.call();

  void _update({required bool overflow, required bool canBack, required bool canForward}) {
    if (overflow == _overflow && canBack == _canBack && canForward == _canForward) return;
    _overflow = overflow;
    _canBack = canBack;
    _canForward = canForward;
    notifyListeners();
  }
}

class KanbanBoard extends StatefulWidget {
  const KanbanBoard({
    super.key,
    required this.statuses,
    required this.flow,
    required this.filterFor,
    required this.onPage,
    required this.onOpen,
    required this.onMove,
    required this.now,
    this.selectedId,
    this.busy = false,
    this.nav,
    this.onCreate,
    this.canDrop,
    this.actionsFor,
    this.onAction,
  });

  final List<StatusRow> statuses;
  final WorkflowRow? flow;
  final TaskFilter Function(String statusId) filterFor;
  final void Function(String statusId, int page) onPage;
  final ValueChanged<String> onOpen;
  final void Function(TaskRow task, StatusRow target) onMove;
  final DateTime now;
  final String? selectedId;
  final bool busy;
  final KanbanNav? nav;

  /// Create action for the first (starting) column's empty state. Null when
  /// the viewer may not create tasks here.
  final VoidCallback? onCreate;

  /// Whether a card may be dropped on a column (an allowed action); a drop
  /// then calls [onMove] with the column. Null refuses every drop.
  final bool Function(TaskRow task, StatusRow column)? canDrop;

  /// The actions a card's menu offers, and what choosing one does.
  final List<TaskAction> Function(TaskRow task)? actionsFor;
  final void Function(TaskRow task, TaskAction action)? onAction;

  @override
  State<KanbanBoard> createState() => _KanbanBoardState();
}

/// Desktop and tablet geometry: as many whole columns as fit, each between
/// [kanbanMinColumn] and [kanbanMaxColumn] wide, so no column is ever cut
/// at an edge; the rest scroll, snapping one whole column at a time.
const kanbanMinColumn = 272.0;
const kanbanMaxColumn = 340.0;
const kanbanGap = 12.0;

({int visible, double width}) kanbanGeometry(double available, int count) {
  if (count <= 0) return (visible: 0, width: kanbanMinColumn);
  final visible = ((available + kanbanGap) / (kanbanMinColumn + kanbanGap)).floor().clamp(1, count);
  final width = (available - (visible - 1) * kanbanGap) / visible;
  if (visible == count) return (visible: visible, width: width.clamp(kanbanMinColumn, kanbanMaxColumn).toDouble());
  return (visible: visible, width: width);
}

class _KanbanBoardState extends State<KanbanBoard> {
  final _pages = PageController();
  final _scroll = ScrollController();
  int _current = 0;
  double _extent = kanbanMinColumn + kanbanGap;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_report);
    widget.nav?._back = () => _step(-1);
    widget.nav?._forward = () => _step(1);
  }

  @override
  void didUpdateWidget(KanbanBoard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.nav != widget.nav) {
      oldWidget.nav?._update(overflow: false, canBack: false, canForward: false);
      widget.nav?._back = () => _step(-1);
      widget.nav?._forward = () => _step(1);
    }
  }

  @override
  void dispose() {
    widget.nav?._back = null;
    widget.nav?._forward = null;
    // The board is gone: its toolbar arrows go with it (after this frame).
    final nav = widget.nav;
    WidgetsBinding.instance.addPostFrameCallback((_) => nav?._update(overflow: false, canBack: false, canForward: false));
    _scroll.removeListener(_report);
    _pages.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Tells the toolbar whether columns are hidden and which way it can go.
  void _report() {
    final nav = widget.nav;
    if (nav == null) return;
    if (!_scroll.hasClients || !_scroll.position.hasContentDimensions) {
      nav._update(overflow: false, canBack: false, canForward: false);
      return;
    }
    final position = _scroll.position;
    final overflow = position.maxScrollExtent > 0.5;
    nav._update(overflow: overflow, canBack: overflow && position.pixels > position.minScrollExtent + 0.5, canForward: overflow && position.pixels < position.maxScrollExtent - 0.5);
  }

  void _step(int delta) {
    if (!_scroll.hasClients) return;
    final current = (_scroll.offset / _extent).round();
    final target = ((current + delta) * _extent).clamp(0.0, _scroll.position.maxScrollExtent);
    _scroll.animateTo(target, duration: AppMotion.of(context, AppMotion.panel), curve: AppMotion.enter);
  }

  /// Dragging a column header with a mouse pans the board (cards keep their
  /// own drag-to-move). RTL: content follows the pointer.
  void _pan(double dx) {
    if (!_scroll.hasClients) return;
    final sign = Directionality.of(context) == TextDirection.rtl ? 1.0 : -1.0;
    _scroll.jumpTo((_scroll.offset + sign * dx).clamp(0.0, _scroll.position.maxScrollExtent));
  }

  void _settle() {
    if (!_scroll.hasClients) return;
    final target = ((_scroll.offset / _extent).round() * _extent).clamp(0.0, _scroll.position.maxScrollExtent);
    _scroll.animateTo(target, duration: AppMotion.of(context, AppMotion.state), curve: AppMotion.enter);
  }

  /// A vertical mouse wheel over a header scrolls the board sideways.
  void _wheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_scroll.hasClients) return;
    final delta = event.scrollDelta.dx.abs() > event.scrollDelta.dy.abs() ? event.scrollDelta.dx : event.scrollDelta.dy;
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      _scroll.jumpTo((_scroll.offset + delta).clamp(0.0, _scroll.position.maxScrollExtent));
    });
  }

  Widget _column(StatusRow status, double width, {required bool first, required bool pans}) => SizedBox(
    width: width,
    child: _KanbanColumn(
      key: ValueKey('column-${status.id}'),
      status: status,
      flow: widget.flow,
      filter: widget.filterFor(status.id),
      onPage: (page) => widget.onPage(status.id, page),
      onOpen: widget.onOpen,
      onMove: widget.onMove,
      now: widget.now,
      selectedId: widget.selectedId,
      busy: widget.busy,
      onCreate: first ? widget.onCreate : null,
      canDrop: widget.canDrop,
      actionsFor: widget.actionsFor,
      onAction: widget.onAction,
      onHeaderPan: pans ? _pan : null,
      onHeaderPanEnd: pans ? _settle : null,
      onHeaderWheel: pans ? _wheel : null,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final statuses = widget.statuses;
    final p = paletteOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        if (width < 600) {
          // Phone: one whole column per page, snapping; a status strip on top.
          WidgetsBinding.instance.addPostFrameCallback((_) => widget.nav?._update(overflow: false, canBack: false, canForward: false));
          return Column(
            children: [
              SizedBox(
                height: 44,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: AppSpace.l),
                  itemCount: statuses.length,
                  separatorBuilder: (_, _) => const SizedBox(width: AppSpace.s),
                  itemBuilder: (context, i) {
                    final s = statuses[i];
                    final selected = i == _current;
                    return ChoiceChip(
                      key: ValueKey('jump-${s.id}'),
                      selected: selected,
                      showCheckmark: false,
                      avatar: AppIconView(categoryIcon(s.category), size: 14, color: statusTone(p, s.category)),
                      label: Text(s.name),
                      onSelected: (_) {
                        setState(() => _current = i);
                        _pages.animateToPage(i, duration: AppMotion.of(context, AppMotion.panel), curve: AppMotion.enter);
                      },
                    );
                  },
                ),
              ),
              Expanded(
                child: PageView.builder(
                  controller: _pages,
                  itemCount: statuses.length,
                  onPageChanged: (i) => setState(() => _current = i),
                  itemBuilder: (context, i) => Padding(
                    padding: const EdgeInsets.fromLTRB(AppSpace.l, AppSpace.s, AppSpace.l, AppSpace.l),
                    child: Align(alignment: Alignment.topCenter, child: _column(statuses[i], double.infinity, first: i == 0, pans: false)),
                  ),
                ),
              ),
            ],
          );
        }
        final gutter = width < 1024 ? AppSpace.xxl : AppSpace.x3;
        final geometry = kanbanGeometry(width - gutter * 2, statuses.length);
        _extent = geometry.width + kanbanGap;
        final scrolls = geometry.visible < statuses.length;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _report();
        });
        // Keyboard: left and right arrows move a column when the board has focus.
        final board = Focus(
          canRequestFocus: scrolls,
          skipTraversal: !scrolls,
          onKeyEvent: (node, event) {
            if (!scrolls || event is! KeyDownEvent) return KeyEventResult.ignored;
            final rtl = Directionality.of(context) == TextDirection.rtl;
            if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
              _step(rtl ? 1 : -1);
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
              _step(rtl ? -1 : 1);
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          // The viewport is exactly the content width (gutters outside, clipped),
          // so whole columns fill it and the next one never peeks in a gutter.
          child: ListView.separated(
            key: const Key('kanban'),
            controller: _scroll,
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.hardEdge,
            physics: scrolls ? _ColumnSnapPhysics(extent: _extent) : const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.only(top: AppSpace.xs, bottom: AppSpace.l),
            itemCount: statuses.length,
            separatorBuilder: (_, _) => const SizedBox(width: kanbanGap),
            itemBuilder: (context, i) => Align(alignment: Alignment.topCenter, child: _column(statuses[i], geometry.width, first: i == 0, pans: scrolls)),
          ),
        );
        return Padding(
          padding: EdgeInsets.symmetric(horizontal: gutter),
          child: scrolls ? Scrollbar(controller: _scroll, child: board) : board,
        );
      },
    );
  }
}

/// Settles a horizontal scroll on a whole column.
class _ColumnSnapPhysics extends ScrollPhysics {
  const _ColumnSnapPhysics({required this.extent, super.parent});

  final double extent;

  @override
  _ColumnSnapPhysics applyTo(ScrollPhysics? ancestor) => _ColumnSnapPhysics(extent: extent, parent: buildParent(ancestor));

  double _target(ScrollMetrics position, double velocity) {
    var page = position.pixels / extent;
    if (velocity < -toleranceFor(position).velocity) {
      page -= 0.5;
    } else if (velocity > toleranceFor(position).velocity) {
      page += 0.5;
    }
    return (page.roundToDouble() * extent).clamp(position.minScrollExtent, position.maxScrollExtent);
  }

  @override
  Simulation? createBallisticSimulation(ScrollMetrics position, double velocity) {
    if ((velocity <= 0.0 && position.pixels <= position.minScrollExtent) || (velocity >= 0.0 && position.pixels >= position.maxScrollExtent)) {
      return super.createBallisticSimulation(position, velocity);
    }
    final tolerance = toleranceFor(position);
    final target = _target(position, velocity);
    if ((target - position.pixels).abs() < tolerance.distance) return null;
    return ScrollSpringSimulation(spring, position.pixels, target, velocity, tolerance: tolerance);
  }

  @override
  bool get allowImplicitScrolling => false;
}

class _KanbanColumn extends ConsumerWidget {
  const _KanbanColumn({
    super.key,
    required this.status,
    required this.flow,
    required this.filter,
    required this.onPage,
    required this.onOpen,
    required this.onMove,
    required this.now,
    required this.selectedId,
    required this.busy,
    this.onCreate,
    this.canDrop,
    this.actionsFor,
    this.onAction,
    this.onHeaderPan,
    this.onHeaderPanEnd,
    this.onHeaderWheel,
  });

  final StatusRow status;
  final WorkflowRow? flow;
  final TaskFilter filter;
  final ValueChanged<int> onPage;
  final ValueChanged<String> onOpen;
  final void Function(TaskRow task, StatusRow target) onMove;
  final DateTime now;
  final String? selectedId;
  final bool busy;
  final VoidCallback? onCreate;
  final bool Function(TaskRow task, StatusRow column)? canDrop;
  final List<TaskAction> Function(TaskRow task)? actionsFor;
  final void Function(TaskRow task, TaskAction action)? onAction;
  final ValueChanged<double>? onHeaderPan;
  final VoidCallback? onHeaderPanEnd;
  final ValueChanged<PointerSignalEvent>? onHeaderWheel;

  bool _allowed(TaskRow task) => canDrop?.call(task, status) ?? false;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    final page = ref.watch(taskPageProvider(filter));
    final tone = statusTone(p, status.category);
    return DragTarget<TaskRow>(
      onWillAcceptWithDetails: (details) => !busy && _allowed(details.data),
      onAcceptWithDetails: (details) => onMove(details.data, status),
      builder: (context, candidates, rejected) {
        final accepting = candidates.isNotEmpty;
        final refusing = rejected.isNotEmpty && rejected.first != null && groupKey(groupOf(rejected.first!)) != status.id;
        Widget header = Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(AppSpace.m, AppSpace.m, AppSpace.m, AppSpace.s),
          child: Row(
            children: [
              ToneIcon(icon: categoryIcon(status.category), tone: tone, size: 26),
              const SizedBox(width: AppSpace.s),
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    status.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
              if (page.hasValue)
                Semantics(
                  label: '${persianDigits(page.value!.total)} تسک',
                  excludeSemantics: true,
                  child: Container(
                    key: ValueKey('column-count-${status.id}'),
                    constraints: const BoxConstraints(minWidth: 26),
                    padding: const EdgeInsets.symmetric(horizontal: AppSpace.s, vertical: 1),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: p.surface, borderRadius: BorderRadius.circular(999), border: Border.all(color: p.stroke)),
                    child: Text(
                      persianDigits(page.value!.total),
                      style: text.labelMedium?.copyWith(fontWeight: FontWeight.w700, color: p.ink, fontFeatures: const [FontFeature.tabularFigures()]),
                    ),
                  ),
                ),
            ],
          ),
        );
        if (onHeaderPan != null) {
          header = Listener(
            onPointerSignal: onHeaderWheel,
            child: MouseRegion(
              cursor: SystemMouseCursors.grab,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: (details) => onHeaderPan!(details.delta.dx),
                onHorizontalDragEnd: (_) => onHeaderPanEnd?.call(),
                child: header,
              ),
            ),
          );
        }
        return AnimatedContainer(
          key: ValueKey('column-body-${status.id}'),
          duration: AppMotion.of(context, AppMotion.state),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: accepting ? Color.alphaBlend(p.jade.withValues(alpha: 0.07), p.surfaceRaised) : p.surfaceRaised,
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(color: accepting ? p.jade : (refusing ? p.danger : p.stroke), width: accepting || refusing ? 1.5 : 1),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Status accent: a slim bar on top, the column's only colour.
              Container(key: ValueKey('column-accent-${status.id}'), height: 3, color: tone.withValues(alpha: 0.85)),
              header,
              if (refusing)
                Padding(
                  padding: const EdgeInsets.fromLTRB(AppSpace.m, 0, AppSpace.m, AppSpace.xs),
                  child: Text(Fa.moveNotAllowed, style: text.bodySmall?.copyWith(color: p.danger)),
                ),
              Flexible(
                child: page.when(
                  skipLoadingOnReload: true,
                  loading: () => const Padding(
                    padding: EdgeInsets.fromLTRB(AppSpace.s, AppSpace.xs, AppSpace.s, AppSpace.s),
                    child: Column(
                      children: [
                        SkeletonBlock(height: 104, radius: AppRadius.control),
                        SizedBox(height: AppSpace.s),
                        SkeletonBlock(height: 104, radius: AppRadius.control),
                      ],
                    ),
                  ),
                  error: (error, _) => Padding(
                    padding: const EdgeInsets.all(AppSpace.m),
                    child: InlineError(message: taskErrorText(error), onRetry: () => ref.invalidate(taskPageProvider(filter))),
                  ),
                  data: (result) {
                    if (result.tasks.isEmpty) {
                      return _ColumnEmpty(key: ValueKey('column-empty-${status.id}'), category: status.category, accepting: accepting, onCreate: onCreate);
                    }
                    final pages = (result.total / taskPageSize).ceil();
                    return ListView.separated(
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(AppSpace.s, AppSpace.xs, AppSpace.s, AppSpace.s),
                      itemCount: result.tasks.length + (pages > 1 ? 1 : 0),
                      separatorBuilder: (_, _) => const SizedBox(height: AppSpace.s),
                      itemBuilder: (context, i) {
                        if (i == result.tasks.length) {
                          return MiniPager(page: filter.page, pages: pages, onPage: onPage);
                        }
                        final task = result.tasks[i];
                        return _DraggableCard(
                          key: ValueKey('drag-${task.id}'),
                          task: task,
                          child: TaskCard(
                            task: task,
                            now: now,
                            selected: task.id == selectedId,
                            onOpen: () => onOpen(task.id),
                            actions: actionsFor?.call(task) ?? const [],
                            onAction: busy || onAction == null ? null : (action) => onAction!(task, action),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// A quiet empty column: a small icon and a short line, no inner box. The
/// starting column offers "new task" to people who may create one.
class _ColumnEmpty extends StatelessWidget {
  const _ColumnEmpty({super.key, required this.category, required this.accepting, this.onCreate});

  final String category;
  final bool accepting;
  final VoidCallback? onCreate;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(AppSpace.m, 0, AppSpace.m, AppSpace.m),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              AppIconView(accepting ? AppIcons.add : AppIcons.empty, size: 16, color: accepting ? p.jade : p.muted),
              const SizedBox(width: AppSpace.s),
              Flexible(
                child: Text(accepting ? Fa.dropHere : columnEmptyText(category), style: text.bodySmall?.copyWith(color: accepting ? p.jade : p.muted)),
              ),
            ],
          ),
          if (onCreate != null && !accepting)
            Padding(
              padding: const EdgeInsets.only(top: AppSpace.xs),
              child: TextButton.icon(
                key: const Key('column-create'),
                onPressed: onCreate,
                style: TextButton.styleFrom(minimumSize: const Size(0, 36), padding: const EdgeInsets.symmetric(horizontal: AppSpace.s)),
                icon: const AppIconView(AppIcons.add, size: 16),
                label: const Text(Fa.newTask),
              ),
            ),
        ],
      ),
    );
  }
}

class _DraggableCard extends StatelessWidget {
  const _DraggableCard({super.key, required this.task, required this.child});

  final TaskRow task;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final feedback = Material(
          color: Colors.transparent,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: constraints.maxWidth.isFinite ? constraints.maxWidth : 280),
            child: Transform.rotate(angle: -0.02, child: Opacity(opacity: 0.95, child: child)),
          ),
        );
        final ghost = Opacity(opacity: 0.35, child: child);
        if (touchFirstPlatform) {
          return LongPressDraggable<TaskRow>(data: task, feedback: feedback, childWhenDragging: ghost, child: child);
        }
        return Draggable<TaskRow>(data: task, feedback: feedback, childWhenDragging: ghost, child: child);
      },
    );
  }
}

/// Compact previous/next with "page / pages", for columns and lists.
class MiniPager extends StatelessWidget {
  const MiniPager({super.key, required this.page, required this.pages, required this.onPage});

  final int page;
  final int pages;
  final ValueChanged<int> onPage;

  @override
  Widget build(BuildContext context) {
    // A single page (or none) needs no pager: never "1 / 1".
    if (pages <= 1) return const SizedBox.shrink();
    final p = paletteOf(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          tooltip: Fa.previousPage,
          onPressed: page > 0 ? () => onPage(page - 1) : null,
          icon: AppIconView(AppIcons.previous, color: p.muted, semanticLabel: Fa.previousPage),
        ),
        Text('${persianDigits(page + 1)} / ${persianDigits(pages)}', style: Theme.of(context).textTheme.labelMedium),
        IconButton(
          tooltip: Fa.nextPage,
          onPressed: page + 1 < pages ? () => onPage(page + 1) : null,
          icon: AppIconView(AppIcons.next, color: p.muted, semanticLabel: Fa.nextPage),
        ),
      ],
    );
  }
}
