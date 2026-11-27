import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../utils/app_logger.dart';
import 'http_range_reader.dart';
import 'storage_driver.dart';

/// Multi-connection sliding-window chunk prefetch cache for sequential playback.
///
/// Designed for origins (such as Quark cloud drive) that throttle individual TCP
/// connections while allowing full throughput across multiple Range requests:
/// - Small probe requests bypass prefetching and run over a single connection.
/// - Sequential reads stream the active chunk immediately as bytes arrive
///   (zero wait for full-chunk buffering) while ramping up background chunk
///   prefetches across a bounded sliding window.
/// - Completed chunks remain in a bounded LRU pool so audio/video interleave,
///   reconnections, and short backward seeks hit memory directly.
/// - Slow active chunks trigger an offset-aligned hedge request after
///   [hedgeDelay] to eliminate tail stalls without duplicating bytes.
class PlaybackPrefetchCache {
  PlaybackPrefetchCache(
    this._client, {
    this.chunkSize = defaultChunkSize,
    int? maxCacheBytes,
    int? defaultMaxConnections,
    this.rampUpFirstBytes = defaultRampUpFirstBytes,
    this.rampUpFullBytes = defaultRampUpFullBytes,
    this.stallTimeout = const Duration(seconds: 20),
    this.hedgeDelay = const Duration(seconds: 3),
    this.refreshWindow = const Duration(seconds: 30),
    this.maxRefreshesInWindow = 3,
    this.rateLimitCooldown = const Duration(seconds: 60),
    this.statsLogInterval = defaultStatsLogInterval,
  }) : assert(chunkSize > 0),
       assert(maxRefreshesInWindow >= 1),
       maxCacheBytes = maxCacheBytes ?? defaultMaxCacheBytesForPlatform,
       defaultMaxConnections = defaultMaxConnections ?? defaultMaxConnectionsForPlatform;

  static const int defaultChunkSize = 1 * 1024 * 1024;
  static const int defaultRampUpFirstBytes = 128 * 1024;
  static const int defaultRampUpFullBytes = 512 * 1024;
  static const Duration defaultStatsLogInterval = Duration(seconds: 15);

  static int get defaultMaxCacheBytesForPlatform =>
      (Platform.isAndroid || Platform.isIOS) ? 16 * 1024 * 1024 : 32 * 1024 * 1024;

  static int get defaultMaxConnectionsForPlatform => (Platform.isAndroid || Platform.isIOS) ? 4 : 6;

  static const int _maxChunkAttempts = 3;
  static const Duration _retryBaseDelay = Duration(milliseconds: 300);

  static const Set<int> _staleLinkStatuses = {
    HttpStatus.unauthorized,
    HttpStatus.forbidden,
    HttpStatus.notFound,
    HttpStatus.gone,
    HttpStatus.preconditionFailed,
  };

  static const Set<String> _credentialHeaders = {
    HttpHeaders.authorizationHeader,
    HttpHeaders.proxyAuthorizationHeader,
    HttpHeaders.wwwAuthenticateHeader,
    HttpHeaders.cookieHeader,
    'cookie2',
  };

  static final RegExp _rangePattern = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$', caseSensitive: false);

  final HttpClient _client;
  final int chunkSize;
  final int maxCacheBytes;
  final int defaultMaxConnections;
  final int rampUpFirstBytes;
  final int rampUpFullBytes;
  final Duration stallTimeout;
  final Duration hedgeDelay;
  final Duration refreshWindow;
  final int maxRefreshesInWindow;
  final Duration rateLimitCooldown;
  final Duration statsLogInterval;

  final LinkedHashMap<_ChunkKey, _ChunkSlot> _lru = LinkedHashMap<_ChunkKey, _ChunkSlot>();
  final Map<String, _FileState> _files = {};
  int _reservedBytes = 0;

  /// Total materialized payload bytes currently held in the cache pool.
  @visibleForTesting
  int get cachedBytes {
    var total = 0;
    for (final slot in _lru.values) {
      total += slot.bytes?.length ?? 0;
    }
    return total;
  }

  /// Number of chunk slots currently tracked in the cache pool.
  @visibleForTesting
  int get cachedChunkCount => _lru.length;

  /// Streams `[start, end]` (inclusive) for [fileKey] of [totalSize] bytes.
  Stream<List<int>> read({
    required String fileKey,
    required StorageLinkResolver resolve,
    required int start,
    required int end,
    required int totalSize,
    int? maxConnections,
  }) {
    if (totalSize <= 0 || end < start || start < 0) {
      return const Stream<List<int>>.empty();
    }
    final clampedEnd = min(end, totalSize - 1);
    final configuredMax = max(1, maxConnections ?? defaultMaxConnections);
    final file = _fileFor(fileKey, resolve, configuredMax);

    final firstChunk = start ~/ chunkSize;
    final lastChunk = clampedEnd ~/ chunkSize;
    if (_isSpanFullyCached(fileKey, firstChunk, lastChunk)) {
      return _streamCachedSpan(
        fileKey: fileKey,
        resolve: resolve,
        start: start,
        end: clampedEnd,
        totalSize: totalSize,
        maxConnections: configuredMax,
        firstChunk: firstChunk,
        lastChunk: lastChunk,
      );
    }

    final span = clampedEnd - start + 1;
    final effectiveMax = file.effectiveMaxConnections(clock.now(), rateLimitCooldown);
    if (totalSize <= chunkSize || effectiveMax <= 1 || file.rangeUnsupported || span < chunkSize) {
      if ((effectiveMax <= 1 || file.rangeUnsupported) && span >= chunkSize && !file.loggedSingleDirectBypass) {
        file.loggedSingleDirectBypass = true;
        appLogger.w(
          'Prefetch bypassed to single connection: effectiveMax=$effectiveMax '
          'rangeUnsupported=${file.rangeUnsupported} span=$span',
        );
      }
      return _wrapCancelable((cancelSignal) => _readSingleDirect(file, start, clampedEnd, totalSize, cancelSignal));
    }

    final session = _PlaybackSession(
      file: file,
      firstChunk: firstChunk,
      lastChunk: lastChunk,
      windowChunks: _windowSizeFor(effectiveMax),
    );
    return _wrapCancelable(
      (cancelSignal) => _readWithPrefetch(file, session, start, clampedEnd, totalSize, cancelSignal),
      onDispose: () => _finishSession(file, session),
    );
  }

