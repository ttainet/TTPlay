import 'dart:ui' show Size;

import '../../services/danmaku/danmaku_models.dart';

class PositionedDanmaku {
  final DanmakuCommentItem item;
  final double x;
  final double y;
  final double width;
  final double height;
  final int trackIndex;

  const PositionedDanmaku({
    required this.item,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.trackIndex,
  });
}

typedef DanmakuWidthMeasurer = double Function(DanmakuCommentItem item);

/// Deterministic, binary-search-indexed danmaku layout engine inspired by
/// NipaPlay-Reload's Next layout architecture.
class DanmakuLayoutEngine {
  static const double _minScrollGap = 24.0;

  Size _size = Size.zero;
  double _fontSize = 22.0;
  double _displayArea = 0.5;
  double _scrollDurationSeconds = 10.0;
  bool _allowStacking = false;
  double _staticDurationSeconds = 5.0;
  double _bottomMargin = 48.0;

  List<DanmakuCommentItem> _items = const [];
  List<double> _times = const [];
  int _commentsVersion = -1;

  /// Cached track assignment per comment index for the current layout configuration.
  /// `-1` means dropped due to track saturation when `allowStacking == false`.
  final Map<int, int> _assignedTrack = <int, int>{};
  final Map<int, double> _cachedWidths = <int, double>{};

  int get layoutVersion => _layoutVersion;
  int _layoutVersion = 0;

  void configure({
    required Size size,
    required double fontSize,
    required double displayArea,
    required double scrollDurationSeconds,
    required bool allowStacking,
    double staticDurationSeconds = 5.0,
    double bottomMargin = 48.0,
  }) {
    final changed =
        (_size.width - size.width).abs() > 0.5 ||
        (_size.height - size.height).abs() > 0.5 ||
        (_fontSize - fontSize).abs() > 0.1 ||
        (_displayArea - displayArea).abs() > 0.005 ||
        (_scrollDurationSeconds - scrollDurationSeconds).abs() > 0.05 ||
        _allowStacking != allowStacking ||
        (_staticDurationSeconds - staticDurationSeconds).abs() > 0.05 ||
        (_bottomMargin - bottomMargin).abs() > 0.5;

    if (!changed) return;

    final widthCacheInvalid = (_fontSize - fontSize).abs() > 0.1;
    _size = size;
    _fontSize = fontSize;
    _displayArea = displayArea.clamp(0.15, 1.0);
    _scrollDurationSeconds = scrollDurationSeconds.clamp(2.0, 30.0);
    _allowStacking = allowStacking;
    _staticDurationSeconds = staticDurationSeconds.clamp(1.0, 15.0);
    _bottomMargin = bottomMargin;
    _assignedTrack.clear();
    if (widthCacheInvalid) {
      _cachedWidths.clear();
    }
    _layoutVersion++;
  }

  void setComments(List<DanmakuCommentItem> sortedComments, int version) {
    if (_commentsVersion == version && identical(_items, sortedComments)) return;
    _commentsVersion = version;
    _items = sortedComments;
    _times = sortedComments.map((e) => e.timeSeconds).toList(growable: false);
    _assignedTrack.clear();
    _cachedWidths.clear();
    _layoutVersion++;
  }

  double get trackHeight => (_fontSize * 1.35).clamp(16.0, 80.0);

  int get trackCount {
    if (_size.height <= 0 || _size.width <= 0) return 0;
    final usableHeight = (_size.height - _bottomMargin * 0.25).clamp(trackHeight, _size.height);
    final raw = ((usableHeight * _displayArea) / trackHeight).floor();
    return raw < 1 ? 1 : raw;
  }

  double _measureWidth(int index, DanmakuCommentItem item, DanmakuWidthMeasurer? measurer) {
    final cached = _cachedWidths[index];
    if (cached != null) return cached;
    final w = measurer != null ? measurer(item) : (item.displayText.runes.length * _fontSize * 0.85);
    _cachedWidths[index] = w;
    return w;
  }

