import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ttplay/focus/focusable_slider.dart';
import 'package:ttplay/focus/input_mode_tracker.dart';
import 'package:ttplay/i18n/strings.g.dart';
import 'package:ttplay/services/danmaku/danmaku_controller.dart';
import 'package:ttplay/services/danmaku/danmaku_models.dart';
import 'package:ttplay/services/danmaku/danmaku_service.dart';
import 'package:ttplay/services/settings_service.dart';
import 'package:ttplay/widgets/focusable_list_tile.dart';
import 'package:ttplay/widgets/overlay_sheet.dart';
import 'package:ttplay/widgets/video_controls/sheets/danmaku_sheet.dart';

import '../test_helpers/prefs.dart';
import '../test_helpers/theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeDanmakuService service;
  late DanmakuController controller;

  setUp(() async {
    LocaleSettings.setLocaleSync(AppLocale.en);
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
    service = _FakeDanmakuService();
    controller = _TestDanmakuController(service: service);
  });

  tearDown(() {
    controller.dispose();
    service.close();
  });

  Widget wrapSheet() {
    return InputModeTracker(
      child: MaterialApp(
        theme: ThemeData.dark().copyWith(extensions: const [testMonoTokens]),
        home: Scaffold(
          body: SizedBox(width: 800, height: 700, child: DanmakuSheet(controller: controller)),
        ),
      ),
    );
  }

  testWidgets('D-pad tab bar switches across Display, Filter, and Source tabs', (tester) async {
    await tester.pumpWidget(wrapSheet());
    await tester.pumpAndSettle();

    expect(find.text(t.danmaku.enabled), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text(t.danmaku.blockScroll), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text(t.danmaku.searchButton), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text(t.danmaku.enabled), findsOneWidget);
  });

  testWidgets('D-pad enter toggles FocusableSwitchListTile and FocusableSlider responds to left/right', (tester) async {
    await tester.pumpWidget(wrapSheet());
    await tester.pumpAndSettle();

    final enabledTileText = find.descendant(
      of: find.widgetWithText(FocusableSwitchListTile, t.danmaku.enabled),
      matching: find.text(t.danmaku.enabled),
    );
    Focus.of(tester.element(enabledTileText)).requestFocus();
    await tester.pump();

    expect(controller.enabled, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(controller.enabled, isTrue);

    final initialFontSize = controller.settings.fontSize;
    final sliderFinder = find.byType(FocusableSlider).first;
    final sliderFocus = tester.widget<FocusableSlider>(sliderFinder).focusNode!;
    sliderFocus.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(controller.settings.fontSize, initialFontSize + 1.0);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(controller.settings.fontSize, initialFontSize);
  });

  testWidgets('D-pad enter on display area chip updates displayArea setting', (tester) async {
    await tester.pumpWidget(wrapSheet());
    await tester.pumpAndSettle();

    final fullChip = find.text(t.danmaku.areaFull);
    final focusNode = Focus.of(tester.element(fullChip));
    focusNode.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(controller.settings.displayArea, 1.0);
  });

  testWidgets('selecting an episode in OverlaySheetHost closes only the sheet without popping underlying route', (
    tester,
  ) async {
    late OverlaySheetController sheetController;
    var routePopped = false;

    await tester.pumpWidget(
      InputModeTracker(
        child: MaterialApp(
          theme: ThemeData.dark().copyWith(extensions: const [testMonoTokens]),
          home: PopScope(
            onPopInvokedWithResult: (didPop, _) => routePopped = didPop,
            child: OverlaySheetHost(
              child: Scaffold(
                body: Builder(
                  builder: (context) {
                    sheetController = OverlaySheetController.of(context);
                    return const Text('player-host');
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    unawaited(sheetController.show(builder: (_) => DanmakuSheet(controller: controller)));
    await tester.pumpAndSettle();
    expect(sheetController.isOpen, isTrue);

    await tester.tap(find.text(t.danmaku.tabSource));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Test Anime');
    await tester.tap(find.text(t.danmaku.searchButton));
    await tester.pumpAndSettle();

    await tester.tap(find.descendant(of: find.byType(FocusableListTile), matching: find.text('Test Anime')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Episode 1'));
    await tester.pumpAndSettle();

    expect(sheetController.isOpen, isFalse);
    expect(routePopped, isFalse);
    expect(find.text('player-host'), findsOneWidget);
  });
}

class _TestDanmakuController extends DanmakuController {
  _TestDanmakuController({required DanmakuService service}) : super(service: service);

  @override
  DanmakuServerConfig? resolveEndpoint() => const DanmakuServerConfig(serverUrl: 'https://danmu.example.com');
}

class _FakeDanmakuService extends DanmakuService {
  @override
  Future<List<DanmakuAnimeItem>> searchAnime(
    DanmakuServerConfig endpoint,
    String keyword, {
    bool refresh = false,
  }) async {
    return const [DanmakuAnimeItem(animeId: 'anime-1', animeTitle: 'Test Anime', episodeCount: 12)];
  }

  @override
  Future<DanmakuBangumiDetail> getBangumi(DanmakuServerConfig endpoint, String animeId, {bool refresh = false}) async {
    return const DanmakuBangumiDetail(
      animeId: 'anime-1',
      animeTitle: 'Test Anime',
      episodes: [DanmakuBangumiEpisode(episodeId: 'ep-1', episodeTitle: 'Episode 1', episodeNumber: '1')],
    );
  }

  @override
  Future<DanmakuCommentsResponse> getComments(
    DanmakuServerConfig endpoint, {
    String? episodeId,
    String? sourceUrl,
    int limit = 10000,
    bool refresh = false,
  }) async {
    return DanmakuCommentsResponse(
      episodeId: episodeId ?? '',
      sourceUrl: sourceUrl ?? '',
      count: 0,
      totalCount: 0,
      sampled: false,
      videoDuration: 0,
      cached: false,
      comments: const [],
    );
  }
}