  /// Drops all cached and in-flight slots for [fileKey].
  void evictFile(String fileKey) {
    final keys = _lru.keys.where((k) => k.fileKey == fileKey).toList();
    for (final key in keys) {
      final slot = _removeFromLru(key);
      slot?.cancel();
    }
    _files.remove(fileKey);
  }

  /// Cancels all in-flight fetches and empties the cache pool.
  void clear() {
    final slots = _lru.values.toList();
    _lru.clear();
    _reservedBytes = 0;
    for (final slot in slots) {
      slot.cancel();
    }
    _files.clear();
  }

  _FileState _fileFor(String fileKey, StorageLinkResolver resolve, int configuredMax) {
    final existing = _files[fileKey];
    if (existing != null) {
      existing.updateConfig(resolve, configuredMax);
      return existing;
    }
    return _files[fileKey] = _FileState(
      fileKey: fileKey,
      configuredMaxConnections: configuredMax,
      refresher: _WindowedLinkRefresher(
        resolve: resolve,
        refreshWindow: refreshWindow,
        maxRefreshesInWindow: maxRefreshesInWindow,
      ),
    );
  }

  int _windowSizeFor(int effectiveMax) {
    final maxCacheChunks = max(1, maxCacheBytes ~/ chunkSize);
    if (maxCacheChunks >= effectiveMax + 4) {
      return max(1, min(maxCacheChunks - 2, max(effectiveMax * 2, effectiveMax + 2)));
    }
    return max(1, min(maxCacheChunks, max(effectiveMax, 2)));
  }

  bool _isSpanFullyCached(String fileKey, int firstChunk, int lastChunk) {
    for (var i = firstChunk; i <= lastChunk; i++) {
      final slot = _lru[_ChunkKey(fileKey, i)];
      if (slot == null || !slot.completed || slot.bytes == null) return false;
    }
    return true;
  }

  Stream<List<int>> _streamCachedSpan({
    required String fileKey,
    required StorageLinkResolver resolve,
    required int start,
    required int end,
    required int totalSize,
    required int maxConnections,
    required int firstChunk,
    required int lastChunk,
  }) async* {
    for (var i = firstChunk; i <= lastChunk; i++) {
      final key = _ChunkKey(fileKey, i);
      final slot = _lru[key];
      if (slot == null || !slot.completed || slot.bytes == null) {
        // Fallback if evicted concurrently between awaits.
        yield* read(
          fileKey: fileKey,
          resolve: resolve,
          start: max(start, i * chunkSize),
          end: end,
          totalSize: totalSize,
          maxConnections: maxConnections,
        );
        return;
      }
      _touchLru(key, slot);
      final localStart = i == firstChunk ? start - slot.from : 0;
      final localEnd = i == lastChunk ? end - slot.from : slot.length - 1;
      final file = _files[fileKey];
      if (file != null) {
        file.windowCacheHits++;
        file.windowDeliveredBytes += localEnd - localStart + 1;
        _maybeLogStats(file, clock.now());
      }
      yield Uint8List.sublistView(slot.bytes!, localStart, localEnd + 1);
    }
  }

  Stream<List<int>> _wrapCancelable(
    Stream<List<int>> Function(_CancelSignal cancelSignal) builder, {
    void Function()? onDispose,
  }) {
    final cancelSignal = _CancelSignal();
    late StreamSubscription<List<int>> subscription;
    final controller = StreamController<List<int>>(sync: true);
    controller.onListen = () {
      subscription = builder(cancelSignal).listen(
        controller.add,
        onError: controller.addError,
        onDone: () {
          cancelSignal.cancel();
          onDispose?.call();
          if (!controller.isClosed) controller.close();
        },
      );
    };
    controller.onPause = () => subscription.pause();
    controller.onResume = () => subscription.resume();
    controller.onCancel = () async {
      cancelSignal.cancel();
      onDispose?.call();
      await subscription.cancel();
    };
    return controller.stream;
  }

  Stream<List<int>> _readSingleDirect(
    _FileState file,
    int start,
    int end,
    int totalSize,
    _CancelSignal cancelSignal,
  ) async* {
    final op = _SingleOp(cancelSignal);
    try {
      final opened = await _openRangeWithRedirects(
        file: file,
        from: start,
        to: end,
        totalSize: totalSize,
        allowFullOk: true,
        cancelSignal: op,
      );
      if (opened.status == HttpStatus.ok) {
        _markRangeUnsupported(file);
        yield* _sliceAndTrack(opened.response, start, end, op);
        return;
      }
      yield* _readExactResponse(opened.response, end - start + 1, op);
    } on _CancelledException {
      return;
    } finally {
      op.cancel();
    }
  }

  Stream<List<int>> _readWithPrefetch(
    _FileState file,
    _PlaybackSession session,
    int start,
    int end,
    int totalSize,
    _CancelSignal cancelSignal,
  ) async* {
    file.sessions.add(session);
    try {
      for (var index = session.firstChunk; index <= session.lastChunk; index++) {
        cancelSignal.checkCancelled();
        session.currentChunk = index;

        final slot = _ensureSlotForConsumer(file, index, totalSize);
        if (slot.completed && slot.bytes != null) {
          _touchLru(slot.key, slot);
          final localStart = index == session.firstChunk ? start - slot.from : 0;
          final localEnd = index == session.lastChunk ? end - slot.from : slot.length - 1;
          final slice = Uint8List.sublistView(slot.bytes!, localStart, localEnd + 1);
          session.deliveredBytes += slice.length;
          file.windowCacheHits++;
          file.windowDeliveredBytes += slice.length;
          _maybeLogStats(file, clock.now());
          _schedulePrefetch(file, totalSize);
          yield slice;
          continue;
        }

        slot.activeConsumers++;
        session.activeSlot = slot;
        try {
          if (!slot.fetching && !slot.completed) {
            _startSlotFetch(slot, file, forceBypassBudget: true);
          }
          _schedulePrefetch(file, totalSize);

          final localStart = index == session.firstChunk ? start - slot.from : 0;
          final localEnd = index == session.lastChunk ? end - slot.from : slot.length - 1;
          var cursor = localStart;

          while (cursor <= localEnd) {
            cancelSignal.checkCancelled();

            if (slot.fullResponseFallback != null) {
              final fallback = slot.fullResponseFallback!;
              slot.fullResponseFallback = null;
              _markRangeUnsupported(file);
              _removeSlotIfExact(slot);
              slot.cancel();
              final resumeAt = slot.from + cursor;
              yield* _sliceAndTrack(fallback, resumeAt, end, cancelSignal);
              return;
            }

            if (slot.written > cursor) {
              final endOffset = min(localEnd + 1, slot.written);
              final piece = Uint8List.sublistView(slot.bytes!, cursor, endOffset);
              cursor = endOffset;
              session.deliveredBytes += piece.length;
              file.windowDeliveredBytes += piece.length;
              _maybeLogStats(file, clock.now());
              _schedulePrefetch(file, totalSize);
              yield piece;
              continue;
            }

            if (slot.error != null) {
              throw slot.error!;
            }
            if (slot.completed) {
              throw StorageException(
                StorageErrorKind.network,
                'Incomplete chunk ${slot.key.index}: ${slot.written}/${slot.length}',
              );
            }
            if (slot.cancelled) {
              throw const _CancelledException();
            }

            await _waitForSlotWithHedge(slot, file, cancelSignal);
          }
        } finally {
          if (identical(session.activeSlot, slot)) {
            slot.activeConsumers--;
            session.activeSlot = null;
          }
        }
      }
    } on _CancelledException {
      return;
    } finally {
      _finishSession(file, session);
    }
  }

