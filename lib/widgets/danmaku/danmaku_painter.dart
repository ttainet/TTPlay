import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../services/danmaku/danmaku_models.dart';
import 'danmaku_engine.dart';

class _DanmakuPaintKey {
  final String text;
  final int colorArgb;
  final int fontSizeTenths;
  final int strokeTenths;
  final int opacityPercent;

  const _DanmakuPaintKey({
    required this.text,
    required this.colorArgb,
    required this.fontSizeTenths,
    required this.strokeTenths,
    required this.opacityPercent,
  });

  @override
  bool operator ==(Object other) {
    return other is _DanmakuPaintKey &&
        other.text == text &&
        other.colorArgb == colorArgb &&
        other.fontSizeTenths == fontSizeTenths &&
        other.strokeTenths == strokeTenths &&
        other.opacityPercent == opacityPercent;
  }

  @override
  int get hashCode => Object.hash(text, colorArgb, fontSizeTenths, strokeTenths, opacityPercent);
}

class _CachedDanmakuPainter {
  final TextPainter? strokePainter;
  final TextPainter fillPainter;
  final double width;

  const _CachedDanmakuPainter({required this.strokePainter, required this.fillPainter, required this.width});
}

/// High-throughput Canvas painter with bounded LRU TextPainter cache,
/// inspired by NipaPlay-Reload's Next Canvas rendering pipeline.
class DanmakuCanvasPainter extends CustomPainter {
  static const int _maxCacheEntries = 600;
  static final LinkedHashMap<_DanmakuPaintKey, _CachedDanmakuPainter> _cache =
      LinkedHashMap<_DanmakuPaintKey, _CachedDanmakuPainter>();

  final ValueListenable<double> smoothTimeSec;
  final DanmakuLayoutEngine engine;
  final DanmakuRenderSettings settings;
  final int commentsVersion;

  DanmakuCanvasPainter({
    required this.smoothTimeSec,
    required this.engine,
    required this.settings,
    required this.commentsVersion,
  }) : super(repaint: smoothTimeSec);

  _CachedDanmakuPainter _resolvePainter(DanmakuCommentItem item) {
    final text = item.displayText;
    final opacity = settings.opacity.clamp(0.1, 1.0);
    final fontSize = settings.fontSize.clamp(12.0, 48.0);
    final strokeWidth = settings.strokeWidth.clamp(0.0, 4.0);
    final key = _DanmakuPaintKey(
      text: text,
      colorArgb: item.color.toARGB32(),
      fontSizeTenths: (fontSize * 10).round(),
      strokeTenths: (strokeWidth * 10).round(),
      opacityPercent: (opacity * 100).round(),
    );

    final existing = _cache.remove(key);
    if (existing != null) {
      _cache[key] = existing;
      return existing;
    }

    TextPainter? strokePainter;
    if (strokeWidth > 0.05) {
      final strokePaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth * 2.0
        ..strokeJoin = StrokeJoin.round
        ..color = Colors.black.withValues(alpha: (opacity * 0.85).clamp(0.0, 1.0));
      strokePainter = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w600, height: 1.15, foreground: strokePaint),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
    }

    final fillPainter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: item.color.withValues(alpha: opacity),
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
          height: 1.15,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();

    final entry = _CachedDanmakuPainter(
      strokePainter: strokePainter,
      fillPainter: fillPainter,
      width: fillPainter.width,
    );
    _cache[key] = entry;
    if (_cache.length > _maxCacheEntries) {
      _cache.remove(_cache.keys.first);
    }
    return entry;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    engine.configure(
      size: size,
      fontSize: settings.fontSize,
      displayArea: settings.displayArea,
      scrollDurationSeconds: settings.scrollDurationSeconds,
      allowStacking: settings.allowStacking,
    );

    final effectiveTime = smoothTimeSec.value + settings.timeOffsetSeconds;
    final items = engine.layoutAt(effectiveTime, measureWidth: (item) => _resolvePainter(item).width);
    if (items.isEmpty) return;

    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (final positioned in items) {
      final painter = _resolvePainter(positioned.item);
      final offset = Offset(positioned.x, positioned.y);
      painter.strokePainter?.paint(canvas, offset);
      painter.fillPainter.paint(canvas, offset);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant DanmakuCanvasPainter oldDelegate) {
    return oldDelegate.commentsVersion != commentsVersion ||
        oldDelegate.engine != engine ||
        oldDelegate.settings != settings ||
        oldDelegate.smoothTimeSec != smoothTimeSec;
  }
}
