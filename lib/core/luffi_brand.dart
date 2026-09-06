import 'package:flutter/material.dart';

import 'app_theme.dart';

/// The two wind-filled sails and their quiet wake are luffi's original mark.
/// Paths match assets/branding/luffi-mark.svg, so the app and launcher agree.
final class LuffiMark extends StatelessWidget {
  const LuffiMark({
    this.size = 40,
    this.color = AppTheme.primary,
    this.secondaryColor,
    super.key,
  });

  final double size;
  final Color color;
  final Color? secondaryColor;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _LuffiMarkPainter(color, secondaryColor ?? color),
      ),
    ),
  );
}

final class LuffiWordmark extends StatelessWidget {
  const LuffiWordmark({
    this.fontSize = 36,
    this.color = AppTheme.ink,
    super.key,
  });

  final double fontSize;
  final Color color;

  @override
  Widget build(BuildContext context) => Text(
    'luffi',
    semanticsLabel: '러피',
    style: TextStyle(
      color: color,
      fontFamily: 'SUIT',
      fontSize: fontSize,
      height: 1,
      letterSpacing: -fontSize * 0.055,
      fontWeight: FontWeight.w700,
    ),
  );
}

final class _LuffiMarkPainter extends CustomPainter {
  const _LuffiMarkPainter(this.color, this.secondaryColor);

  final Color color;
  final Color secondaryColor;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 100, size.height / 100);
    final mainSail = Path()
      ..moveTo(60, 14)
      ..cubicTo(42, 22, 27, 40, 21, 59)
      ..cubicTo(31, 53, 41, 52, 50, 54)
      ..cubicTo(51, 37, 54, 24, 60, 14)
      ..close();
    final smallSail = Path()
      ..moveTo(65, 30)
      ..cubicTo(63, 41, 62, 51, 62, 62)
      ..cubicTo(69, 58, 76, 58, 84, 60)
      ..cubicTo(76, 50, 70, 40, 65, 30)
      ..close();
    final wake = Path()
      ..moveTo(23, 70)
      ..cubicTo(41, 77, 65, 78, 83, 68)
      ..cubicTo(75, 81, 57, 88, 40, 82)
      ..cubicTo(32, 80, 26, 75, 23, 70)
      ..close();
    canvas.drawPath(mainSail, Paint()..color = color);
    canvas.drawPath(smallSail, Paint()..color = secondaryColor);
    canvas.drawPath(wake, Paint()..color = color);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_LuffiMarkPainter oldDelegate) =>
      color != oldDelegate.color ||
      secondaryColor != oldDelegate.secondaryColor;
}