  Future<void> _waitForSlotWithHedge(_ChunkSlot slot, _FileState file, _CancelSignal cancelSignal) async {
    Timer? hedgeTimer;
    final effectiveMax = file.effectiveMaxConnections(clock.now(), rateLimitCooldown);
    if (!slot.hedged && effectiveMax > 1 && slot.fetching) {
      final lastAt = slot.lastProgressAt;
      final elapsed = lastAt == null ? Duration.zero : clock.now().difference(lastAt);
      final remaining = hedgeDelay - elapsed;
      if (remaining <= Duration.zero) {
        _maybeStartHedge(slot, file);
      } else {
        hedgeTimer = Timer(remaining, () {
          if (!cancelSignal.cancelled && !slot.cancelled && !slot.completed && slot.fetching) {
            _maybeStartHedge(slot, file);
          }
        });
      }
    }
    try {
      await Future.any<void>([slot.waitForProgress(), cancelSignal.future]);
    } finally {
      hedgeTimer?.cancel();
    }
  }

  void _finishSession(_FileState file, _PlaybackSession session) {
    final activeSlot = session.activeSlot;
    if (activeSlot != null) {
      activeSlot.activeConsumers--;
      session.activeSlot = null;
    }
    if (!file.sessions.remove(session)) return;
    _cancelOrphanedFetches(file);
    if (file.sessions.isEmpty) {
      _maybeLogStats(file, clock.now(), sessionEnded: true);
    }
  }

  void _markRangeUnsupported(_FileState file) {
    file.rangeUnsupported = true;
    if (!file.loggedRangeUnsupported) {
      file.loggedRangeUnsupported = true;
      appLogger.w('Prefetch fallback: origin returned HTTP 200 (Range unsupported), switched to single connection');
    }
  }

  void _maybeLogStats(_FileState file, DateTime now, {bool sessionEnded = false}) {
    if (statsLogInterval <= Duration.zero) return;
    final windowStart = file.statsWindowStart;
    if (windowStart == null) {
      file.statsWindowStart = now;
      return;
    }
    final elapsedMs = now.difference(windowStart).inMilliseconds;
    if (sessionEnded) {
      if (elapsedMs < 3000 || (file.windowUpstreamBytes < chunkSize && file.windowDeliveredBytes < chunkSize)) {
        return;
      }
    } else if (elapsedMs < statsLogInterval.inMilliseconds ||
        (file.windowUpstreamBytes <= 0 && file.windowDeliveredBytes <= 0)) {
      return;
    }
    final elapsedSec = elapsedMs / 1000.0;
    final upMBs = (file.windowUpstreamBytes / (1024 * 1024)) / elapsedSec;
    final downMBs = (file.windowDeliveredBytes / (1024 * 1024)) / elapsedSec;
    final perConnMBs = file.windowCompletedChunkMs > 0
        ? (file.windowCompletedChunkBytes / (1024 * 1024)) / (file.windowCompletedChunkMs / 1000.0)
        : 0.0;
    final active = _activeFetchCount(file);
    final effectiveMax = file.effectiveMaxConnections(now, rateLimitCooldown);
    final cacheMiB = (cachedBytes / (1024 * 1024)).toStringAsFixed(1);
    final maxMiB = (maxCacheBytes / (1024 * 1024)).toStringAsFixed(1);
    final avgTtfb = file.windowTtfbCount > 0 ? (file.windowTtfbMsSum / file.windowTtfbCount).round() : 0;
    appLogger.i(
      'Prefetch stats${sessionEnded ? '(end)' : ''}: up=${upMBs.toStringAsFixed(2)}MB/s '
      'down=${downMBs.toStringAsFixed(2)}MB/s perConn=${perConnMBs.toStringAsFixed(2)}MB/s '
      'conn=$active/$effectiveMax(peak=${file.windowPeakActiveConns},cfg=${file.configuredMaxConnections}) '
      'chunks=${file.windowChunksCompleted} hits=${file.windowCacheHits} '
      'hedges=${file.windowHedges} retries=${file.windowRetries} '
      'ttfb=${avgTtfb}ms(max=${file.windowTtfbMaxMs}ms) redir=${file.windowRedirects} '
      'host=${file.lastFinalHost ?? '-'} '
      'cache=$cacheMiB/${maxMiB}MiB chunk=${chunkSize ~/ 1024}KiB',
    );
    file.resetStatsWindow(now);
  }

  void _cancelOrphanedFetches(_FileState file) {
    final activeKeys = _lru.keys.where((k) => k.fileKey == file.fileKey).toList();
    for (final key in activeKeys) {
      final slot = _lru[key];
      if (slot == null || slot.completed || slot.activeConsumers > 0) continue;
      if (!file.isChunkInAnySessionWindow(key.index)) {
        _removeFromLru(key);
        slot.cancel();
      }
    }
  }

