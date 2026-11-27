import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:clock/clock.dart';

import '../../mpv/mpv.dart';
import '../../utils/app_logger.dart';

/// Periodically samples player cache, decoder, and Dart isolate lag metrics
/// into [appLogger] so playback stalls can be attributed to network/CDN
/// throttling, soft-decode bottlenecks, or UI isolate stalls.
class PlaybackDiagnosticsLogger {
  PlaybackDiagnosticsLogger({
    required this.player,
    this.sampleInterval = const Duration(seconds: 15),
    this.stallThreshold = const Duration(milliseconds: 1500),
    this.stallMinGap = const Duration(seconds: 5),
    this.heartbeatInterval = const Duration(seconds: 1),
    this.lagSpikeThresholdMs = 200,
  });

  final Player player;
  final Duration sampleInterval;
  final Duration stallThreshold;
  final Duration stallMinGap;
  final Duration heartbeatInterval;
  final int lagSpikeThresholdMs;

  Timer? _heartbeatTimer;
  Timer? _stallTimer;
  bool _started = false;
  bool _disposed = false;
  bool _sampling = false;
  bool _isBuffering = false;

  late DateTime _lastTickAt;
  late DateTime _lastSampleAt;
  DateTime? _lastStallLogAt;
  int _windowMaxLoopLagMs = 0;
  int _windowLagSpikes = 0;

