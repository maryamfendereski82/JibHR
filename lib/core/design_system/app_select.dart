import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../localization/fa.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import 'app_icons.dart';

/// One choice of an [AppSelectField].
@immutable
class AppSelectOption<T> {
  const AppSelectOption({required this.value, required this.label, this.subtitle, this.leading, this.enabled = true, this.searchText});

  final T value;
  final String label;

  /// Helper line, e.g. team or role, to tell similar names apart.
  final String? subtitle;
  final Widget? leading;
  final bool enabled;

  /// Extra words matched by the search box (label and subtitle always are).
  final String? searchText;

  bool matches(String query) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return true;
    return '$label ${subtitle ?? ''} ${searchText ?? ''}'.toLowerCase().contains(needle);
  }
}

/// The single select of the app: a field that opens an anchored menu on
/// wide screens and a bottom sheet on phones.
///
/// States: hover, focus, open, selected, disabled ([onChanged] null),
/// loading, load error (with retry), empty, and a validation [errorText].
/// The menu opens where there is room (below or above), never past the
/// screen edge, scrolls inside a bounded height, filters with a search box
/// when the list is long, and works with the keyboard: arrows move, Enter
/// picks, Escape closes, typing goes to the search box.
class AppSelectField<T> extends StatefulWidget {
  const AppSelectField({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.label,
    this.placeholder = Fa.selectPlaceholder,
    this.icon,
    this.loading = false,
    this.loadError,
    this.onRetry,
    this.emptyText = Fa.noOptions,
    this.searchable,
    this.searchHint = Fa.searchOptions,
    this.errorText,
    this.helperText,
    this.menuMaxHeight = 340,
    this.dense = false,
    this.selectedLabel,
    this.fieldKey,
  });

  final List<AppSelectOption<T>> options;
  final T? value;

  /// Null disables the field.
  final ValueChanged<T>? onChanged;
  final String? label;
  final String placeholder;
  final AppIcon? icon;
  final bool loading;

  /// A failed load: the menu shows it with [onRetry] instead of an empty list.
  final String? loadError;
  final VoidCallback? onRetry;
  final String emptyText;

  /// Null: a search box appears when there are more than 7 options.
  final bool? searchable;
  final String searchHint;
  final String? errorText;
  final String? helperText;
  final double menuMaxHeight;
  final bool dense;

  /// Shown when [value] is not among [options] (e.g. a stored assignee who
  /// is no longer a member). Never an id.
  final String? selectedLabel;
  final Key? fieldKey;

  @override
  State<AppSelectField<T>> createState() => _AppSelectFieldState<T>();
}

class _AppSelectFieldState<T> extends State<AppSelectField<T>> {
  final _link = LayerLink();
  final _portal = OverlayPortalController();
  final _fieldFocus = FocusNode(debugLabel: 'select-field');
  final _tapGroup = Object();
  bool _hover = false;
  bool _focused = false;

  bool get _enabled => widget.onChanged != null;

