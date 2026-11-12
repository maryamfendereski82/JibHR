import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 56});

  final double size;

  @override
  Widget build(BuildContext context) {
    final palette = paletteOf(context);
    return Semantics(
      label: 'JibHR',
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: const Color(0xFF12382C),
          borderRadius: BorderRadius.circular(size * 0.28),
          border: Border.all(color: palette.stroke),
        ),
        alignment: Alignment.center,
        child: CustomPaint(size: Size.square(size * 0.62), painter: _MarkPainter()),
      ),
    );
  }
}

class _MarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = const Color(0xFF3DDC97)
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.1
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path()
      ..moveTo(size.width * 0.18, size.height * 0.2)
      ..lineTo(size.width * 0.72, size.height * 0.2)
      ..cubicTo(size.width * 0.95, size.height * 0.2, size.width * 0.95, size.height * 0.55, size.width * 0.62, size.height * 0.55)
      ..lineTo(size.width * 0.38, size.height * 0.55)
      ..lineTo(size.width * 0.38, size.height * 0.84);
    canvas.drawPath(path, stroke);
    canvas.drawCircle(Offset(size.width * 0.78, size.height * 0.78), size.width * 0.08, Paint()..color = const Color(0xFFE7C56A));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