  /// Begins the 1s event-loop-lag heartbeat and periodic playback sampling.
  void start() {
    if (_disposed || _started) return;
    _started = true;
    final now = clock.now();
    _lastTickAt = now;
    _lastSampleAt = now;
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) => _onHeartbeat());
  }

  /// Notifies the logger when player buffering state changes so sustained stalls
  /// exceeding [stallThreshold] emit an immediate diagnostic snapshot.
  void onBufferingChanged(bool isBuffering) {
    if (_disposed || player.disposed || _isBuffering == isBuffering) return;
    _isBuffering = isBuffering;
    _stallTimer?.cancel();
    _stallTimer = null;
    if (!isBuffering) return;

    _stallTimer = Timer(stallThreshold, () {
      _stallTimer = null;
      if (_disposed || player.disposed || !_isBuffering) return;
      final now = clock.now();
      final lastStall = _lastStallLogAt;
      if (lastStall != null && now.difference(lastStall) < stallMinGap) return;
      unawaited(_sample('stall'));
    });
  }

  /// Stops all timers and prevents further sampling.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _stallTimer?.cancel();
    _stallTimer = null;
  }

  void _onHeartbeat() {
    if (_disposed || player.disposed) {
      dispose();
      return;
    }
    final now = clock.now();
    final lagMs = max(0, now.difference(_lastTickAt).inMilliseconds - heartbeatInterval.inMilliseconds);
    _lastTickAt = now;
    if (lagMs > _windowMaxLoopLagMs) _windowMaxLoopLagMs = lagMs;
    if (lagMs >= lagSpikeThresholdMs) _windowLagSpikes++;

    final active = player.state.playing || _isBuffering;
    if (active && !_sampling && now.difference(_lastSampleAt) >= sampleInterval) {
      unawaited(_sample('periodic'));
    }
  }

  Future<void> _sample(String reason) async {
    if (_disposed || player.disposed || _sampling) return;
    _sampling = true;
    final lagMax = _windowMaxLoopLagMs;
    final spikes = _windowLagSpikes;
    _windowMaxLoopLagMs = 0;
    _windowLagSpikes = 0;
    final now = clock.now();
    _lastSampleAt = now;
    if (reason == 'stall') _lastStallLogAt = now;

    try {
      final line = player.providesNativeStats
          ? await _collectNativeStatsLine(reason: reason, lagMax: lagMax, spikes: spikes)
          : await _collectMpvPropertyLine(reason: reason, lagMax: lagMax, spikes: spikes);
      if (!_disposed && line != null) {
        appLogger.i(line);
      }
    } catch (e) {
      appLogger.d('Playback diag ($reason) failed: $e');
    } finally {
      _sampling = false;
    }
  }

  Future<String?> _collectNativeStatsLine({
    required String reason,
    required int lagMax,
    required int spikes,
  }) async {
    final stats = await player.getStats();
    if (_disposed || player.disposed) return null;
    final type = stats['playerType'] as String?;
    if (type == 'exoplayer') {
      final netMBs = _formatMBs(_parseDouble(stats['networkSpeedBytesPerSec']));
      final cacheMs = _parseDouble(stats['totalBufferedDurationMs']);
      final cacheSec = cacheMs != null ? (cacheMs / 1000.0).toStringAsFixed(1) : '-';
      final vMbps = _formatMbps(_parseDouble(stats['videoBitrate']));
      final dec = stats['videoDecoderName']?.toString() ?? '-';
      final drops = _parseInt(stats['videoDroppedFrames']);
      return 'Playback diag ($reason): backend=exoplayer playing=${player.state.playing} buf=$_isBuffering '
          'net=${netMBs}MB/s cache=${cacheSec}s vBitrate=${vMbps}Mbps dec=$dec '
          'drops=${drops ?? '-'} loopLagMax=${lagMax}ms spikes=$spikes';
    }
    return _formatMpvLine(
      reason: reason,
      cacheSpeedRaw: stats['cache-speed'],
      cacheDurationRaw: stats['demuxer-cache-duration'],
      cacheStateRaw: stats['demuxer-cache-state'],
      videoBitrateRaw: stats['video-bitrate'],
      hwdecRaw: stats['hwdec-current'],
      dropsRaw: stats['frame-drop-count'],
      decDropsRaw: stats['decoder-frame-drop-count'],
      lagMax: lagMax,
      spikes: spikes,
    );
  }

  Future<String?> _collectMpvPropertyLine({
    required String reason,
    required int lagMax,
    required int spikes,
  }) async {
    final values = await Future.wait([
      player.getProperty('cache-speed'),
      player.getProperty('demuxer-cache-duration'),
      player.getProperty('demuxer-cache-state'),
      player.getProperty('video-bitrate'),
      player.getProperty('hwdec-current'),
      player.getProperty('frame-drop-count'),
      player.getProperty('decoder-frame-drop-count'),
    ]);
    if (_disposed || player.disposed) return null;
    return _formatMpvLine(
      reason: reason,
      cacheSpeedRaw: values[0],
      cacheDurationRaw: values[1],
      cacheStateRaw: values[2],
      videoBitrateRaw: values[3],
      hwdecRaw: values[4],
      dropsRaw: values[5],
      decDropsRaw: values[6],
      lagMax: lagMax,
      spikes: spikes,
    );
  }

  String _formatMpvLine({
    required String reason,
    required dynamic cacheSpeedRaw,
    required dynamic cacheDurationRaw,
    required dynamic cacheStateRaw,
    required dynamic videoBitrateRaw,
    required dynamic hwdecRaw,
    required dynamic dropsRaw,
    required dynamic decDropsRaw,
    required int lagMax,
    required int spikes,
  }) {
    final cacheSpeedMBs = _formatMBs(_parseDouble(cacheSpeedRaw));
    final cacheDur = _parseDouble(cacheDurationRaw);
    final cacheSec = cacheDur != null ? cacheDur.toStringAsFixed(1) : '-';
    final fwBytes = _parseFwBytes(cacheStateRaw);
    final fwMiB = fwBytes != null ? (fwBytes / (1024 * 1024)).toStringAsFixed(1) : '-';
    final vMbps = _formatMbps(_parseDouble(videoBitrateRaw));
    final hwdecText = hwdecRaw?.toString();
    final hwdec = (hwdecText == null || hwdecText.isEmpty) ? '-' : hwdecText;
    final drops = _parseInt(dropsRaw);
    final decDrops = _parseInt(decDropsRaw);
    return 'Playback diag ($reason): backend=mpv playing=${player.state.playing} buf=$_isBuffering '
        'cacheSpeed=${cacheSpeedMBs}MB/s cache=${cacheSec}s fwBuf=${fwMiB}MiB '
        'vBitrate=${vMbps}Mbps hwdec=$hwdec drops=${drops ?? '-'} decDrops=${decDrops ?? '-'} '
        'loopLagMax=${lagMax}ms spikes=$spikes';
  }

  static String _formatMBs(double? bytesPerSec) =>
      bytesPerSec != null ? (bytesPerSec / (1024 * 1024)).toStringAsFixed(2) : '-';

  static String _formatMbps(double? bitsPerSec) =>
      bitsPerSec != null ? (bitsPerSec / 1000000.0).toStringAsFixed(1) : '-';

  static double? _parseDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  static int? _parseInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? double.tryParse(value)?.round();
    return null;
  }

  static int? _parseFwBytes(dynamic raw) {
    if (raw is Map) {
      return _parseInt(raw['fw-bytes']) ?? _parseInt(raw['total-bytes']);
    }
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          return _parseInt(decoded['fw-bytes']) ?? _parseInt(decoded['total-bytes']);
        }
      } catch (_) {}
      final match = RegExp(r'(?:fw-bytes|total-bytes)[:=](\d+)').firstMatch(raw);
      if (match != null) return int.tryParse(match[1]!);
    }
    return null;
  }
}