  List<PositionedDanmaku> layoutAt(double currentTimeSec, {DanmakuWidthMeasurer? measureWidth}) {
    if (_items.isEmpty || _size.width <= 0 || _size.height <= 0) {
      return const [];
    }
    final tracks = trackCount;
    if (tracks <= 0) return const [];

    final maxDur = _scrollDurationSeconds > _staticDurationSeconds ? _scrollDurationSeconds : _staticDurationSeconds;
    final simWindowStart = currentTimeSec - maxDur * 2.0;
    final simStartIdx = _lowerBound(_times, simWindowStart);
    final endIdx = _upperBound(_times, currentTimeSec);
    if (simStartIdx >= endIdx) return const [];

    // Latest occupant index per track during this window scan.
    final lastScroll = List<int>.filled(tracks, -1);
    final lastTop = List<int>.filled(tracks, -1);
    final lastBottom = List<int>.filled(tracks, -1);

    final out = <PositionedDanmaku>[];
    final th = trackHeight;
    final w = _size.width;
    final h = _size.height;

    for (var i = simStartIdx; i < endIdx; i++) {
      final item = _items[i];
      final itemWidth = _measureWidth(i, item, measureWidth);
      var track = _assignedTrack[i];

      if (track == null) {
        track = switch (item.mode) {
          DanmakuMode.scroll => _pickScrollTrack(i, item, itemWidth, w, tracks, lastScroll, measureWidth),
          DanmakuMode.top => _pickStaticTrack(item, tracks, lastTop),
          DanmakuMode.bottom => _pickStaticTrack(item, tracks, lastBottom),
        };
        _assignedTrack[i] = track;
      }

      if (track >= 0 && track < tracks) {
        switch (item.mode) {
          case DanmakuMode.scroll:
            lastScroll[track] = i;
          case DanmakuMode.top:
            lastTop[track] = i;
          case DanmakuMode.bottom:
            lastBottom[track] = i;
        }
      } else {
        continue;
      }

      final elapsed = currentTimeSec - item.timeSeconds;
      if (elapsed < 0) continue;

      switch (item.mode) {
        case DanmakuMode.scroll:
          if (elapsed > _scrollDurationSeconds) continue;
          final x = w - (w + itemWidth) * (elapsed / _scrollDurationSeconds);
          if (x + itemWidth < 0 || x > w) continue;
          final y = 8.0 + track * th;
          if (y + th > h) continue;
          out.add(PositionedDanmaku(item: item, x: x, y: y, width: itemWidth, height: th, trackIndex: track));
        case DanmakuMode.top:
          if (elapsed > _staticDurationSeconds) continue;
          final x = (w - itemWidth) * 0.5;
          final y = 8.0 + track * th;
          if (y + th > h) continue;
          out.add(PositionedDanmaku(item: item, x: x, y: y, width: itemWidth, height: th, trackIndex: track));
        case DanmakuMode.bottom:
          if (elapsed > _staticDurationSeconds) continue;
          final x = (w - itemWidth) * 0.5;
          final y = h - _bottomMargin - (track + 1) * th;
          if (y < 0 || y + th > h) continue;
          out.add(PositionedDanmaku(item: item, x: x, y: y, width: itemWidth, height: th, trackIndex: track));
      }
    }

    return out;
  }

  int _pickScrollTrack(
    int index,
    DanmakuCommentItem item,
    double widthB,
    double viewportWidth,
    int tracks,
    List<int> lastScroll,
    DanmakuWidthMeasurer? measureWidth,
  ) {
    final tB = item.timeSeconds;
    final dur = _scrollDurationSeconds;
    final vB = (viewportWidth + widthB) / dur;
    final timeToReachLeftB = viewportWidth / vB;

    var bestFallbackTrack = 0;
    var earliestPrevEnd = double.infinity;

    for (var tr = 0; tr < tracks; tr++) {
      final prevIdx = lastScroll[tr];
      if (prevIdx < 0) return tr;

      final prev = _items[prevIdx];
      final widthA = _measureWidth(prevIdx, prev, measureWidth);
      final tA = prev.timeSeconds;
      final endA = tA + dur;
      if (endA < earliestPrevEnd) {
        earliestPrevEnd = endA;
        bestFallbackTrack = tr;
      }

      if (tB >= endA) return tr;

      final vA = (viewportWidth + widthA) / dur;
      final rightAatStartB = viewportWidth - vA * (tB - tA) + widthA;
      final hasEntered = rightAatStartB < (viewportWidth - _minScrollGap);
      final willNotCatchUp = (tB + timeToReachLeftB) >= endA;
      if (hasEntered && willNotCatchUp) {
        return tr;
      }
    }

    return _allowStacking ? bestFallbackTrack : -1;
  }

  int _pickStaticTrack(DanmakuCommentItem item, int tracks, List<int> lastStatic) {
    final tB = item.timeSeconds;
    var bestFallbackTrack = 0;
    var earliestEnd = double.infinity;

    for (var tr = 0; tr < tracks; tr++) {
      final prevIdx = lastStatic[tr];
      if (prevIdx < 0) return tr;
      final endA = _items[prevIdx].timeSeconds + _staticDurationSeconds;
      if (tB >= endA) return tr;
      if (endA < earliestEnd) {
        earliestEnd = endA;
        bestFallbackTrack = tr;
      }
    }

    return _allowStacking ? bestFallbackTrack : -1;
  }

  static int _lowerBound(List<double> arr, double target) {
    var lo = 0;
    var hi = arr.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (arr[mid] < target) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  static int _upperBound(List<double> arr, double target) {
    var lo = 0;
    var hi = arr.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (arr[mid] <= target) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }
}
