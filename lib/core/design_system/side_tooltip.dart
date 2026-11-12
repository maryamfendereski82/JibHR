import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';

/// A tooltip that opens beside its child, towards the content side, vertically
/// centred on it. Made for the navigation rail, where Flutter's [Tooltip]
/// would open above or below the icon.
///
/// * In RTL it opens to the left of the child, in LTR to the right.
/// * Shown on mouse hover (after a short delay) and on keyboard focus.
/// * Never shown for touch: phone navigation keeps visible labels instead.
/// * Drawn in the overlay, so no parent clips it and the layout never moves.
/// * Not part of the accessibility tree; the child already carries its label.
class SideTooltip extends StatefulWidget {
  const SideTooltip({super.key, required this.message, required this.child});

  final String message;
  final Widget child;

  @override
  State<SideTooltip> createState() => _SideTooltipState();
}

class _SideTooltipState extends State<SideTooltip> {
  final _link = LayerLink();
  final _portal = OverlayPortalController();
  Timer? _delay;
  bool _hover = false;
  bool _focus = false;

  void _sync() {
    _delay?.cancel();
    final keyboard = FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    final want = _hover || (_focus && keyboard);
    if (want && !_portal.isShowing) {
      _delay = Timer(_hover && !_focus ? const Duration(milliseconds: 350) : Duration.zero, () {
        if (mounted) _portal.show();
      });
    } else if (!want && _portal.isShowing) {
      _portal.hide();
    }
  }

  @override
  void dispose() {
    _delay?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _portal,
        // The Align gives the follower loose constraints, so it is exactly the
        // size of the bubble; the follower then moves it next to the child.
        overlayChildBuilder: (context) => Align(
          alignment: Alignment.topLeft,
          child: CompositedTransformFollower(
            link: _link,
            showWhenUnlinked: false,
            // The bubble's near edge meets the child's far edge, centred.
            targetAnchor: rtl ? Alignment.centerLeft : Alignment.centerRight,
            followerAnchor: rtl ? Alignment.centerRight : Alignment.centerLeft,
            offset: Offset(rtl ? -AppSpace.s : AppSpace.s, 0),
            child: IgnorePointer(
              child: _Bubble(message: widget.message, pointsRight: rtl),
            ),
          ),
        ),
        child: MouseRegion(
          onEnter: (event) {
            if (event.kind == PointerDeviceKind.mouse) {
              _hover = true;
              _sync();
            }
          },
          onExit: (_) {
            _hover = false;
            _sync();
          },
          child: Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onFocusChange: (value) {
              _focus = value;
              _sync();
            },
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.pointsRight});

  final String message;

  /// The arrow sits on the side facing the child.
  final bool pointsRight;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final arrow = CustomPaint(
      size: const Size(6, 12),
      painter: _Arrow(color: p.ink, pointsRight: pointsRight),
    );
    final body = Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.m, vertical: 6),
      decoration: BoxDecoration(color: p.ink, borderRadius: BorderRadius.circular(AppRadius.chip), boxShadow: AppElevation.e2(p.ink)),
      child: Text(message, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: p.canvas)),
    );
    return Material(
      type: MaterialType.transparency,
      child: Row(mainAxisSize: MainAxisSize.min, textDirection: TextDirection.ltr, children: pointsRight ? [body, arrow] : [arrow, body]),
    );
  }
}

class _Arrow extends CustomPainter {
  _Arrow({required this.color, required this.pointsRight});

  final Color color;
  final bool pointsRight;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path();
    if (pointsRight) {
      path
        ..moveTo(0, 0)
        ..lineTo(size.width, size.height / 2)
        ..lineTo(0, size.height);
    } else {
      path
        ..moveTo(size.width, 0)
        ..lineTo(0, size.height / 2)
        ..lineTo(size.width, size.height);
    }
    canvas.drawPath(path..close(), Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _Arrow old) => old.color != color || old.pointsRight != pointsRight;
}
