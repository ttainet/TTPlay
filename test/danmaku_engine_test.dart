import 'dart:ui' show Color, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:ttplay/services/danmaku/danmaku_controller.dart';
import 'package:ttplay/services/danmaku/danmaku_models.dart';
import 'package:ttplay/widgets/danmaku/danmaku_engine.dart';

void main() {
  group('processDanmakuComments', () {
    test('filters blocked types, colors, and keywords and merges duplicates within 10s window', () {
      const white = Color(0xFFFFFFFF);
      const red = Color(0xFFFF0000);
      final raw = [
        const DanmakuCommentItem(cid: 1, timeSeconds: 12.0, mode: DanmakuMode.scroll, color: white, text: '前方高能'),
        const DanmakuCommentItem(cid: 2, timeSeconds: 5.0, mode: DanmakuMode.scroll, color: white, text: '前方高能'),
        const DanmakuCommentItem(cid: 3, timeSeconds: 8.0, mode: DanmakuMode.scroll, color: white, text: '  前方高能  '),
        const DanmakuCommentItem(cid: 4, timeSeconds: 20.0, mode: DanmakuMode.scroll, color: white, text: '前方高能'),
        const DanmakuCommentItem(cid: 5, timeSeconds: 6.0, mode: DanmakuMode.top, color: white, text: '顶部弹幕'),
        const DanmakuCommentItem(cid: 6, timeSeconds: 7.0, mode: DanmakuMode.bottom, color: white, text: '底部弹幕'),
        const DanmakuCommentItem(cid: 7, timeSeconds: 9.0, mode: DanmakuMode.scroll, color: red, text: '彩色弹幕'),
        const DanmakuCommentItem(cid: 8, timeSeconds: 10.0, mode: DanmakuMode.scroll, color: white, text: '包含剧透内容'),
      ];

      final processed = processDanmakuComments(
        raw,
        const DanmakuRenderSettings(blockTop: true, blockColor: true, blockedKeywords: ['剧透'], mergeDuplicates: true),
      );

      expect(processed.length, 3);
      expect(processed[0].timeSeconds, 5.0);
      expect(processed[0].mergeCount, 3);
      expect(processed[0].displayText, '前方高能 ×3');
      expect(processed[1].timeSeconds, 7.0);
      expect(processed[1].mode, DanmakuMode.bottom);
      expect(processed[2].timeSeconds, 20.0);
      expect(processed[2].mergeCount, 1);
    });
  });

  group('DanmakuLayoutEngine', () {
    test('avoids scroll track collision and drops overflow when allowStacking is false', () {
      final engine = DanmakuLayoutEngine();
      engine.configure(
        size: const Size(800, 120),
        fontSize: 24,
        displayArea: 0.5, // usable height ~ 108 * 0.5 = 54, trackHeight = 32.4 -> 1 track
        scrollDurationSeconds: 10.0,
        allowStacking: false,
      );

      final items = [
        const DanmakuCommentItem(
          cid: 1,
          timeSeconds: 1.0,
          mode: DanmakuMode.scroll,
          color: Color(0xFFFFFFFF),
          text: '第一条弹幕很长很长',
        ),
        const DanmakuCommentItem(
          cid: 2,
          timeSeconds: 1.2,
          mode: DanmakuMode.scroll,
          color: Color(0xFFFFFFFF),
          text: '第二条紧跟',
        ),
        const DanmakuCommentItem(
          cid: 3,
          timeSeconds: 12.0,
          mode: DanmakuMode.scroll,
          color: Color(0xFFFFFFFF),
          text: '第三条错开',
        ),
      ];
      engine.setComments(items, 1);

      final at2s = engine.layoutAt(2.0, measureWidth: (_) => 200);
      expect(at2s.length, 1);
      expect(at2s.first.item.cid, 1);

      final at13s = engine.layoutAt(13.0, measureWidth: (_) => 200);
      expect(at13s.length, 1);
      expect(at13s.first.item.cid, 3);
    });

    test('places top and bottom static danmaku centered without overlap and supports stacking', () {
      final engine = DanmakuLayoutEngine();
      engine.configure(
        size: const Size(1000, 400),
        fontSize: 20,
        displayArea: 1.0,
        scrollDurationSeconds: 10.0,
        allowStacking: true,
        bottomMargin: 40,
      );

      final items = [
        const DanmakuCommentItem(
          cid: 1,
          timeSeconds: 5.0,
          mode: DanmakuMode.top,
          color: Color(0xFFFFFFFF),
          text: 'TOP1',
        ),
        const DanmakuCommentItem(
          cid: 2,
          timeSeconds: 5.5,
          mode: DanmakuMode.top,
          color: Color(0xFFFFFFFF),
          text: 'TOP2',
        ),
        const DanmakuCommentItem(
          cid: 3,
          timeSeconds: 6.0,
          mode: DanmakuMode.bottom,
          color: Color(0xFFFFFFFF),
          text: 'BOT1',
        ),
      ];
      engine.setComments(items, 1);

      final active = engine.layoutAt(7.0, measureWidth: (_) => 100);
      expect(active.length, 3);
      expect(active[0].x, 450);
      expect(active[0].trackIndex, 0);
      expect(active[1].x, 450);
      expect(active[1].trackIndex, 1);
      expect(active[2].x, 450);
      expect(active[2].y, greaterThan(active[1].y));

      // After 5s static duration expires, items disappear deterministically.
      final expired = engine.layoutAt(12.0, measureWidth: (_) => 100);
      expect(expired, isEmpty);
    });
  });
}