  _ChunkSlot _ensureSlotForConsumer(_FileState file, int index, int totalSize) {
    final key = _ChunkKey(file.fileKey, index);
    final existing = _lru[key];
    if (existing != null && !existing.cancelled && existing.error == null) {
      _touchLru(key, existing);
      return existing;
    }
    if (existing != null) {
      _removeFromLru(key);
    }
    final from = index * chunkSize;
    final to = min(totalSize - 1, from + chunkSize - 1);
    final slot = _ChunkSlot(key: key, from: from, to: to, totalSize: totalSize);
    _evictForIncoming(file, slot.length, allowOverBudget: true);
    _putInLru(key, slot);
    return slot;
  }

  void _schedulePrefetch(_FileState file, int totalSize) {
    if (file.rangeUnsupported || file.sessions.isEmpty) return;

    final now = clock.now();
    final effectiveMax = file.effectiveMaxConnections(now, rateLimitCooldown);
    if (effectiveMax <= 1) return;

    var allowed = 1;
    for (final session in file.sessions) {
      final sessionAllowed = _allowedConnectionsForSession(session, effectiveMax);
      if (sessionAllowed > allowed) allowed = sessionAllowed;
    }
    if (allowed <= 1) return;

    var activeCount = _activeFetchCount(file);
    if (activeCount >= allowed) return;

    final candidates = SplayTreeSet<int>();
    for (final session in file.sessions) {
      final windowEnd = session.windowEndChunk;
      for (var idx = session.currentChunk; idx <= windowEnd; idx++) {
        candidates.add(idx);
      }
    }

    for (final idx in candidates) {
      if (activeCount >= allowed) break;
      final key = _ChunkKey(file.fileKey, idx);
      final existing = _lru[key];
      if (existing != null && !existing.cancelled && existing.error == null) {
        continue;
      }
      if (existing != null) _removeFromLru(key);

      final from = idx * chunkSize;
      if (from >= totalSize) continue;
      final to = min(totalSize - 1, from + chunkSize - 1);
      final length = to - from + 1;
      if (!_evictForIncoming(file, length, allowOverBudget: false)) {
        break;
      }
      final slot = _ChunkSlot(key: key, from: from, to: to, totalSize: totalSize);
      _putInLru(key, slot);
      _startSlotFetch(slot, file, forceBypassBudget: false);
      activeCount++;
    }
  }

  int _allowedConnectionsForSession(_PlaybackSession session, int effectiveMax) {
    if (session.deliveredBytes >= rampUpFullBytes || session.currentChunk > session.firstChunk) {
      return effectiveMax;
    }
    if (session.deliveredBytes >= rampUpFirstBytes) {
      return min(2, effectiveMax);
    }
    return 1;
  }

  int _activeFetchCount(_FileState file) {
    var count = 0;
    for (final entry in _lru.entries) {
      if (entry.key.fileKey == file.fileKey && entry.value.fetching) {
        count++;
      }
    }
    return count;
  }

  bool _evictForIncoming(_FileState file, int neededBytes, {required bool allowOverBudget}) {
    if (_reservedBytes + neededBytes <= maxCacheBytes) return true;
    final keys = _lru.keys.toList();
    for (final key in keys) {
      if (_reservedBytes + neededBytes <= maxCacheBytes) return true;
      final slot = _lru[key];
      if (slot == null || slot.activeConsumers > 0) continue;
      final owner = _files[key.fileKey];
      if (owner != null && owner.isChunkInAnySessionWindow(key.index)) continue;
      _removeFromLru(key);
      slot.cancel();
    }
    return allowOverBudget || _reservedBytes + neededBytes <= maxCacheBytes;
  }

  void _putInLru(_ChunkKey key, _ChunkSlot slot) {
    final prev = _lru.remove(key);
    if (prev != null) _reservedBytes -= prev.length;
    _lru[key] = slot;
    _reservedBytes += slot.length;
  }

  void _touchLru(_ChunkKey key, _ChunkSlot slot) {
    if (!identical(_lru[key], slot)) return;
    _lru.remove(key);
    _lru[key] = slot;
  }

  _ChunkSlot? _removeFromLru(_ChunkKey key) {
    final removed = _lru.remove(key);
    if (removed != null) _reservedBytes -= removed.length;
    return removed;
  }

  void _removeSlotIfExact(_ChunkSlot slot) {
    if (identical(_lru[slot.key], slot)) {
      _removeFromLru(slot.key);
    }
  }

  void _startSlotFetch(_ChunkSlot slot, _FileState file, {required bool forceBypassBudget}) {
    if (slot.fetching || slot.completed || slot.cancelled) return;
    final now = clock.now();
    slot.fetching = true;
    slot.primaryActive = true;
    slot.lastProgressAt = now;
    slot.fetchStartedAt ??= now;
    file.recordActiveConns(_activeFetchCount(file));
    unawaited(_runPrimaryFetch(slot, file, allowFullOk: forceBypassBudget));
  }

  Future<void> _runPrimaryFetch(_ChunkSlot slot, _FileState file, {required bool allowFullOk}) async {
    try {
      for (var attempt = 1; ; attempt++) {
        if (slot.cancelled || slot.completed) return;
        final baseWritten = slot.written;
        final fetch = _InFlightFetch(slot);
        slot.inFlight.add(fetch);
        try {
          await _executeFetchAttempt(
            slot: slot,
            file: file,
            fetch: fetch,
            baseWritten: baseWritten,
            allowFullOk: allowFullOk && baseWritten == 0,
            isHedge: false,
          );
          if (slot.completed || slot.cancelled || slot.fullResponseFallback != null) return;
          if (slot.written >= slot.length) {
            _markSlotCompleted(slot, file);
            return;
          }
          throw StorageException(
            StorageErrorKind.network,
            'Origin sent ${slot.written} of ${slot.length} bytes at ${slot.from}',
          );
        } on _SupersededByPeer {
          return;
        } on _CancelledException {
          return;
        } on StorageException catch (e) {
          if (slot.cancelled || slot.completed) return;
          final hasPeer = slot.inFlight.any((f) => !identical(f, fetch));
          if (hasPeer) return;
          if (!_retryable(e.kind) || attempt >= _maxChunkAttempts) {
            _failSlot(slot, e);
            return;
          }
        } catch (e) {
          if (slot.cancelled || slot.completed) return;
          final hasPeer = slot.inFlight.any((f) => !identical(f, fetch));
          if (hasPeer) return;
          if (attempt >= _maxChunkAttempts) {
            _failSlot(slot, StorageException(StorageErrorKind.network, '$e', cause: e));
            return;
          }
        } finally {
          slot.inFlight.remove(fetch);
          fetch.abort();
        }
        file.windowRetries++;
        await slot.untilCancelled(Future<void>.delayed(_retryBaseDelay * attempt));
      }
    } on _CancelledException {
      return;
    } finally {
      slot.primaryActive = false;
      if (slot.inFlight.isEmpty) {
        slot.fetching = false;
      }
    }
  }

