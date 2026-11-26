import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';

import 'package:ttplay/database/app_database.dart';
import 'package:ttplay/focus/input_mode_tracker.dart';
import 'package:ttplay/i18n/strings.g.dart';
import 'package:ttplay/media/media_backend.dart';
import 'package:ttplay/media/media_item.dart';
import 'package:ttplay/media/media_kind.dart';
import 'package:ttplay/media/play_queue.dart';
import 'package:ttplay/mpv/mpv.dart';
import 'package:ttplay/providers/playback_state_provider.dart';
import 'package:ttplay/services/keyboard_shortcuts_service.dart';
import 'package:ttplay/services/settings_service.dart';
import 'package:ttplay/services/video_volume_controller.dart';
import 'package:ttplay/utils/platform_detector.dart';
import 'package:ttplay/widgets/video_controls/desktop_video_controls.dart';
import 'package:ttplay/widgets/video_controls/models/track_controls_state.dart';
import 'package:ttplay/widgets/video_controls/player_chrome_controller.dart';
import 'package:ttplay/widgets/video_controls/video_controls.dart';
import 'package:ttplay/widgets/video_controls/widgets/content_strip.dart';
import 'package:ttplay/widgets/video_controls/widgets/player_toast_indicator.dart';
import 'package:ttplay/widgets/video_controls/widgets/track_chapter_controls.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeTvPlayer player;
  late PlayerChromeController chrome;
  late PlayerToastController toast;
  late VideoVolumeController volume;
  late PlaybackStateProvider playbackState;
  late AppDatabase database;
  late ValueNotifier<bool> hasFirstFrame;
  late SettingsService settings;

  setUp(() async {
    LocaleSettings.setLocaleSync(AppLocale.en);
    await initializeDateFormatting('en');
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    settings = await SettingsService.getInstance();
    final shortcuts = await KeyboardShortcutsService.getInstance();
    addTearDown(shortcuts.dispose);

    TvDetectionService.debugSetAppleTVOverride(null);
    await TvDetectionService.getInstance(forceTv: true);
    TvDetectionService.setForceTVSync(true);
    PlatformDetector.debugSetIsDesktopOSOverride(false);
    await settings.write(SettingsService.videoPlayerNavigationEnabled, true);

    database = AppDatabase.forTesting(NativeDatabase.memory());
    player = _FakeTvPlayer();
    chrome = PlayerChromeController(initiallyVisible: false);
    toast = PlayerToastController();
    volume = VideoVolumeController(player: player, settings: settings, initialVolume: 100);
    playbackState = PlaybackStateProvider();
    hasFirstFrame = ValueNotifier<bool>(true);
  });

  tearDown(() async {
    TvDetectionService.debugSetAppleTVOverride(null);
    TvDetectionService.setForceTVSync(false);
    PlatformDetector.debugSetIsDesktopOSOverride(null);
    hasFirstFrame.dispose();
    volume.dispose();
    playbackState.dispose();
    chrome.dispose();
    toast.dispose();
    await player.close();
    await database.close();
  });

  MediaItem makeEpisode(String id, int index) {
    return testMediaItem(
      id: id,
      backend: MediaBackend.plex,
      kind: MediaKind.episode,
      title: 'Episode $index',
      grandparentTitle: 'Show',
      parentIndex: 1,
      index: index,
    );
  }

  Widget buildControlsTree(MediaItem metadata) {
    return InputModeTracker(
      child: MultiProvider(
        providers: [
          Provider<AppDatabase>.value(value: database),
          ChangeNotifierProvider<PlaybackStateProvider>.value(value: playbackState),
        ],
        child: MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android, extensions: const [testMonoTokens]),
          home: Scaffold(
            body: SizedBox(
              width: 1280,
              height: 720,
              child: PlexVideoControls(
                player: player,
                volumeController: volume,
                metadata: metadata,
                toastController: toast,
                chromeController: chrome,
                hasFirstFrame: hasFirstFrame,
                canNavigateMediaItems: true,
                canControl: true,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> pressKey(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(key);
    await tester.pump();
    await tester.sendKeyUpEvent(key);
    await tester.pumpAndSettle();
  }

  String? focusLabel() => FocusManager.instance.primaryFocus?.debugLabel;

  testWidgets('TV episode selection closes content strip, hides chrome, and resets next down press', (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final ep1 = makeEpisode('ep-1', 1);
    final ep2 = makeEpisode('ep-2', 2);
    playbackState.setPlaybackFromLocalQueue(LocalPlayQueue(currentIndex: 0, items: [ep1, ep2]));

    await tester.pumpWidget(buildControlsTree(ep1));
    await tester.pumpAndSettle();

    expect(chrome.controlsVisible, isFalse);
    expect(chrome.contentStripVisible, isFalse);

    // 1st D-pad Down: shows controls and focuses PlayPause.
    await pressKey(tester, LogicalKeyboardKey.arrowDown);
    expect(chrome.controlsVisible, isTrue);
    expect(chrome.contentStripVisible, isFalse);
    expect(focusLabel(), 'PlayPause');
    expect(find.byType(ContentStrip), findsNothing);

    // Held-down key repeat on PlayPause must not immediately open the strip.
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(chrome.contentStripVisible, isFalse);
    expect(find.byType(ContentStrip), findsNothing);

    // 2nd D-pad Down: opens ContentStrip and holds chrome visible.
    await pressKey(tester, LogicalKeyboardKey.arrowDown);
    expect(chrome.contentStripVisible, isTrue);
    expect(chrome.isHeld(PlayerChromeHold.contentStrip), isTrue);
    expect(find.byType(ContentStrip), findsOneWidget);

    // Move to episode 2 and select it.
    await pressKey(tester, LogicalKeyboardKey.arrowRight);
    await pressKey(tester, LogicalKeyboardKey.select);

    expect(chrome.contentStripVisible, isFalse);
    expect(chrome.isHeld(PlayerChromeHold.contentStrip), isFalse);
    expect(chrome.controlsVisible, isFalse);
    expect(find.byType(ContentStrip), findsNothing);

    // Simulate episode metadata updating in place to ep2 while chrome stays hidden.
    await tester.pumpWidget(buildControlsTree(ep2));
    await tester.pumpAndSettle();

    // Next D-pad Down must start from PlayPause again, not re-open ContentStrip.
    await pressKey(tester, LogicalKeyboardKey.arrowDown);
    expect(chrome.controlsVisible, isTrue);
    expect(chrome.contentStripVisible, isFalse);
    expect(focusLabel(), 'PlayPause');
    expect(find.byType(ContentStrip), findsNothing);

    // Pressing Down a second time opens ContentStrip normally.
    await pressKey(tester, LogicalKeyboardKey.arrowDown);
    expect(chrome.contentStripVisible, isTrue);
    expect(find.byType(ContentStrip), findsOneWidget);

    chrome.cancelAutoHide();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('TrackChapterControls ignores arrowDown KeyRepeatEvent for onNavigateDown', (tester) async {
    final nodes = List.generate(15, (i) => FocusNode(debugLabel: 'Track$i'));
    addTearDown(() {
      for (final node in nodes) {
        node.dispose();
      }
    });

    var downCount = 0;
    await tester.pumpWidget(
      InputModeTracker(
        child: MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android, extensions: const [testMonoTokens]),
          home: Scaffold(
            body: Center(
              child: TrackChapterControls(
                player: player,
                chapters: const [],
                chaptersLoaded: true,
                trackControlsState: const TrackControlsState(),
                focusNodes: nodes,
                onNavigateDown: () => downCount++,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    nodes.first.requestFocus();
    await tester.pump();

    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(downCount, 0);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(downCount, 1);
  });

  testWidgets('DesktopVideoControls resets _contentStripVisible when metadata changes', (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final ep1 = makeEpisode('ep-1', 1);
    final ep2 = makeEpisode('ep-2', 2);
    playbackState.setPlaybackFromLocalQueue(LocalPlayQueue(currentIndex: 0, items: [ep1, ep2]));

    Widget buildDesktop(MediaItem metadata) {
      return InputModeTracker(
        child: ChangeNotifierProvider<PlaybackStateProvider>.value(
          value: playbackState,
          child: MaterialApp(
            theme: ThemeData(platform: TargetPlatform.android, extensions: const [testMonoTokens]),
            home: Scaffold(
              body: SizedBox(
                width: 1280,
                height: 720,
                child: DesktopVideoControls(
                  player: player,
                  volumeController: volume,
                  metadata: metadata,
                  onPlayPause: () {},
                  chapters: const [],
                  chaptersLoaded: true,
                  seekTimeSmall: 10,
                  onSeekToPreviousChapter: () {},
                  onSeekToNextChapter: () {},
                  onSeek: (_) {},
                  onSeekEnd: (_) {},
                  getReplayIcon: (_) => Icons.replay_10,
                  getForwardIcon: (_) => Icons.forward_10,
                  useDpadNavigation: true,
                  showQueueTab: true,
                  onQueueItemSelected: (_) {},
                  chromeController: chrome,
                ),
              ),
            ),
          ),
        ),
      );
    }

    await tester.pumpWidget(buildDesktop(ep1));
    await tester.pumpAndSettle();

    tester.state<DesktopVideoControlsState>(find.byType(DesktopVideoControls)).requestPlayPauseFocus();
    await tester.pump();

    await pressKey(tester, LogicalKeyboardKey.arrowDown);
    expect(find.byType(ContentStrip), findsOneWidget);

    await tester.pumpWidget(buildDesktop(ep2));
    await tester.pumpAndSettle();
    expect(find.byType(ContentStrip), findsNothing);
  });
}

class _FakeTvPlayer implements Player {
  final StreamController<Duration> _positionController = StreamController<Duration>.broadcast();

  Future<void> close() => _positionController.close();

  @override
  String get playerType => 'mpv';

  @override
  PlayerState get state => PlayerState(playing: true, duration: const Duration(minutes: 45), seekable: true);

  @override
  PlayerStreams get streams => PlayerStreams(
    playing: const Stream<bool>.empty(),
    completed: const Stream<bool>.empty(),
    buffering: const Stream<bool>.empty(),
    position: _positionController.stream,
    duration: const Stream<Duration>.empty(),
    seekable: const Stream<bool>.empty(),
    buffer: const Stream<Duration>.empty(),
    volume: const Stream<double>.empty(),
    rate: const Stream<double>.empty(),
    tracks: const Stream<Tracks>.empty(),
    track: const Stream<TrackSelection>.empty(),
    log: const Stream<PlayerLog>.empty(),
    error: const Stream<PlayerError>.empty(),
    audioDevice: const Stream<AudioDevice>.empty(),
    audioDevices: const Stream<List<AudioDevice>>.empty(),
    bufferRanges: const Stream<List<BufferRange>>.empty(),
    playbackRestart: const Stream<void>.empty(),
    backendSwitched: const Stream<void>.empty(),
  );

  @override
  Future<void> setVolume(double volume) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
