import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:ttplay/mpv/mpv.dart';
import 'package:ttplay/screens/video_player/playback_diagnostics_logger.dart';
import 'package:ttplay/utils/app_logger.dart' as logging;

class _RecordingLogOutput extends LogOutput {
  final List<String> lines = [];

  @override
  void output(OutputEvent event) => lines.addAll(event.lines);
}

class _FakePlayer extends Fake implements Player {
  _FakePlayer({
    this.nativeStatsEnabled = false,
  });

  final bool nativeStatsEnabled;
  PlayerState currentState = const PlayerState();
  bool isDisposed = false;
  Map<String, dynamic> nativeStats = {};
  Map<String, String?> mpvProperties = {};

  @override
  bool get disposed => isDisposed;

  @override
  PlayerState get state => currentState;

  @override
  bool get providesNativeStats => nativeStatsEnabled;

  @override
  Future<Map<String, dynamic>> getStats() async => nativeStats;

  @override
  Future<String?> getProperty(String name) async => mpvProperties[name];
}

void main() {
  late Logger originalLogger;
  late _RecordingLogOutput logOutput;

  setUp(() {
    originalLogger = logging.appLogger;
    logOutput = _RecordingLogOutput();
    logging.appLogger = Logger(printer: SimplePrinter(), output: logOutput);
  });

  tearDown(() {
    logging.appLogger = originalLogger;
  });

  test('logs periodic MPV diagnostics only while active and resets lag window', () {
    fakeAsync((async) {
      final player = _FakePlayer()
        ..mpvProperties = {
          'cache-speed': '5242880', // 5.00 MB/s
          'demuxer-cache-duration': '12.5',
          'demuxer-cache-state': '{"fw-bytes":10485760}',
          'video-bitrate': '25000000', // 25.0 Mbps
          'hwdec-current': 'no',
          'frame-drop-count': '4',
          'decoder-frame-drop-count': '2',
        };
      final logger = PlaybackDiagnosticsLogger(
        player: player,
        sampleInterval: const Duration(seconds: 15),
        heartbeatInterval: const Duration(seconds: 1),
      )..start();

      // Paused & not buffering -> no periodic logs even after 20s.
      async.elapse(const Duration(seconds: 20));
      expect(logOutput.lines, isEmpty);

      // Become playing -> next heartbeat at/after 15s since start logs immediately, then every 15s.
      player.currentState = player.currentState.copyWith(playing: true);
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();

      final diagLines = logOutput.lines.where((l) => l.contains('Playback diag (periodic):')).toList();
      expect(diagLines, hasLength(1));
      expect(diagLines.single, contains('backend=mpv'));
      expect(diagLines.single, contains('cacheSpeed=5.00MB/s'));
      expect(diagLines.single, contains('cache=12.5s'));
      expect(diagLines.single, contains('fwBuf=10.0MiB'));
      expect(diagLines.single, contains('vBitrate=25.0Mbps'));
      expect(diagLines.single, contains('hwdec=no'));
      expect(diagLines.single, contains('drops=4 decDrops=2'));

      logger.dispose();
    });
  });

  test('logs stall only when buffering exceeds stallThreshold and throttles within stallMinGap', () {
    fakeAsync((async) {
      final player = _FakePlayer(nativeStatsEnabled: true)
        ..currentState = const PlayerState(playing: true)
        ..nativeStats = {
          'playerType': 'exoplayer',
          'networkSpeedBytesPerSec': 2 * 1024 * 1024,
          'totalBufferedDurationMs': 800,
          'videoBitrate': 18000000,
          'videoDecoderName': 'OMX.realtek.hevc',
          'videoDroppedFrames': 3,
        };
      final logger = PlaybackDiagnosticsLogger(
        player: player,
        sampleInterval: const Duration(seconds: 60),
        stallThreshold: const Duration(milliseconds: 1500),
        stallMinGap: const Duration(seconds: 5),
      )..start();

      // Short 1s buffer does not emit a stall log.
      logger.onBufferingChanged(true);
      async.elapse(const Duration(seconds: 1));
      logger.onBufferingChanged(false);
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(logOutput.lines.where((l) => l.contains('(stall)')), isEmpty);

      // Sustained 2s buffer emits one stall log with ExoPlayer fields.
      logger.onBufferingChanged(true);
      async.elapse(const Duration(seconds: 2));
      async.flushMicrotasks();
      expect(logOutput.lines.where((l) => l.contains('Playback diag (stall):')), hasLength(1));
      expect(logOutput.lines.last, contains('backend=exoplayer'));
      expect(logOutput.lines.last, contains('net=2.00MB/s'));
      expect(logOutput.lines.last, contains('cache=0.8s'));
      expect(logOutput.lines.last, contains('vBitrate=18.0Mbps'));
      expect(logOutput.lines.last, contains('dec=OMX.realtek.hevc'));
      expect(logOutput.lines.last, contains('drops=3'));

      // Another stall within 5s stallMinGap is throttled.
      logger.onBufferingChanged(false);
      async.elapse(const Duration(seconds: 1));
      logger.onBufferingChanged(true);
      async.elapse(const Duration(seconds: 2));
      async.flushMicrotasks();
      expect(logOutput.lines.where((l) => l.contains('Playback diag (stall):')), hasLength(1));

      // After stallMinGap elapses, a new stall logs again.
      logger.onBufferingChanged(false);
      async.elapse(const Duration(seconds: 5));
      logger.onBufferingChanged(true);
      async.elapse(const Duration(seconds: 2));
      async.flushMicrotasks();
      expect(logOutput.lines.where((l) => l.contains('Playback diag (stall):')), hasLength(2));

      logger.dispose();
    });
  });

  test('dispose cancels active timers and suppresses further logging', () {
    fakeAsync((async) {
      final player = _FakePlayer()..currentState = const PlayerState(playing: true);
      final logger = PlaybackDiagnosticsLogger(
        player: player,
        sampleInterval: const Duration(seconds: 2),
        stallThreshold: const Duration(seconds: 1),
      )..start();

      logger.onBufferingChanged(true);
      logger.dispose();

      async.elapse(const Duration(seconds: 10));
      async.flushMicrotasks();
      expect(logOutput.lines, isEmpty);
      expect(async.pendingTimers, isEmpty);
    });
  });
}