  void _maybeStartHedge(_ChunkSlot slot, _FileState file) {
    if (slot.hedged || slot.cancelled || slot.completed || !slot.fetching) return;
    final snapshotWritten = slot.written;
    if (snapshotWritten >= slot.length) return;
    slot.hedged = true;
    file.windowHedges++;
    file.recordActiveConns(_activeFetchCount(file));
    unawaited(_runHedgeFetch(slot, file, snapshotWritten));
  }

  Future<void> _runHedgeFetch(_ChunkSlot slot, _FileState file, int snapshotWritten) async {
    final fetch = _InFlightFetch(slot);
    slot.inFlight.add(fetch);
    try {
      await _executeFetchAttempt(
        slot: slot,
        file: file,
        fetch: fetch,
        baseWritten: snapshotWritten,
        allowFullOk: false,
        isHedge: true,
      );
      if (!slot.cancelled && !slot.completed && slot.written >= slot.length) {
        _markSlotCompleted(slot, file);
      }
    } on _SupersededByPeer {
      return;
    } on _CancelledException {
      return;
    } on StorageException catch (e) {
      final hasPeer = slot.inFlight.any((f) => !identical(f, fetch));
      if (!slot.cancelled && !slot.completed && !slot.primaryActive && !hasPeer) {
        _failSlot(slot, e);
      }
    } catch (e) {
      final hasPeer = slot.inFlight.any((f) => !identical(f, fetch));
      if (!slot.cancelled && !slot.completed && !slot.primaryActive && !hasPeer) {
        _failSlot(slot, StorageException(StorageErrorKind.network, '$e', cause: e));
      }
    } finally {
      slot.inFlight.remove(fetch);
      fetch.abort();
      if (slot.inFlight.isEmpty && !slot.primaryActive) {
        slot.fetching = false;
      }
    }
  }

  Future<void> _executeFetchAttempt({
    required _ChunkSlot slot,
    required _FileState file,
    required _InFlightFetch fetch,
    required int baseWritten,
    required bool allowFullOk,
    required bool isHedge,
  }) async {
    final reqStart = slot.from + baseWritten;
    final opened = await _openRangeWithRedirects(
      file: file,
      from: reqStart,
      to: slot.to,
      totalSize: slot.totalSize,
      allowFullOk: allowFullOk,
      cancelSignal: fetch,
    );

    if (opened.status == HttpStatus.ok) {
      if (isHedge || slot.written > 0) {
        await opened.response.listen(null).cancel().catchError((Object _) {});
        throw const StorageException(StorageErrorKind.network, 'Origin ignored Range header');
      }
      slot.fullResponseFallback = opened.response;
      slot.notifyWaiters();
      return;
    }

    slot.bytes ??= Uint8List(slot.length);
    var localOffset = baseWritten;

    final body = StreamIterator(opened.response.timeout(stallTimeout));
    fetch.bodyIterator = body;
    try {
      while (await fetch.untilCancelled(body.moveNext())) {
        fetch.checkCancelled();
        final block = body.current;
        if (block.isEmpty) continue;

        final blockEnd = localOffset + block.length;
        if (blockEnd > slot.length) {
          throw const StorageException(StorageErrorKind.network, 'Origin sent more bytes than requested');
        }

        final currentWritten = slot.written;
        if (blockEnd <= currentWritten) {
          // A peer fetch already filled past this block.
          throw const _SupersededByPeer();
        }

        final skip = currentWritten > localOffset ? currentWritten - localOffset : 0;
        final writeLen = block.length - skip;
        slot.bytes!.setRange(currentWritten, currentWritten + writeLen, block, skip);
        slot.written = currentWritten + writeLen;
        slot.lastProgressAt = clock.now();
        file.windowUpstreamBytes += writeLen;
        localOffset = blockEnd;

        // Abort any competing peer once we advance the shared write cursor.
        if (slot.inFlight.length > 1) {
          for (final peer in slot.inFlight.toList()) {
            if (!identical(peer, fetch)) {
              peer.supersede();
            }
          }
        }
        slot.notifyWaiters();
      }
      fetch.checkCancelled();
      if (slot.written >= slot.length) {
        _markSlotCompleted(slot, file);
      }
    } on _SupersededByPeer {
      rethrow;
    } on _CancelledException {
      rethrow;
    } on StorageException {
      rethrow;
    } on Exception catch (e) {
      fetch.checkCancelled();
      throw StorageException(StorageErrorKind.network, 'Stream interrupted at $reqStart: $e', cause: e);
    } finally {
      fetch.bodyIterator = null;
      await body.cancel().catchError((Object _) {});
    }
  }

  void _markSlotCompleted(_ChunkSlot slot, _FileState file) {
    if (slot.completed || slot.cancelled) return;
    final now = clock.now();
    slot.completed = true;
    slot.fetching = false;
    file.windowChunksCompleted++;
    file.windowCompletedChunkBytes += slot.length;
    if (slot.fetchStartedAt case final started?) {
      file.windowCompletedChunkMs += max(1, now.difference(started).inMilliseconds);
    }
    slot.notifyWaiters();
    _maybeLogStats(file, now);
    _schedulePrefetch(file, slot.totalSize);
  }

  void _failSlot(_ChunkSlot slot, StorageException error) {
    if (slot.completed || slot.cancelled) return;
    _removeSlotIfExact(slot);
    slot.error = error;
    slot.fetching = false;
    slot.notifyWaiters();
  }