  AppSelectOption<T>? get _selected {
    for (final option in widget.options) {
      if (option.value == widget.value) return option;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _fieldFocus.addListener(() {
      if (mounted) setState(() => _focused = _fieldFocus.hasFocus);
    });
  }

  @override
  void dispose() {
    _fieldFocus.dispose();
    super.dispose();
  }

  bool _phone(BuildContext context) => MediaQuery.sizeOf(context).width < AppBreakpoints.medium;

  Future<void> _open() async {
    if (!_enabled) return;
    if (_phone(context)) {
      final picked = await showModalBottomSheet<_Picked<T>>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (sheetContext) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.75),
            child: _SelectMenu<T>(
              title: widget.label,
              options: widget.options,
              value: widget.value,
              loading: widget.loading,
              loadError: widget.loadError,
              onRetry: widget.onRetry,
              emptyText: widget.emptyText,
              searchable: widget.searchable ?? widget.options.length > 7,
              searchHint: widget.searchHint,
              sheet: true,
              onPick: (value) => Navigator.pop(sheetContext, _Picked(value)),
              onClose: () => Navigator.pop(sheetContext),
            ),
          ),
        ),
      );
      if (picked != null && mounted) widget.onChanged?.call(picked.value);
      return;
    }
    setState(_portal.show);
  }

  void _close({bool refocus = true}) {
    if (!_portal.isShowing) return;
    setState(_portal.hide);
    if (refocus) _fieldFocus.requestFocus();
  }

  void _pick(T value) {
    _close();
    widget.onChanged?.call(value);
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    final selected = _selected;
    final open = _portal.isShowing;
    final shownLabel = selected?.label ?? widget.selectedLabel;
    final hasError = widget.errorText != null;
    final borderColor = !_enabled
        ? p.stroke
        : hasError
        ? p.danger
        : (open || _focused)
        ? p.jade
        : _hover
        ? p.ink.withValues(alpha: 0.55)
        : p.outline;
    final borderWidth = (open || _focused || hasError) && _enabled ? 1.6 : 1.0;

    final field = CompositedTransformTarget(
      link: _link,
      child: Semantics(
        button: true,
        enabled: _enabled,
        expanded: open,
        label: [widget.label, shownLabel ?? widget.placeholder].whereType<String>().join(': '),
        excludeSemantics: true,
        onTap: _enabled ? _open : null,
        child: FocusableActionDetector(
          focusNode: _fieldFocus,
          enabled: _enabled,
          mouseCursor: _enabled ? SystemMouseCursors.click : SystemMouseCursors.forbidden,
          onShowHoverHighlight: (value) => setState(() => _hover = value),
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
            SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
            SingleActivator(LogicalKeyboardKey.arrowDown): ActivateIntent(),
            SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
          },
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => open ? _close() : _open()),
            DismissIntent: CallbackAction<DismissIntent>(onInvoke: (_) => _close()),
          },
          child: GestureDetector(
            key: widget.fieldKey,
            behavior: HitTestBehavior.opaque,
            onTap: _enabled ? () => open ? _close() : _open() : null,
            child: AnimatedContainer(
              duration: AppMotion.of(context, AppMotion.state),
              constraints: BoxConstraints(minHeight: widget.dense ? 40 : 48),
              padding: EdgeInsetsDirectional.fromSTEB(AppSpace.m, widget.dense ? 4 : AppSpace.xs, AppSpace.s, widget.dense ? 4 : AppSpace.xs),
              decoration: BoxDecoration(
                color: !_enabled ? p.surfaceRaised : (_hover || open ? Color.alphaBlend(p.jade.withValues(alpha: 0.04), p.surface) : p.surface),
                borderRadius: BorderRadius.circular(AppRadius.control),
                border: Border.all(color: borderColor, width: borderWidth),
              ),
              child: Row(
                children: [
                  if (selected?.leading != null) ...[
                    selected!.leading!,
                    const SizedBox(width: AppSpace.s),
                  ] else if (widget.icon != null) ...[
                    AppIconView(widget.icon!, size: 18, color: p.muted),
                    const SizedBox(width: AppSpace.s),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (widget.label != null && !widget.dense)
                          Text(
                            widget.label!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.labelSmall?.copyWith(color: hasError ? p.danger : p.muted),
                          ),
                        Text(
                          shownLabel ?? widget.placeholder,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodyMedium?.copyWith(color: shownLabel == null || !_enabled ? p.muted : p.ink, fontWeight: shownLabel == null ? null : FontWeight.w600),
                        ),
                        if (selected?.subtitle != null && !widget.dense)
                          Text(
                            selected!.subtitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.labelSmall?.copyWith(color: p.muted),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpace.xs),
                  if (widget.loading)
                    SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: p.muted))
                  else
                    AnimatedRotation(
                      turns: open ? 0.5 : 0,
                      duration: AppMotion.of(context, AppMotion.state),
                      child: AppIconView(AppIcons.expand, size: 18, color: _enabled ? p.muted : p.stroke),
                    ),
                  const SizedBox(width: AppSpace.xs),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    return TapRegion(
      groupId: _tapGroup,
      onTapOutside: (_) => _close(refocus: false),
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: _menu,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            field,
            if (widget.errorText != null || widget.helperText != null)
              Padding(
                padding: const EdgeInsetsDirectional.only(start: AppSpace.m, top: AppSpace.xs),
                child: Text(widget.errorText ?? widget.helperText!, style: text.bodySmall?.copyWith(color: hasError ? p.danger : p.muted)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _menu(BuildContext overlayContext) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return const SizedBox.shrink();
    final screen = MediaQuery.sizeOf(overlayContext);
    final padding = MediaQuery.paddingOf(overlayContext);
    final origin = box.localToGlobal(Offset.zero);
    // The field row only (helper text excluded) anchors the menu.
    final fieldHeight = math.min(box.size.height, widget.dense ? 44.0 : 64.0);
    const gap = 6.0;
    const margin = 12.0;
    final below = screen.height - padding.bottom - (origin.dy + fieldHeight) - gap - margin;
    final above = origin.dy - padding.top - gap - margin;
    final openUp = below < math.min(widget.menuMaxHeight, 220) && above > below;
    final maxHeight = math.max(120.0, math.min(widget.menuMaxHeight, openUp ? above : below));
    final width = math.max(box.size.width, 240.0);
    // Keep the menu inside the screen horizontally.
    final overflowRight = origin.dx + width - (screen.width - margin);
    final dx = overflowRight > 0 ? -overflowRight : 0.0;

    return Positioned(
      left: 0,
      top: 0,
      child: CompositedTransformFollower(
        link: _link,
        showWhenUnlinked: false,
        targetAnchor: openUp ? Alignment.topLeft : Alignment.topLeft,
        followerAnchor: openUp ? Alignment.bottomLeft : Alignment.topLeft,
        offset: Offset(dx, openUp ? -gap : fieldHeight + gap),
        child: TapRegion(
          groupId: _tapGroup,
          child: SizedBox(
            width: width,
            child: _MenuSurface(
              maxHeight: maxHeight,
              child: _SelectMenu<T>(
                options: widget.options,
                value: widget.value,
                loading: widget.loading,
                loadError: widget.loadError,
                onRetry: widget.onRetry,
                emptyText: widget.emptyText,
                searchable: widget.searchable ?? widget.options.length > 7,
                searchHint: widget.searchHint,
                sheet: false,
                onPick: _pick,
                onClose: _close,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Picked<T> {
  const _Picked(this.value);
  final T value;
}

/// L3 surface of an open menu: deep glass, hairline edge, natural shadow.
class _MenuSurface extends StatelessWidget {
  const _MenuSurface({required this.child, required this.maxHeight});

  final Widget child;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final radius = BorderRadius.circular(AppRadius.control + 2);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: AppMotion.of(context, AppMotion.state),
      curve: AppMotion.enter,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, (1 - t) * -4), child: child),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(borderRadius: radius, boxShadow: AppElevation.e3(p.ink)),
        child: ClipRRect(
          borderRadius: radius,
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Material(
              color: Color.alphaBlend(p.glassDeep, p.surface.withValues(alpha: 0.55)),
              shape: RoundedRectangleBorder(
                borderRadius: radius,
                side: BorderSide(color: p.stroke),
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxHeight),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SelectMenu<T> extends StatefulWidget {
  const _SelectMenu({
    required this.options,
    required this.value,
    required this.loading,
    required this.loadError,
    required this.onRetry,
    required this.emptyText,
    required this.searchable,
    required this.searchHint,
    required this.sheet,
    required this.onPick,
    required this.onClose,
    this.title,
  });

  final List<AppSelectOption<T>> options;
  final T? value;
  final bool loading;
  final String? loadError;
  final VoidCallback? onRetry;
  final String emptyText;
  final bool searchable;
  final String searchHint;
  final bool sheet;
  final String? title;
  final ValueChanged<T> onPick;
  final VoidCallback onClose;

  @override
  State<_SelectMenu<T>> createState() => _SelectMenuState<T>();
}

class _SelectMenuState<T> extends State<_SelectMenu<T>> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode(debugLabel: 'select-menu');
  final _searchFocus = FocusNode(debugLabel: 'select-search');
  final _keys = <int, GlobalKey>{};
  String _query = '';
  int _highlight = -1;

  List<AppSelectOption<T>> get _visible => [
    for (final option in widget.options)
      if (option.matches(_query)) option,
  ];

  @override
  void initState() {
    super.initState();
    final index = widget.options.indexWhere((o) => o.value == widget.value);
    _highlight = index >= 0 ? index : widget.options.indexWhere((o) => o.enabled);
    // Take focus explicitly: autofocus is ignored when another field (e.g.
    // the task title) already holds focus, which left keys going elsewhere.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      (widget.searchable ? _searchFocus : _focus).requestFocus();
      _reveal();
    });
  }

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    _focus.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _reveal() {
    final context = _keys[_highlight]?.currentContext;
    if (context != null) Scrollable.ensureVisible(context, alignment: 0.5, duration: AppMotion.press);
  }

  void _step(int delta) {
    final visible = _visible;
    if (visible.isEmpty) return;
    var next = _highlight;
    for (var i = 0; i < visible.length; i++) {
      next = (next + delta) % visible.length;
      if (next < 0) next += visible.length;
      if (visible[next].enabled) break;
    }
    setState(() => _highlight = next);
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      _step(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _step(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.home || key == LogicalKeyboardKey.end) {
      final visible = _visible;
      if (visible.isEmpty) return KeyEventResult.handled;
      setState(() => _highlight = key == LogicalKeyboardKey.home ? 0 : visible.length - 1);
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      final visible = _visible;
      if (_highlight >= 0 && _highlight < visible.length && visible[_highlight].enabled) widget.onPick(visible[_highlight].value);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      widget.onClose();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    final visible = _visible;

    Widget body;
    if (widget.loading && widget.options.isEmpty) {
      body = Padding(
        padding: const EdgeInsets.all(AppSpace.l),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: p.jade)),
            const SizedBox(width: AppSpace.s),
            Text(Fa.loadingOptions, style: text.bodySmall),
          ],
        ),
      );
    } else if (widget.loadError != null) {
      body = Padding(
        key: const Key('select-error'),
        padding: const EdgeInsets.all(AppSpace.l),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIconView(AppIcons.error, size: 22, color: p.danger),
            const SizedBox(height: AppSpace.s),
            Text(
              widget.loadError!,
              textAlign: TextAlign.center,
              style: text.bodySmall?.copyWith(color: p.ink),
            ),
            if (widget.onRetry != null) ...[const SizedBox(height: AppSpace.s), TextButton(onPressed: widget.onRetry, child: const Text(Fa.retry))],
          ],
        ),
      );
    } else if (visible.isEmpty) {
      body = Padding(
        key: const Key('select-empty'),
        padding: const EdgeInsets.all(AppSpace.l),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIconView(AppIcons.empty, size: 22, color: p.muted),
            const SizedBox(height: AppSpace.s),
            Text(_query.isEmpty ? widget.emptyText : Fa.noOptionMatch, textAlign: TextAlign.center, style: text.bodySmall),
          ],
        ),
      );
    } else {
      body = ListView.builder(
        controller: _scroll,
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
        itemCount: visible.length,
        itemBuilder: (context, i) {
          final option = visible[i];
          final key = _keys.putIfAbsent(i, GlobalKey.new);
          return _OptionRow<T>(
            key: key,
            option: option,
            selected: option.value == widget.value,
            highlighted: i == _highlight,
            onHover: () => setState(() => _highlight = i),
            onTap: option.enabled ? () => widget.onPick(option.value) : null,
          );
        },
      );
    }

    return Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.sheet && widget.title != null)
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(AppSpace.xl, 0, AppSpace.xl, AppSpace.s),
              child: Text(widget.title!, style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            ),
          if (widget.searchable)
            Padding(
              padding: EdgeInsets.fromLTRB(widget.sheet ? AppSpace.xl : AppSpace.s, AppSpace.s, widget.sheet ? AppSpace.xl : AppSpace.s, AppSpace.xs),
              child: TextField(
                key: const Key('select-search'),
                controller: _search,
                focusNode: _searchFocus,
                textInputAction: TextInputAction.done,
                onChanged: (value) => setState(() {
                  _query = value;
                  _highlight = _visible.indexWhere((o) => o.enabled);
                }),
                onSubmitted: (_) {
                  final visible = _visible;
                  if (_highlight >= 0 && _highlight < visible.length && visible[_highlight].enabled) widget.onPick(visible[_highlight].value);
                },
                decoration: InputDecoration(
                  isDense: true,
                  hintText: widget.searchHint,
                  prefixIcon: Padding(
                    padding: const EdgeInsets.all(10),
                    child: AppIconView(AppIcons.search, size: 18, color: p.muted),
                  ),
                  prefixIconConstraints: const BoxConstraints(minWidth: 38, minHeight: 38),
                ),
              ),
            ),
          Flexible(child: body),
          if (widget.sheet) const SizedBox(height: AppSpace.m),
        ],
      ),
    );
  }
}

class _OptionRow<T> extends StatelessWidget {
  const _OptionRow({super.key, required this.option, required this.selected, required this.highlighted, required this.onHover, required this.onTap});

  final AppSelectOption<T> option;
  final bool selected;
  final bool highlighted;
  final VoidCallback onHover;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final text = Theme.of(context).textTheme;
    final enabled = option.enabled;
    final fill = selected
        ? Color.alphaBlend(p.jade.withValues(alpha: 0.12), Colors.transparent)
        : highlighted
        ? p.ink.withValues(alpha: 0.06)
        : Colors.transparent;
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      label: [option.label, option.subtitle].whereType<String>().join('، '),
      excludeSemantics: true,
      child: MouseRegion(
        onEnter: (_) => onHover(),
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.xs, vertical: 1),
          child: Material(
            color: fill,
            borderRadius: BorderRadius.circular(AppRadius.chip),
            child: InkWell(
              key: ValueKey('option-${option.value}'),
              borderRadius: BorderRadius.circular(AppRadius.chip),
              onTap: onTap,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 44),
                child: Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(AppSpace.m, AppSpace.xs + 2, AppSpace.s, AppSpace.xs + 2),
                  child: Row(
                    children: [
                      if (option.leading != null) ...[option.leading!, const SizedBox(width: AppSpace.m)],
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              option.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: text.bodyMedium?.copyWith(color: enabled ? p.ink : p.muted, fontWeight: selected ? FontWeight.w700 : FontWeight.w500),
                            ),
                            if (option.subtitle != null)
                              Text(
                                option.subtitle!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: text.labelSmall?.copyWith(color: p.muted),
                              ),
                          ],
                        ),
                      ),
                      SizedBox(width: 22, child: selected ? AppIconView(AppIcons.approve, selected: true, size: 18, color: p.jade) : null),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
