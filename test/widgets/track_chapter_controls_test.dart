import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:ttplay/focus/input_mode_tracker.dart';
import 'package:ttplay/i18n/strings.g.dart';
import 'package:ttplay/media/stream_quality.dart';
import 'package:ttplay/mpv/mpv.dart';
import 'package:ttplay/services/danmaku/danmaku_controller.dart';
import 'package:ttplay/services/settings_service.dart';
import 'package:ttplay/services/video_volume_controller.dart';
import 'package:ttplay/utils/platform_detector.dart';
import 'package:ttplay/utils/quality_preset_labels.dart';
import 'package:ttplay/widgets/danmaku/danmaku_badge_icon.dart';
import 'package:ttplay/widgets/system_clock.dart';
import 'package:ttplay/widgets/video_controls/desktop_video_controls.dart';
import 'package:ttplay/widgets/video_controls/models/track_controls_state.dart';
import 'package:ttplay/widgets/video_controls/video_control_button.dart';
import 'package:ttplay/widgets/video_controls/widgets/track_chapter_controls.dart';
import 'package:ttplay/widgets/video_controls/widgets/video_controls_header.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/player_streams.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsService settings;
  late _FakeTrackPlayer player;
  late DanmakuController danmakuController;
  late VideoVolumeController volumeController;

  setUp(() async {
    await LocaleSettings.setLocale(AppLocale.zh);
    await initializeDateFormatting('zh');
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    settings = await SettingsService.getInstance();

    TvDetectionService.debugSetAppleTVOverride(false);
    PlatformDetector.debugSetIsDesktopOSOverride(true);

    player = _FakeTrackPlayer();
    danmakuController = DanmakuController();
    volumeController = VideoVolumeController(player: player, settings: settings, initialVolume: 100);
  });

  tearDown(() {
    TvDetectionService.debugSetAppleTVOverride(null);
    PlatformDetector.debugSetIsDesktopOSOverride(null);
    volumeController.dispose();
    danmakuController.dispose();
  });

  TrackControlsState buildState({
    int boxFitMode = 0,
    bool isAlwaysOnTop = false,
    bool isFullscreen = false,
    bool withQualities = true,
  }) {
    return TrackControlsState(
      danmakuSupported: true,
      danmakuController: danmakuController,
      streamQualities: withQualities
          ? const [
              StreamQuality(id: 'high', width: 1920, height: 1080),
              StreamQuality(id: 'original', width: 3840, height: 2160),
            ]
          : const [],
      selectedStreamQuality: 'high',
      onSwitchStreamQuality: (_) async {},
      showQueueButton: true,
      onQueueItemSelected: (_) {},
      onRemoteHandoff: (_) async {},
      onCycleBoxFitMode: () {},
      boxFitMode: boxFitMode,
      onToggleAlwaysOnTop: () {},
      isAlwaysOnTop: isAlwaysOnTop,
      onToggleFullscreen: () {},
      isFullscreen: isFullscreen,
    );
  }

  Widget wrapControls({
    required TrackControlsState state,
    TargetPlatform platform = TargetPlatform.windows,
    List<FocusNode>? focusNodes,
    VoidCallback? onNavigateLeft,
  }) {
    return InputModeTracker(
      child: MaterialApp(
        theme: ThemeData(platform: platform, extensions: const [testMonoTokens]),
        home: Scaffold(
          body: Center(
            child: TrackChapterControls(
              player: player,
              chapters: const [],
              chaptersLoaded: true,
              trackControlsState: state,
              focusNodes: focusNodes,
              onNavigateLeft: onNavigateLeft,
            ),
          ),
        ),
      ),
    );
  }

  Widget wrapDesktopControls({
    required WidgetTester tester,
    required TrackControlsState state,
    TargetPlatform platform = TargetPlatform.windows,
  }) {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    return InputModeTracker(
      child: MaterialApp(
        theme: ThemeData(platform: platform, extensions: const [testMonoTokens]),
        home: Scaffold(
          body: SizedBox(
            width: 1280,
            height: 720,
            child: DesktopVideoControls(
              player: player,
              volumeController: volumeController,
              metadata: testMediaItem(id: 'desktop-top-actions', title: 'Desktop Top Actions'),
              chapters: const [],
              chaptersLoaded: true,
              seekTimeSmall: 10,
              onSeekToPreviousChapter: () {},
              onSeekToNextChapter: () {},
              onSeek: (_) {},
              onSeekEnd: (_) {},
              onPlayPause: () {},
              getReplayIcon: (_) => Symbols.replay_10_rounded,
              getForwardIcon: (_) => Symbols.forward_10_rounded,
              useDpadNavigation: false,
              trackControlsState: state,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('renders Scheme A bottom controls on desktop without cast or always-on-top', (tester) async {
    await tester.pumpWidget(wrapControls(state: buildState()));
    await tester.pump();

    expect(find.byType(DanmakuBadgeIcon), findsOneWidget);
    expect(DanmakuBadgeIcon.glyphForLocale(AppLocale.zh), '弹');
    expect(DanmakuBadgeIcon.glyphForLocale(AppLocale.zhHant), '彈');
    expect(DanmakuBadgeIcon.glyphForLocale(AppLocale.en), 'DM');

    expect(find.byIcon(Symbols.tune_rounded), findsOneWidget);
    expect(find.byIcon(Symbols.high_quality_rounded), findsNothing);
    final qualityLabel = streamQualityName('high');
    expect(find.text(qualityLabel), findsOneWidget);
    final qualityPillWidth = tester
        .getSize(find.ancestor(of: find.text(qualityLabel), matching: find.byType(VideoControlButton)))
        .width;
    expect(qualityPillWidth, lessThan(80), reason: 'quality chip should shrink-wrap its text label');
    expect(tester.widget<Icon>(find.byIcon(Symbols.settings_rounded)).weight, 700);
    expect(find.byIcon(Symbols.closed_caption_rounded), findsOneWidget);
    expect(find.byIcon(Symbols.playlist_play_rounded), findsOneWidget);
    expect(find.byIcon(Symbols.settings_rounded), findsOneWidget);
    expect(find.byIcon(Symbols.aspect_ratio_rounded), findsOneWidget);
    expect(find.byIcon(Symbols.fullscreen_rounded), findsOneWidget);

    expect(find.byIcon(Symbols.cast_rounded), findsNothing);
    expect(find.byIcon(Symbols.keep_rounded), findsNothing);
  });

  testWidgets('desktop places cast and always-on-top in top-right left of clock', (tester) async {
    await tester.pumpWidget(wrapDesktopControls(tester: tester, state: buildState(isAlwaysOnTop: false)));
    await tester.pump();

    final castInHeader = find.descendant(
      of: find.byType(VideoControlsHeader),
      matching: find.byIcon(Symbols.cast_rounded),
    );
    final pinInHeader = find.descendant(
      of: find.byType(VideoControlsHeader),
      matching: find.byIcon(Symbols.keep_rounded),
    );
    final castInBottom = find.descendant(
      of: find.byType(TrackChapterControls),
      matching: find.byIcon(Symbols.cast_rounded),
    );
    final pinInBottom = find.descendant(
      of: find.byType(TrackChapterControls),
      matching: find.byIcon(Symbols.keep_rounded),
    );

    expect(castInHeader, findsOneWidget);
    expect(pinInHeader, findsOneWidget);
    expect(castInBottom, findsNothing);
    expect(pinInBottom, findsNothing);

    final castRect = tester.getRect(castInHeader);
    final pinRect = tester.getRect(pinInHeader);
    final clockRect = tester.getRect(find.byType(SystemClock));
    expect(castRect.right, lessThanOrEqualTo(pinRect.left));
    expect(pinRect.right, lessThanOrEqualTo(clockRect.left));

    final offIcon = tester.widget<Icon>(pinInHeader);
    final offTransform = tester.widget<Transform>(
      find.ancestor(of: pinInHeader, matching: find.byType(Transform)).first,
    );
    expect(offIcon.fill, 1);
    expect(offIcon.weight, 700);
    expect(offIcon.color, Colors.white);
    expect(offTransform.transform, isNot(equals(Matrix4.identity())));

    await tester.pumpWidget(wrapDesktopControls(tester: tester, state: buildState(isAlwaysOnTop: true)));
    await tester.pump();
    final onIcon = tester.widget<Icon>(pinInHeader);
    final onTransform = tester.widget<Transform>(
      find.ancestor(of: pinInHeader, matching: find.byType(Transform)).first,
    );
    expect(onIcon.fill, 1);
    expect(onIcon.weight, 700);
    expect(onIcon.color, Colors.amber);
    expect(onTransform.transform, equals(Matrix4.identity()));

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('mobile top-right controls show cast without always-on-top', (tester) async {
    PlatformDetector.debugSetIsDesktopOSOverride(false);
    TvDetectionService.debugSetAppleTVOverride(false);

    await tester.pumpWidget(wrapControls(state: buildState(), platform: TargetPlatform.android));
    await tester.pump();

    expect(find.byIcon(Symbols.cast_rounded), findsOneWidget);
    expect(find.byIcon(Symbols.keep_rounded), findsNothing);
  });

  testWidgets('TV hides both cast and always-on-top across header and bottom bar', (tester) async {
    PlatformDetector.debugSetIsDesktopOSOverride(false);
    TvDetectionService.debugSetAppleTVOverride(true);

    await tester.pumpWidget(wrapDesktopControls(tester: tester, state: buildState(), platform: TargetPlatform.android));
    await tester.pump();

    expect(find.byIcon(Symbols.cast_rounded), findsNothing);
    expect(find.byIcon(Symbols.keep_rounded), findsNothing);
    expect(find.byType(SystemClock), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('renders distinct outline boxFit icons per mode', (tester) async {
    await tester.pumpWidget(wrapControls(state: buildState(boxFitMode: 0)));
    await tester.pump();
    expect(find.byIcon(Symbols.aspect_ratio_rounded), findsOneWidget);

    await tester.pumpWidget(wrapControls(state: buildState(boxFitMode: 1)));
    await tester.pump();
    expect(find.byIcon(Symbols.zoom_out_map_rounded), findsOneWidget);

    await tester.pumpWidget(wrapControls(state: buildState(boxFitMode: 2)));
    await tester.pump();
    expect(find.byIcon(Symbols.settings_overscan_rounded), findsOneWidget);
  });

  testWidgets('D-pad left/right traverses all 8 desktop bottom-bar buttons across Danmaku pill and group dividers', (
    tester,
  ) async {
    final nodes = List.generate(12, (i) => FocusNode(debugLabel: 'track_$i'));
    addTearDown(() {
      for (final node in nodes) {
        node.dispose();
      }
    });
    var navigatedLeft = 0;

    await tester.pumpWidget(
      wrapControls(state: buildState(), focusNodes: nodes, onNavigateLeft: () => navigatedLeft++),
    );
    await tester.pump();

    // Expected 8 focusable buttons in desktop bottom bar:
    // 0: Danmaku toggle, 1: Danmaku settings, 2: Quality pill, 3: Tracks,
    // 4: Queue, 5: Settings, 6: BoxFit, 7: Fullscreen.
    nodes[0].requestFocus();
    await tester.pump();
    expect(nodes[0].hasPrimaryFocus, isTrue);

    for (var expected = 1; expected < 8; expected++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(nodes[expected].hasPrimaryFocus, isTrue, reason: 'Expected focus on button index $expected');
    }

    // Pressing arrowRight on the last button stays clamped on index 7.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(nodes[7].hasPrimaryFocus, isTrue);

    for (var expected = 6; expected >= 0; expected--) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(nodes[expected].hasPrimaryFocus, isTrue, reason: 'Expected focus back on button index $expected');
    }

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(navigatedLeft, 1);
  });
}

class _FakeTrackPlayer implements Player {
  @override
  String get playerType => 'mpv';

  @override
  PlayerState get state => PlayerState(
    tracks: Tracks(
      subtitle: [SubtitleTrack(id: 'sub-1', title: '中文', language: 'zh')],
    ),
    track: const TrackSelection(),
  );

  @override
  PlayerStreams get streams => emptyPlayerStreams();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