  Future<({HttpClientResponse response, int status})> _openRangeWithRedirects({
    required _FileState file,
    required int from,
    required int to,
    required int totalSize,
    required bool allowFullOk,
    required _CancelableOp cancelSignal,
  }) async {
    var link = await cancelSignal.untilCancelled(file.refresher.current(clock.now()));
    while (true) {
      cancelSignal.checkCancelled();
      final opened = await _followRedirects(
        link: link,
        from: from,
        to: to,
        cancelSignal: cancelSignal,
      );
      final response = opened.response;
      final status = response.statusCode;
      file.recordRequestLatency(ttfbMs: opened.ttfbMs, redirects: opened.redirects, host: opened.finalHost);
      try {
        cancelSignal.checkCancelled();
        if (status == HttpStatus.partialContent) {
          _validateContentRange(response, from: from, to: to, expectedSize: totalSize);
          return (response: response, status: status);
        }
        if (allowFullOk && status == HttpStatus.ok) {
          if (response.contentLength >= 0 && response.contentLength != totalSize) {
            throw const StorageException(StorageErrorKind.network, 'Origin reported a different file size');
          }
          return (response: response, status: status);
        }
        if (status == HttpStatus.tooManyRequests) {
          final now = clock.now();
          final prevMax = file.effectiveMaxConnections(now, rateLimitCooldown);
          file.recordRateLimit(now);
          final nextMax = file.effectiveMaxConnections(now, rateLimitCooldown);
          appLogger.w(
            'Prefetch rate-limited (HTTP 429): maxConn $prevMax->$nextMax '
            'cooldown=${rateLimitCooldown.inSeconds}s host=${link.url.host}',
          );
          throw const StorageException(StorageErrorKind.rateLimited, 'Origin answered HTTP 429');
        }
        if (!_staleLinkStatuses.contains(status)) {
          throw StorageException(_kindFor(status), 'Origin answered HTTP $status');
        }
      } catch (_) {
        await response.listen(null).cancel().catchError((Object _) {});
        rethrow;
      }
      await response.listen(null).cancel().catchError((Object _) {});
      link = await cancelSignal.untilCancelled(file.refresher.refresh(link, clock.now()));
    }
  }

  Future<({HttpClientResponse response, int redirects, String finalHost, int ttfbMs})> _followRedirects({
    required StorageLink link,
    required int from,
    required int to,
    required _CancelableOp cancelSignal,
  }) async {
    final sw = Stopwatch()..start();
    var uri = link.url;
    var headers = link.headers;
    for (var redirects = 0; ; redirects++) {
      final response = await _sendRangeGet(uri: uri, headers: headers, from: from, to: to, cancelSignal: cancelSignal);
      final location = response.isRedirect ? response.headers.value(HttpHeaders.locationHeader) : null;
      if (location == null) {
        sw.stop();
        return (response: response, redirects: redirects, finalHost: uri.host, ttfbMs: sw.elapsedMilliseconds);
      }
      await response.listen(null).cancel().catchError((Object _) {});
      final target = uri.resolve(location);
      if (redirects >= 5 || !(target.isScheme('http') || target.isScheme('https'))) {
        throw const StorageException(StorageErrorKind.network, 'Invalid origin redirect');
      }
      final canForwardCredentials =
          target.isScheme(uri.scheme) &&
          target.port == uri.port &&
          (target.host == uri.host || target.host.endsWith('.${uri.host}'));
      headers = Map.of(headers)
        ..removeWhere((name, _) {
          final lower = name.toLowerCase();
          return lower == HttpHeaders.hostHeader || (!canForwardCredentials && _credentialHeaders.contains(lower));
        });
      uri = target;
    }
  }

  Future<HttpClientResponse> _sendRangeGet({
    required Uri uri,
    required Map<String, String> headers,
    required int from,
    required int to,
    required _CancelableOp cancelSignal,
  }) async {
    try {
      cancelSignal.checkCancelled();
      final opening = _client.getUrl(uri).then((request) {
        // Silence any late error from request.abort() if cancelled mid-flight.
        request.done.then<void>((_) {}, onError: (Object _) {});
        if (cancelSignal.cancelled) {
          request.abort(const _CancelledException());
          throw const _CancelledException();
        }
        return request;
      });
      final request = await cancelSignal.untilCancelled(opening);
      cancelSignal.request = request;
      headers.forEach(request.headers.set);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=$from-$to');
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      request.followRedirects = false;

      final responseFuture = request.close();
      // Silence late rejection if cancelSignal interrupts the await before headers arrive.
      unawaited(responseFuture.then<void>((_) {}, onError: (Object _) {}));
      try {
        return await cancelSignal.untilCancelled(
          responseFuture.timeout(
            stallTimeout,
            onTimeout: () {
              final error = TimeoutException('Origin did not send response headers', stallTimeout);
              request.abort(error);
              throw StorageException(StorageErrorKind.network, error.message!, cause: error);
            },
          ),
        );
      } finally {
        if (identical(cancelSignal.request, request)) {
          cancelSignal.request = null;
        }
      }
    } on _CancelledException {
      rethrow;
    } on StorageException {
      rethrow;
    } on SocketException catch (e) {
      throw StorageException(StorageErrorKind.network, 'Cannot reach ${uri.host}', cause: e);
    } on HandshakeException catch (e) {
      throw StorageException(StorageErrorKind.network, 'TLS handshake with ${uri.host} failed', cause: e);
    } on HttpException catch (e) {
      throw StorageException(StorageErrorKind.network, e.message, cause: e);
    }
  }

  Stream<List<int>> _readExactResponse(HttpClientResponse response, int expectedBytes, _CancelableOp op) async* {
    final iterator = StreamIterator(response.timeout(stallTimeout));
    var received = 0;
    try {
      while (await op.untilCancelled(iterator.moveNext())) {
        op.checkCancelled();
        final chunk = iterator.current;
        if (chunk.isEmpty) continue;
        received += chunk.length;
        if (received > expectedBytes) {
          throw const StorageException(StorageErrorKind.network, 'Origin sent more bytes than requested');
        }
        yield chunk;
      }
      op.checkCancelled();
      if (received != expectedBytes) {
        throw StorageException(StorageErrorKind.network, 'Origin sent $received of $expectedBytes bytes');
      }
    } on _CancelledException {
      return;
    } on Exception catch (e) {
      op.checkCancelled();
      if (e is StorageException) rethrow;
      throw StorageException(StorageErrorKind.network, 'Stream interrupted: $e', cause: e);
    } finally {
      await iterator.cancel().catchError((Object _) {});
    }
  }

