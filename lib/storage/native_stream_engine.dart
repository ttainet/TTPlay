import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import '../utils/app_logger.dart';
import 'direct_url_source.dart';

typedef _RefreshNativeFn = Void Function(Pointer<Uint8>, Uint64);
typedef _StartNative = Pointer<Void> Function(Pointer<NativeFunction<_RefreshNativeFn>>);
typedef _StartDart = Pointer<Void> Function(Pointer<NativeFunction<_RefreshNativeFn>>);

typedef _PortNative = Uint16 Function(Pointer<Void>);
typedef _PortDart = int Function(Pointer<Void>);

typedef _RegisterNative = Int32 Function(Pointer<Void>, Pointer<Uint8>);
typedef _RegisterDart = int Function(Pointer<Void>, Pointer<Uint8>);

typedef _UpdateLinkNative = Int32 Function(Pointer<Void>, Pointer<Uint8>, Uint64, Pointer<Uint8>);
typedef _UpdateLinkDart = int Function(Pointer<Void>, Pointer<Uint8>, int, Pointer<Uint8>);

typedef _UpdateDemandNative = Int32 Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint8>);
typedef _UpdateDemandDart = int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint8>);

typedef _UnregisterNative = Int32 Function(Pointer<Void>, Pointer<Uint8>);
typedef _UnregisterDart = int Function(Pointer<Void>, Pointer<Uint8>);

typedef _PollStatsNative = Pointer<Uint8> Function(Pointer<Void>);
typedef _PollStatsDart = Pointer<Uint8> Function(Pointer<Void>);

typedef _PeekStatusNative = Pointer<Uint8> Function(Pointer<Void>, Pointer<Uint8>);
typedef _PeekStatusDart = Pointer<Uint8> Function(Pointer<Void>, Pointer<Uint8>);

typedef _StopNative = Void Function(Pointer<Void>);
typedef _StopDart = void Function(Pointer<Void>);

typedef _StringFreeNative = Void Function(Pointer<Uint8>);
typedef _StringFreeDart = void Function(Pointer<Uint8>);

typedef _BytesAllocNative = Pointer<Uint8> Function(Size);
typedef _BytesAllocDart = Pointer<Uint8> Function(int);

typedef _BytesFreeNative = Void Function(Pointer<Uint8>, Size);
typedef _BytesFreeDart = void Function(Pointer<Uint8>, int);

typedef DirectLinkResolver = Future<DirectPlaybackSource> Function({required bool forceRefresh});

/// Live non-destructive concurrency snapshot of an active native stream.
class NativeStreamStatus {
  const NativeStreamStatus({
    required this.activeConns,
    required this.targetConns,
    required this.maxConns,
    required this.cacheBytes,
  });

  final int activeConns;
  final int targetConns;
  final int maxConns;
  final int cacheBytes;
}

/// FFI bridge to the cross-platform Rust streaming data plane (`ttplay_stream`).
///
/// Owns a local `127.0.0.1` HTTP Range server running on multi-threaded Tokio
/// workers while delegating drive-specific link refreshes back to Dart.
class NativeStreamEngine {
  NativeStreamEngine._(DynamicLibrary lib, {this.statsLogInterval = const Duration(seconds: 15)})
    : _portFn = lib.lookupFunction<_PortNative, _PortDart>('ttplay_engine_port'),
      _registerFn = lib.lookupFunction<_RegisterNative, _RegisterDart>('ttplay_engine_register_stream'),
      _updateLinkFn = lib.lookupFunction<_UpdateLinkNative, _UpdateLinkDart>('ttplay_engine_update_link'),
      _updateDemandFn = lib.lookupFunction<_UpdateDemandNative, _UpdateDemandDart>('ttplay_engine_update_demand'),
      _unregisterFn = lib.lookupFunction<_UnregisterNative, _UnregisterDart>('ttplay_engine_unregister_stream'),
      _pollStatsFn = lib.lookupFunction<_PollStatsNative, _PollStatsDart>('ttplay_engine_poll_stats'),
      _peekStatusFn = lib.lookupFunction<_PeekStatusNative, _PeekStatusDart>('ttplay_engine_peek_status'),
      _stopFn = lib.lookupFunction<_StopNative, _StopDart>('ttplay_engine_stop'),
      _stringFreeFn = lib.lookupFunction<_StringFreeNative, _StringFreeDart>('ttplay_string_free'),
      _bytesAllocFn = lib.lookupFunction<_BytesAllocNative, _BytesAllocDart>('ttplay_bytes_alloc'),
      _bytesFreeFn = lib.lookupFunction<_BytesFreeNative, _BytesFreeDart>('ttplay_bytes_free') {
    final startFn = lib.lookupFunction<_StartNative, _StartDart>('ttplay_engine_start');
    _refreshCallable = NativeCallable<_RefreshNativeFn>.listener(_onRefreshSignal);
    _engine = startFn(_refreshCallable.nativeFunction);
    if (_engine == nullptr) {
      _refreshCallable.close();
      throw StateError('ttplay_engine_start returned null');
    }
    port = _portFn(_engine);
    if (port == 0) {
      _stopFn(_engine);
      _refreshCallable.close();
      throw StateError('ttplay_engine_port returned 0');
    }
  }

