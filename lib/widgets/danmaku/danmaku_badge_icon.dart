import 'package:flutter/material.dart';

import '../../i18n/strings.g.dart';

/// Custom badge icon for Danmaku toggle (`弹` / `彈` in Chinese locales, `DM` otherwise).
///
/// Uses [CustomPaint] rather than [Icon] so it adapts cleanly to active amber,
/// disabled outline + slash, and D-pad focus disc color inversion without
/// violating `check_icon_consistency.dart`.
class DanmakuBadgeIcon extends StatelessWidget {
  final bool enabled;
  final Color color;
  final double size;

  const DanmakuBadgeIcon({super.key, required this.enabled, required this.color, this.size = 22});

  static String glyphForLocale(AppLocale locale) {
    if (locale.languageCode == 'zh') {
      final isTraditional = locale.scriptCode == 'Hant' || locale.countryCode == 'TW' || locale.countryCode == 'HK';
      return isTraditional ? '彈' : '弹';
    }
    return 'DM';
  }

  @override
  Widget build(BuildContext context) {
    final glyph = glyphForLocale(LocaleSettings.currentLocale);
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _DanmakuBadgePainter(enabled: enabled, color: color, glyph: glyph),
      ),
    );
  }
}

class _DanmakuBadgePainter extends CustomPainter {
  final bool enabled;
  final Color color;
  final String glyph;

  const _DanmakuBadgePainter({required this.enabled, required this.color, required this.glyph});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: size.width * 0.92,
      height: size.height * 0.76,
    );
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(size.width * 0.21));
    final fontSize = glyph.length > 1 ? size.width * 0.42 : size.width * 0.50;

    if (enabled) {
      final fillPaint = Paint()..color = color;
      canvas.drawRRect(rrect, fillPaint);

      final textColor = color.computeLuminance() < 0.2 ? Colors.amber : const Color(0xFF18181B);
      _paintGlyph(canvas, size, textColor, fontSize, FontWeight.w800);
      return;
    }

    final mutedColor = color.withValues(alpha: color.a * 0.85);
    canvas.saveLayer(Offset.zero & size, Paint());

    final borderPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..color = mutedColor;
    canvas.drawRRect(rrect.deflate(1.0), borderPaint);

    _paintGlyph(canvas, size, mutedColor, fontSize, FontWeight.w800);

    final slashStart = Offset(size.width * 0.16, size.height * 0.84);
    final slashEnd = Offset(size.width * 0.84, size.height * 0.16);
    final cutoutPaint = Paint()
      ..blendMode = BlendMode.clear
      ..strokeWidth = 3.6
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(slashStart, slashEnd, cutoutPaint);

    final slashPaint = Paint()
      ..color = color
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(slashStart, slashEnd, slashPaint);

    canvas.restore();
  }

  void _paintGlyph(Canvas canvas, Size size, Color textColor, double fontSize, FontWeight fontWeight) {
    final textPainter = TextPainter(
      text: TextSpan(
        text: glyph,
        style: TextStyle(color: textColor, fontSize: fontSize, fontWeight: fontWeight, height: 1.0),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout();

    final offset = Offset(
      (size.width - textPainter.width) / 2,
      (size.height - textPainter.height) / 2 - (glyph.length == 1 ? size.height * 0.02 : 0),
    );
    textPainter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _DanmakuBadgePainter oldDelegate) {
    return oldDelegate.enabled != enabled || oldDelegate.color != color || oldDelegate.glyph != glyph;
  }
}