  Stream<List<int>> _sliceAndTrack(
    HttpClientResponse response,
    int start,
    int end,
    _CancelableOp cancelSignal,
  ) async* {
    final iterator = StreamIterator(response.timeout(stallTimeout));
    var offset = 0;
    try {
      while (await cancelSignal.untilCancelled(iterator.moveNext())) {
        cancelSignal.checkCancelled();
        final chunk = iterator.current;
        if (chunk.isEmpty) continue;
        final chunkStart = offset;
        offset += chunk.length;
        if (offset <= start) continue;
        final from = start > chunkStart ? start - chunkStart : 0;
        final to = end + 1 < offset ? end + 1 - chunkStart : chunk.length;
        yield from == 0 && to == chunk.length ? chunk : chunk.sublist(from, to);
        if (offset > end) return;
      }
    } on _CancelledException {
      return;
    } on Exception catch (e) {
      cancelSignal.checkCancelled();
      if (e is StorageException) rethrow;
      throw StorageException(StorageErrorKind.network, 'Stream interrupted: $e', cause: e);
    } finally {
      await iterator.cancel().catchError((Object _) {});
    }
  }

  static void _validateContentRange(
    HttpClientResponse response, {
    required int from,
    required int to,
    required int expectedSize,
  }) {
    final value = response.headers.value(HttpHeaders.contentRangeHeader);
    final match = value == null ? null : _rangePattern.firstMatch(value);
    final actualFrom = int.tryParse(match?.group(1) ?? '');
    final actualTo = int.tryParse(match?.group(2) ?? '');
    final size = int.tryParse(match?.group(3) ?? '');
    if (actualFrom != from || actualTo != to || size == null || size != expectedSize || size <= to) {
      throw StorageException(
        StorageErrorKind.network,
        'Invalid Content-Range for $from-$to/$expectedSize: $value',
      );
    }
  }

  static bool _retryable(StorageErrorKind kind) =>
      kind == StorageErrorKind.network || kind == StorageErrorKind.rateLimited || kind == StorageErrorKind.other;

  static StorageErrorKind _kindFor(int status) => switch (status) {
    HttpStatus.unauthorized || HttpStatus.forbidden => StorageErrorKind.unauthorized,
    HttpStatus.notFound || HttpStatus.gone => StorageErrorKind.notFound,
    HttpStatus.tooManyRequests => StorageErrorKind.rateLimited,
    _ => StorageErrorKind.other,
  };
}

class _ChunkKey {
  const _ChunkKey(this.fileKey, this.index);

  final String fileKey;
  final int index;

  @override
  bool operator ==(Object other) => other is _ChunkKey && other.fileKey == fileKey && other.index == index;

  @override
  int get hashCode => Object.hash(fileKey, index);
}

class _ChunkSlot {
  _ChunkSlot({required this.key, required this.from, required this.to, required this.totalSize});

  final _ChunkKey key;
  final int from;
  final int to;
  final int totalSize;

  Uint8List? bytes;
  int written = 0;
  bool completed = false;
  Object? error;
  bool cancelled = false;
  bool fetching = false;
  bool primaryActive = false;
  bool hedged = false;
  int activeConsumers = 0;
  DateTime? lastProgressAt;
  DateTime? fetchStartedAt;
  HttpClientResponse? fullResponseFallback;

  final Set<_InFlightFetch> inFlight = {};
  final Completer<void> _cancelled = Completer<void>();
  Completer<void> _progressSignal = Completer<void>();

  int get length => to - from + 1;

  Future<void> waitForProgress() => _progressSignal.future;

  Future<T> untilCancelled<T>(Future<T> future) {
    if (cancelled) return Future<T>.error(const _CancelledException());
    return Future.any([future, _cancelled.future.then<T>((_) => throw const _CancelledException())]);
  }

  void notifyWaiters() {
    if (!_progressSignal.isCompleted) {
      _progressSignal.complete();
    }
    _progressSignal = Completer<void>();
  }

  void cancel() {
    if (cancelled) return;
    cancelled = true;
    fetching = false;
    if (!_cancelled.isCompleted) _cancelled.complete();
    for (final fetch in inFlight.toList()) {
      fetch.abort();
    }
    inFlight.clear();
    final fallback = fullResponseFallback;
    fullResponseFallback = null;
    if (fallback != null) {
      unawaited(fallback.listen(null).cancel().catchError((Object _) {}));
    }
    notifyWaiters();
  }
}

class _FileState {
  _FileState({required this.fileKey, required this.configuredMaxConnections, required this.refresher})
    : _dynamicMaxConnections = configuredMaxConnections;

  final String fileKey;
  int configuredMaxConnections;
  final _WindowedLinkRefresher refresher;
  final List<_PlaybackSession> sessions = [];
  bool rangeUnsupported = false;

  int _dynamicMaxConnections;
  DateTime? _lastRateLimitAt;
  DateTime? statsWindowStart;
  int windowUpstreamBytes = 0;
  int windowDeliveredBytes = 0;
  int windowChunksCompleted = 0;
  int windowCompletedChunkBytes = 0;
  int windowCompletedChunkMs = 0;
  int windowCacheHits = 0;
  int windowHedges = 0;
  int windowRetries = 0;
  int windowPeakActiveConns = 0;
  int windowTtfbMsSum = 0;
  int windowTtfbCount = 0;
  int windowTtfbMaxMs = 0;
  int windowRedirects = 0;
  String? lastFinalHost;
  bool loggedRangeUnsupported = false;
  bool loggedSingleDirectBypass = false;

  void recordActiveConns(int active) {
    if (active > windowPeakActiveConns) {
      windowPeakActiveConns = active;
    }
  }

  void recordRequestLatency({required int ttfbMs, required int redirects, required String host}) {
    windowTtfbMsSum += ttfbMs;
    windowTtfbCount++;
    if (ttfbMs > windowTtfbMaxMs) windowTtfbMaxMs = ttfbMs;
    windowRedirects += redirects;
    lastFinalHost = host;
  }

  void resetStatsWindow(DateTime now) {
    statsWindowStart = now;
    windowUpstreamBytes = 0;
    windowDeliveredBytes = 0;
    windowChunksCompleted = 0;
    windowCompletedChunkBytes = 0;
    windowCompletedChunkMs = 0;
    windowCacheHits = 0;
    windowHedges = 0;
    windowRetries = 0;
    windowPeakActiveConns = 0;
    windowTtfbMsSum = 0;
    windowTtfbCount = 0;
    windowTtfbMaxMs = 0;
    windowRedirects = 0;
  }