  /// Loads `ttplay_stream` and starts its background runtime.
  /// Throws a [StateError] if the native library cannot be loaded or started.
  static NativeStreamEngine create({
    String? libraryPathOverride,
    Duration statsLogInterval = const Duration(seconds: 15),
  }) {
    final candidates = _candidatePaths(libraryPathOverride: libraryPathOverride);
    final lib = _openLibrary(candidates);
    if (lib == null) {
      throw StateError('Failed to load ttplay_stream native library (tried: ${candidates.join(', ')})');
    }
    return NativeStreamEngine._(lib, statsLogInterval: statsLogInterval);
  }

  static List<String> _candidatePaths({String? libraryPathOverride}) {
    if (libraryPathOverride != null && libraryPathOverride.isNotEmpty) {
      return [libraryPathOverride];
    }
    return _platformCandidates();
  }

  static DynamicLibrary? _openLibrary(List<String> candidates) {
    for (final candidate in candidates) {
      try {
        return DynamicLibrary.open(candidate);
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  static List<String> _platformCandidates() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final cwd = Directory.current.path;
    if (Platform.isWindows) {
      return [
        '$exeDir\\ttplay_stream.dll',
        'ttplay_stream.dll',
        '$cwd\\native\\ttplay_stream\\target\\release\\ttplay_stream.dll',
        '$cwd\\native\\ttplay_stream\\target\\debug\\ttplay_stream.dll',
      ];
    }
    if (Platform.isAndroid) {
      return ['libttplay_stream.so'];
    }
    if (Platform.isLinux) {
      return [
        '$exeDir/lib/libttplay_stream.so',
        'libttplay_stream.so',
        '$cwd/native/ttplay_stream/target/release/libttplay_stream.so',
      ];
    }
    if (Platform.isMacOS) {
      return [
        '$exeDir/../Frameworks/libttplay_stream.dylib',
        'libttplay_stream.dylib',
        '$cwd/native/ttplay_stream/target/release/libttplay_stream.dylib',
      ];
    }
    return const [];
  }

  final _PortDart _portFn;
  final _RegisterDart _registerFn;
  final _UpdateLinkDart _updateLinkFn;
  final _UpdateDemandDart _updateDemandFn;
  final _UnregisterDart _unregisterFn;
  final _PollStatsDart _pollStatsFn;
  final _PeekStatusDart _peekStatusFn;
  final _StopDart _stopFn;
  final _StringFreeDart _stringFreeFn;
  final _BytesAllocDart _bytesAllocFn;
  final _BytesFreeDart _bytesFreeFn;

  final Duration statsLogInterval;
  late final NativeCallable<_RefreshNativeFn> _refreshCallable;
  late final Pointer<Void> _engine;
  late final int port;

  final Map<String, DirectLinkResolver> _refreshHandlers = {};
  Timer? _statsTimer;
  bool _disposed = false;

  /// Registers or updates a stream identified by [token] and returns its
  /// local loopback URL (`http://127.0.0.1:<port>/s/<token>/<fileName>`).
  Uri registerStream({
    required String token,
    required DirectPlaybackSource source,
    required String fileName,
    required DirectLinkResolver onRefresh,
  }) {
    if (_disposed) throw StateError('NativeStreamEngine has been stopped');
    final payload = jsonEncode({
      'token': token,
      'total_size': source.totalSize,
      if (source.contentType != null) 'content_type': source.contentType,
      'url': source.link.url.toString(),
      'headers': source.link.headers,
      'profile': source.profile.toJson(),
    });
    final rc = _withUtf8(payload, (ptr) => _registerFn(_engine, ptr));
    if (rc != 0) {
      throw StateError('ttplay_engine_register_stream failed with code $rc');
    }
    _refreshHandlers[token] = onRefresh;
    _ensureStatsTimer();
    return Uri(
      scheme: 'http',
      host: InternetAddress.loopbackIPv4.address,
      port: port,
      pathSegments: ['s', token, fileName],
    );
  }

  /// Removes a stream and cancels its active native background workers.
  void unregisterStream(String token) {
    if (_disposed) return;
    _refreshHandlers.remove(token);
    _withUtf8(token, (ptr) => _unregisterFn(_engine, ptr));
    if (_refreshHandlers.isEmpty) {
      _statsTimer?.cancel();
      _statsTimer = null;
    }
  }

  /// Extracts the active native stream token for a loopback [url], or `null`
  /// if [url] is not currently served by this engine.
  String? tokenForUrl(String? url) {
    if (_disposed || url == null || url.isEmpty) return null;
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'http' ||
        uri.host != InternetAddress.loopbackIPv4.address ||
        uri.port != port ||
        uri.pathSegments.length < 2 ||
        uri.pathSegments[0] != 's') {
      return null;
    }
    final token = uri.pathSegments[1];
    return _refreshHandlers.containsKey(token) ? token : null;
  }

  /// Pushes real-time playback demand or deferred tier limits to Rust.
  void updateDemand({
    required String token,
    bool? playbackStarted,
    int? bitrateBps,
    double? bufferedSecs,
    bool? isBuffering,
    int? maxConnections,
  }) {
    if (_disposed || !_refreshHandlers.containsKey(token)) return;
    final payload = <String, Object?>{
      'playback_started': ?playbackStarted,
      'bitrate_bps': ?bitrateBps,
      'buffered_secs': ?bufferedSecs,
      'is_buffering': ?isBuffering,
      'max_connections': ?maxConnections,
    };
    if (payload.isEmpty) return;
    final jsonStr = jsonEncode(payload);
    _withUtf8(token, (tokenPtr) => _withUtf8(jsonStr, (jsonPtr) => _updateDemandFn(_engine, tokenPtr, jsonPtr)));
  }

  /// Drains rolling telemetry snapshots for all active streams.
  List<Map<String, dynamic>> pollStats() {
    if (_disposed) return const [];
    final ptr = _pollStatsFn(_engine);
    if (ptr == nullptr) return const [];
    final jsonText = _readAndFreeRustString(ptr);
    if (jsonText.isEmpty) return const [];
    final decoded = jsonDecode(jsonText);
    if (decoded is! List) return const [];
    return decoded.whereType<Map<String, dynamic>>().toList();
  }

  /// Reads live stream connection counts without resetting rolling telemetry.
  NativeStreamStatus? peekStatus(String token) {
    if (_disposed || !_refreshHandlers.containsKey(token)) return null;
    final ptr = _withUtf8(token, (tokenPtr) => _peekStatusFn(_engine, tokenPtr));
    if (ptr == nullptr) return null;
    final jsonText = _readAndFreeRustString(ptr);
    if (jsonText.isEmpty) return null;
    final decoded = jsonDecode(jsonText);
    if (decoded is! Map) return null;
    return NativeStreamStatus(
      activeConns: (decoded['active_conns'] as num?)?.toInt() ?? 0,
      targetConns: (decoded['target_conns'] as num?)?.toInt() ?? 0,
      maxConns: (decoded['effective_max_conns'] as num?)?.toInt() ?? 0,
      cacheBytes: (decoded['cache_bytes'] as num?)?.toInt() ?? 0,
    );
  }

  /// Shuts down the Rust runtime and local HTTP server cleanly.
  void stop() {
    if (_disposed) return;
    _disposed = true;
    _statsTimer?.cancel();
    _statsTimer = null;
    _refreshHandlers.clear();
    _stopFn(_engine);
    _refreshCallable.close();
  }

  void _ensureStatsTimer() {
    if (_statsTimer != null || statsLogInterval <= Duration.zero) return;
    _statsTimer = Timer.periodic(statsLogInterval, (_) => _logStats());
  }

  void _logStats() {
    if (_disposed || _refreshHandlers.isEmpty) return;
    final snaps = pollStats();
    for (final s in snaps) {
      final elapsedMs = (s['elapsed_ms'] as num?)?.toInt() ?? 0;
      final upBytes = (s['upstream_bytes'] as num?)?.toInt() ?? 0;
      final downBytes = (s['delivered_bytes'] as num?)?.toInt() ?? 0;
      final activeConns = (s['active_conns'] as num?)?.toInt() ?? 0;
      final activeReaders = (s['active_readers'] as num?)?.toInt() ?? 0;
      final requests = (s['requests'] as num?)?.toInt() ?? 0;
      final retries = (s['retries'] as num?)?.toInt() ?? 0;
      final rateLimits = (s['rate_limits'] as num?)?.toInt() ?? 0;
      final lastError = s['last_error'] as String?;
      final hasActivity =
          upBytes > 0 ||
          downBytes > 0 ||
          activeConns > 0 ||
          activeReaders > 0 ||
          requests > 0 ||
          retries > 0 ||
          rateLimits > 0 ||
          (lastError != null && lastError.isNotEmpty);
      if (elapsedMs <= 0 || !hasActivity) continue;
      final sec = elapsedMs / 1000.0;
      final upMBs = (upBytes / (1024 * 1024)) / sec;
      final downMBs = (downBytes / (1024 * 1024)) / sec;
      final cacheMiB = (((s['cache_bytes'] as num?)?.toInt() ?? 0) / (1024 * 1024)).toStringAsFixed(1);
      final upPct = ((s['up_wait_pct'] as num?)?.toDouble() ?? 0).toStringAsFixed(0);
      final downPct = ((s['down_wait_pct'] as num?)?.toDouble() ?? 0).toStringAsFixed(0);
      final brBps = (s['demand_bitrate_bps'] as num?)?.toInt() ?? 0;
      final brStr = brBps > 0 ? '${(brBps / 1000000.0).toStringAsFixed(1)}Mbps' : '-';
      final errSuffix = (lastError != null && lastError.isNotEmpty) ? ' err=$lastError' : '';
      final msg =
          'Native proxy stats: up=${upMBs.toStringAsFixed(2)}MB/s down=${downMBs.toStringAsFixed(2)}MB/s '
          'conn=$activeConns/${s['effective_max_conns']}(target=${s['target_conns']},peak=${s['peak_conns']}) '
          'readers=$activeReaders req=$requests started=${s['playback_started'] == true} br=$brStr '
          'ttfb=${s['ttfb_avg_ms']}ms(max=${s['ttfb_max_ms']}ms) redir=${s['redirects']} '
          'steals=${s['work_steals']} retries=$retries '
          'upWait=$upPct% downWait=$downPct% pauses=${s['pauses']} '
          'host=${s['final_host'] ?? '-'} cache=${cacheMiB}MiB$errSuffix';
      if (lastError != null && lastError.isNotEmpty) {
        appLogger.w(msg);
      } else {
        appLogger.i(msg);
      }
    }
  }

  void _onRefreshSignal(Pointer<Uint8> tokenPtr, int reqId) {
    final token = _readAndFreeRustString(tokenPtr);
    if (_disposed || token.isEmpty) return;
    final resolver = _refreshHandlers[token];
    if (resolver == null) {
      _sendLinkUpdate(token, reqId, {'error': 'Stream handler not found'});
      return;
    }
    unawaited(_handleRefresh(token, reqId, resolver));
  }

  Future<void> _handleRefresh(String token, int reqId, DirectLinkResolver resolver) async {
    try {
      final refreshed = await resolver(forceRefresh: true);
      if (_disposed) return;
      _sendLinkUpdate(token, reqId, {'url': refreshed.link.url.toString(), 'headers': refreshed.link.headers});
    } catch (e) {
      if (_disposed) return;
      _sendLinkUpdate(token, reqId, {'error': e.toString()});
    }
  }

  void _sendLinkUpdate(String token, int reqId, Map<String, Object?> payload) {
    if (_disposed) return;
    final jsonStr = jsonEncode(payload);
    _withUtf8(token, (tokenPtr) => _withUtf8(jsonStr, (jsonPtr) => _updateLinkFn(_engine, tokenPtr, reqId, jsonPtr)));
  }

  T _withUtf8<T>(String value, T Function(Pointer<Uint8> ptr) fn) {
    final bytes = utf8.encode(value);
    final allocLen = bytes.length + 1;
    final ptr = _bytesAllocFn(allocLen);
    if (ptr == nullptr) throw StateError('Rust allocator returned null');
    try {
      final view = ptr.asTypedList(allocLen);
      view.setRange(0, bytes.length, bytes);
      view[bytes.length] = 0;
      return fn(ptr);
    } finally {
      _bytesFreeFn(ptr, allocLen);
    }
  }

  String _readAndFreeRustString(Pointer<Uint8> ptr) {
    if (ptr == nullptr) return '';
    try {
      var len = 0;
      while (ptr[len] != 0) {
        len++;
      }
      if (len == 0) return '';
      return utf8.decode(ptr.asTypedList(len), allowMalformed: true);
    } finally {
      _stringFreeFn(ptr);
    }
  }
}