  void updateConfig(StorageLinkResolver resolve, int maxConnections) {
    refresher.resolve = resolve;
    configuredMaxConnections = maxConnections;
    if (_dynamicMaxConnections > maxConnections) {
      _dynamicMaxConnections = maxConnections;
    }
  }

  void recordRateLimit(DateTime now) {
    _lastRateLimitAt = now;
    _dynamicMaxConnections = max(1, _dynamicMaxConnections ~/ 2);
  }

  int effectiveMaxConnections(DateTime now, Duration cooldown) {
    final last = _lastRateLimitAt;
    if (last != null && _dynamicMaxConnections < configuredMaxConnections && now.difference(last) >= cooldown) {
      _dynamicMaxConnections = min(configuredMaxConnections, _dynamicMaxConnections * 2);
      _lastRateLimitAt = _dynamicMaxConnections < configuredMaxConnections ? now : null;
    }
    return min(configuredMaxConnections, _dynamicMaxConnections);
  }

  bool isChunkInAnySessionWindow(int chunkIndex) {
    for (final s in sessions) {
      if (chunkIndex >= s.currentChunk && chunkIndex <= s.windowEndChunk) return true;
    }
    return false;
  }
}

class _PlaybackSession {
  _PlaybackSession({
    required this.file,
    required this.firstChunk,
    required this.lastChunk,
    required this.windowChunks,
  }) : currentChunk = firstChunk;

  final _FileState file;
  final int firstChunk;
  final int lastChunk;
  final int windowChunks;
  int currentChunk;
  int deliveredBytes = 0;
  _ChunkSlot? activeSlot;

  int get windowEndChunk => min(lastChunk, currentChunk + windowChunks - 1);
}

class _WindowedLinkRefresher {
  _WindowedLinkRefresher({
    required this.resolve,
    required this.refreshWindow,
    required this.maxRefreshesInWindow,
  });

  StorageLinkResolver resolve;
  final Duration refreshWindow;
  final int maxRefreshesInWindow;

  Future<StorageLink>? _pending;
  StorageLink? _latest;
  final Queue<DateTime> _refreshTimes = Queue<DateTime>();

  Future<StorageLink> current(DateTime now) {
    final existing = _pending;
    if (existing != null) return existing;
    return _pending = _resolveAndKeep(forceRefresh: false);
  }

  Future<StorageLink> refresh(StorageLink stale, DateTime now) {
    if (!identical(_latest, stale)) {
      return current(now);
    }
    while (_refreshTimes.isNotEmpty && now.difference(_refreshTimes.first) > refreshWindow) {
      _refreshTimes.removeFirst();
    }
    if (_refreshTimes.length >= maxRefreshesInWindow) {
      return Future<StorageLink>.error(
        const StorageException(StorageErrorKind.unauthorized, 'Origin keeps refusing the link'),
      );
    }
    _refreshTimes.addLast(now);
    _latest = null;
    return _pending = _resolveAndKeep(forceRefresh: true);
  }

  Future<StorageLink> _resolveAndKeep({required bool forceRefresh}) async {
    try {
      final link = await resolve(forceRefresh: forceRefresh);
      _latest = link;
      return link;
    } catch (_) {
      _pending = null;
      rethrow;
    }
  }
}

abstract interface class _CancelableOp {
  bool get cancelled;
  HttpClientRequest? get request;
  set request(HttpClientRequest? value);

  void checkCancelled();
  Future<T> untilCancelled<T>(Future<T> future);
}

class _CancelSignal implements _CancelableOp {
  final Completer<void> _completer = Completer<void>();

  @override
  HttpClientRequest? request;

  @override
  bool get cancelled => _completer.isCompleted;

  Future<void> get future => _completer.future;

  @override
  void checkCancelled() {
    if (cancelled) throw const _CancelledException();
  }

  @override
  Future<T> untilCancelled<T>(Future<T> future) {
    if (cancelled) return Future<T>.error(const _CancelledException());
    return Future.any([future, _completer.future.then<T>((_) => throw const _CancelledException())]);
  }

  void cancel() {
    if (!_completer.isCompleted) _completer.complete();
    request?.abort(const _CancelledException());
    request = null;
  }
}

class _SingleOp implements _CancelableOp {
  _SingleOp(this._signal);

  final _CancelSignal _signal;

  @override
  HttpClientRequest? get request => _signal.request;

  @override
  set request(HttpClientRequest? value) => _signal.request = value;

  @override
  bool get cancelled => _signal.cancelled;

  @override
  void checkCancelled() => _signal.checkCancelled();

  @override
  Future<T> untilCancelled<T>(Future<T> future) => _signal.untilCancelled(future);

  void cancel() => _signal.cancel();
}

class _InFlightFetch implements _CancelableOp {
  _InFlightFetch(this.slot);

  final _ChunkSlot slot;
  final Completer<void> _done = Completer<void>();
  bool _superseded = false;

  @override
  HttpClientRequest? request;
  StreamIterator<List<int>>? bodyIterator;

  @override
  bool get cancelled => _done.isCompleted || slot.cancelled;

  @override
  void checkCancelled() {
    if (_superseded) throw const _SupersededByPeer();
    if (cancelled) throw const _CancelledException();
  }

  @override
  Future<T> untilCancelled<T>(Future<T> future) {
    if (_superseded) return Future<T>.error(const _SupersededByPeer());
    if (cancelled) return Future<T>.error(const _CancelledException());
    return Future.any([
      future,
      _done.future.then<T>((_) => throw (_superseded ? const _SupersededByPeer() : const _CancelledException())),
    ]);
  }

  void supersede() {
    _superseded = true;
    abort();
  }

  void abort() {
    if (!_done.isCompleted) _done.complete();
    request?.abort(_superseded ? const _SupersededByPeer() : const _CancelledException());
    request = null;
    final body = bodyIterator;
    bodyIterator = null;
    if (body != null) {
      unawaited(body.cancel().catchError((Object _) {}));
    }
  }
}

class _CancelledException implements Exception {
  const _CancelledException();
}

class _SupersededByPeer implements Exception {
  const _SupersededByPeer();
}
