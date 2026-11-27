import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../utils/app_logger.dart';
import 'storage_driver.dart';

/// Opened upstream HLS segment ready to stream to the local proxy response.
class HlsSegmentResponse {
  const HlsSegmentResponse({
    required this.statusCode,
    required this.body,
    this.contentType,
    this.contentLength,
  });

  final int statusCode;
  final String? contentType;
  final int? contentLength;
  final Stream<List<int>> body;
}

typedef HlsHeadersResolver = Future<Map<String, String>> Function({required bool forceRefresh});

/// Concurrent sliding-window prefetcher for ordered HLS media segments.
///
/// Serves the active segment immediately as bytes arrive while prefetching
/// subsequent segments in the playlist across multiple connections into a
/// bounded LRU memory pool.
class HlsSegmentPrefetcher {
  HlsSegmentPrefetcher(
    this._client, {
    int? maxCacheBytes,
    int? defaultMaxConnections,
    int? maxSingleSegmentCacheBytes,
    this.stallTimeout = const Duration(seconds: 20),
    this.rateLimitCooldown = const Duration(seconds: 60),
    this.statsLogInterval = defaultStatsLogInterval,
  }) : assert((maxCacheBytes ?? defaultMaxCacheBytesForPlatform) > 0),
       maxCacheBytes = maxCacheBytes ?? defaultMaxCacheBytesForPlatform,
       defaultMaxConnections = defaultMaxConnections ?? defaultMaxConnectionsForPlatform,
       maxSingleSegmentCacheBytes =
           maxSingleSegmentCacheBytes ?? max(1, (maxCacheBytes ?? defaultMaxCacheBytesForPlatform) ~/ 2);

  static const Duration defaultStatsLogInterval = Duration(seconds: 15);

  static int get defaultMaxCacheBytesForPlatform =>
      (Platform.isAndroid || Platform.isIOS) ? 16 * 1024 * 1024 : 32 * 1024 * 1024;

  static int get defaultMaxConnectionsForPlatform => (Platform.isAndroid || Platform.isIOS) ? 4 : 6;

  static const Set<int> _staleStatuses = {
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

  final HttpClient _client;
  final int maxCacheBytes;
  final int defaultMaxConnections;
  final int maxSingleSegmentCacheBytes;
  final Duration stallTimeout;
  final Duration rateLimitCooldown;
  final Duration statsLogInterval;

  final LinkedHashMap<_SegmentKey, _SegmentSlot> _lru = LinkedHashMap<_SegmentKey, _SegmentSlot>();
  final Map<String, _PlaylistState> _playlists = {};
  int _reservedBytes = 0;

  @visibleForTesting
  int get cachedBytes => _reservedBytes;

  @visibleForTesting
  int get cachedSegmentCount => _lru.length;

  /// Opens segment at [segmentPosition] in [segmentUrls] for [playlistKey],
  /// returning cached or streaming bytes while concurrently prefetching ahead.
  Future<HlsSegmentResponse> openSegment({
    required String playlistKey,
    required List<Uri> segmentUrls,
    required int segmentPosition,
    required HlsHeadersResolver resolveHeaders,
    int? maxConnections,
  }) async {
    if (segmentPosition < 0 || segmentPosition >= segmentUrls.length) {
      throw const StorageException(StorageErrorKind.notFound, 'HLS segment index out of range');
    }

    final configuredMax = max(1, maxConnections ?? defaultMaxConnections);
    final playlist = _playlistFor(playlistKey, resolveHeaders, configuredMax);
    final effectiveMax = playlist.effectiveMaxConnections(clock.now(), rateLimitCooldown);

    playlist.activeWindowStart = segmentPosition;
    playlist.activeWindowEnd = min(segmentUrls.length - 1, segmentPosition + effectiveMax);

    _cancelOrphanedPrefetches(playlist);

    final key = _SegmentKey(playlistKey, segmentPosition);
    final targetUrl = segmentUrls[segmentPosition];
    var existing = _lru[key];
    if (existing != null && existing.url != targetUrl) {
      _removeFromLru(key);
      existing.cancel();
      existing = null;
    }
    if (existing != null && existing.completed && !existing.uncacheable && existing.error == null) {
      _touchLru(key, existing);
      playlist.windowCacheHits++;
      _maybeLogStats(playlist, clock.now());
      _schedulePrefetch(playlist, segmentUrls, effectiveMax);
      return HlsSegmentResponse(
        statusCode: existing.statusCode,
        contentType: existing.contentType,
        contentLength: existing.contentLength ?? existing.bufferedBytes,
        body: Stream<List<int>>.fromIterable([
          for (final chunk in existing.chunks) ?chunk,
        ]),
      );
    }

    final _SegmentSlot slot;
    if (existing != null && !existing.cancelled && existing.error == null && !existing.uncacheable) {
      _touchLru(key, existing);
      slot = existing;
    } else {
      if (existing != null) _removeFromLru(key);
      slot = _SegmentSlot(key: key, url: segmentUrls[segmentPosition]);
      _lru[key] = slot;
    }

    slot.activeConsumers++;
    try {
      if (!slot.fetching && !slot.completed) {
        _startFetch(slot, playlist, segmentUrls, effectiveMax);
      }
      _schedulePrefetch(playlist, segmentUrls, effectiveMax);

      await slot.waitForHeaders();
      if (slot.error != null) {
        throw slot.error!;
      }
      if (slot.cancelled) {
        throw const StorageException(StorageErrorKind.network, 'Segment request cancelled');
      }

      return HlsSegmentResponse(
        statusCode: slot.statusCode,
        contentType: slot.contentType,
        contentLength: slot.contentLength,
        body: _consumeSlotBody(slot, playlist, segmentUrls),
      );
    } catch (_) {
      slot.activeConsumers--;
      rethrow;
    }
  }

  /// Drops all cached and in-flight segments whose playlist key starts with [keyPrefix].
  void evictByPrefix(String keyPrefix) {
    final keys = _lru.keys.where((k) => k.playlistKey.startsWith(keyPrefix)).toList();
    for (final key in keys) {
      _removeFromLru(key)?.cancel();
    }
    _playlists.removeWhere((k, _) => k.startsWith(keyPrefix));
  }

  /// Cancels all in-flight segment fetches and empties the cache pool.
  void clear() {
    final slots = _lru.values.toList();
    _lru.clear();
    _reservedBytes = 0;
    for (final slot in slots) {
      slot.cancel();
    }
    _playlists.clear();
  }

  _PlaylistState _playlistFor(String playlistKey, HlsHeadersResolver resolveHeaders, int configuredMax) {
    final existing = _playlists[playlistKey];
    if (existing != null) {
      existing.updateConfig(resolveHeaders, configuredMax);
      return existing;
    }
    return _playlists[playlistKey] = _PlaylistState(
      playlistKey: playlistKey,
      configuredMaxConnections: configuredMax,
      refresher: _HeadersRefresher(resolveHeaders),
    );
  }

  void _cancelOrphanedPrefetches(_PlaylistState playlist) {
    final keys = _lru.keys.where((k) => k.playlistKey == playlist.playlistKey).toList();
    for (final key in keys) {
      final slot = _lru[key];
      if (slot == null || slot.completed || slot.activeConsumers > 0) continue;
      if (!playlist.isInWindow(key.position)) {
        _removeFromLru(key);
        slot.cancel();
      }
    }
  }

  void _cancelBackgroundPrefetches(String playlistKey) {
    final keys = _lru.keys.where((k) => k.playlistKey == playlistKey).toList();
    for (final key in keys) {
      final slot = _lru[key];
      if (slot == null || slot.completed || slot.activeConsumers > 0) continue;
      _removeFromLru(key);
      slot.cancel();
    }
  }

  void _schedulePrefetch(_PlaylistState playlist, List<Uri> segmentUrls, int effectiveMax) {
    if (effectiveMax <= 1) return;
    var active = _activeFetchCount(playlist.playlistKey);
    if (active >= effectiveMax) return;

    final start = playlist.activeWindowStart + 1;
    final end = min(segmentUrls.length - 1, playlist.activeWindowEnd);
    for (var pos = start; pos <= end && active < effectiveMax; pos++) {
      final key = _SegmentKey(playlist.playlistKey, pos);
      final targetUrl = segmentUrls[pos];
      var existing = _lru[key];
      if (existing != null && existing.url != targetUrl) {
        _removeFromLru(key);
        existing.cancel();
        existing = null;
      }
      if (existing != null && !existing.cancelled && existing.error == null) {
        continue;
      }
      if (existing != null) _removeFromLru(key);
      _evictToFit(0);
      if (_reservedBytes >= maxCacheBytes) break;

      final slot = _SegmentSlot(key: key, url: segmentUrls[pos]);
      _lru[key] = slot;
      _startFetch(slot, playlist, segmentUrls, effectiveMax);
      active++;
    }
  }

  int _activeFetchCount(String playlistKey) {
    var count = 0;
    for (final entry in _lru.entries) {
      if (entry.key.playlistKey == playlistKey && entry.value.fetching) count++;
    }
    return count;
  }

  bool _evictToFit(int neededBytes) {
    if (_reservedBytes + neededBytes <= maxCacheBytes) return true;
    final keys = _lru.keys.toList();
    for (final key in keys) {
      if (_reservedBytes + neededBytes <= maxCacheBytes) return true;
      final slot = _lru[key];
      if (slot == null || slot.activeConsumers > 0) continue;
      final owner = _playlists[key.playlistKey];
      if (owner != null && owner.isInWindow(key.position) && !slot.completed) continue;
      if (owner != null && owner.isInWindow(key.position)) continue;
      _removeFromLru(key);
      slot.cancel();
    }
    return _reservedBytes + neededBytes <= maxCacheBytes;
  }

  void _touchLru(_SegmentKey key, _SegmentSlot slot) {
    if (!identical(_lru[key], slot)) return;
    _lru.remove(key);
    _lru[key] = slot;
  }

  _SegmentSlot? _removeFromLru(_SegmentKey key) {
    final removed = _lru.remove(key);
    if (removed != null) {
      _reservedBytes -= removed.trackedBytes;
      removed.trackedBytes = 0;
    }
    return removed;
  }

  void _removeSlotIfExact(_SegmentSlot slot) {
    if (identical(_lru[slot.key], slot)) {
      _removeFromLru(slot.key);
    }
  }

  void _markUncacheable(_PlaylistState playlist, _SegmentSlot slot, int observedBytes) {
    slot.uncacheable = true;
    _removeSlotIfExact(slot);
    if (!playlist.loggedUncacheable) {
      playlist.loggedUncacheable = true;
      appLogger.w(
        'HLS prefetch segment uncacheable: pos=${slot.key.position} '
        'bytes=$observedBytes limit=$maxSingleSegmentCacheBytes',
      );
    }
  }

  void _maybeLogStats(_PlaylistState playlist, DateTime now) {
    if (statsLogInterval <= Duration.zero) return;
    final windowStart = playlist.statsWindowStart;
    if (windowStart == null) {
      playlist.statsWindowStart = now;
      return;
    }
    final elapsedMs = now.difference(windowStart).inMilliseconds;
    if (elapsedMs < statsLogInterval.inMilliseconds || playlist.windowUpstreamBytes <= 0) {
      return;
    }
    final elapsedSec = elapsedMs / 1000.0;
    final upMBs = (playlist.windowUpstreamBytes / (1024 * 1024)) / elapsedSec;
    final perConnMBs = playlist.windowCompletedMs > 0
        ? (playlist.windowCompletedBytes / (1024 * 1024)) / (playlist.windowCompletedMs / 1000.0)
        : 0.0;
    final active = _activeFetchCount(playlist.playlistKey);
    final effectiveMax = playlist.effectiveMaxConnections(now, rateLimitCooldown);
    final cacheMiB = (_reservedBytes / (1024 * 1024)).toStringAsFixed(1);
    final maxMiB = (maxCacheBytes / (1024 * 1024)).toStringAsFixed(1);
    appLogger.i(
      'HLS prefetch stats: up=${upMBs.toStringAsFixed(2)}MB/s '
      'perConn=${perConnMBs.toStringAsFixed(2)}MB/s '
      'conn=$active/$effectiveMax(peak=${playlist.windowPeakActiveConns},cfg=${playlist.configuredMaxConnections}) '
      'segs=${playlist.windowSegmentsCompleted} hits=${playlist.windowCacheHits} '
      'cache=$cacheMiB/${maxMiB}MiB',
    );
    playlist.resetStatsWindow(now);
  }

  void _startFetch(_SegmentSlot slot, _PlaylistState playlist, List<Uri> segmentUrls, int effectiveMax) {
    if (slot.fetching || slot.completed || slot.cancelled) return;
    slot.fetching = true;
    slot.fetchStartedAt = clock.now();
    playlist.recordActiveConns(_activeFetchCount(playlist.playlistKey));
    unawaited(_runFetch(slot, playlist, segmentUrls, effectiveMax));
  }

  Future<void> _runFetch(
    _SegmentSlot slot,
    _PlaylistState playlist,
    List<Uri> segmentUrls,
    int effectiveMax,
  ) async {
    try {
      var headers = await slot.untilCancelled(playlist.refresher.current());
      var response = await _followRedirects(slot, slot.url, headers);
      if (_staleStatuses.contains(response.statusCode)) {
        await response.listen(null).cancel().catchError((Object _) {});
        headers = await slot.untilCancelled(playlist.refresher.refresh(headers));
        response = await _followRedirects(slot, slot.url, headers);
      }

      final status = response.statusCode;
      if (status == HttpStatus.tooManyRequests) {
        await response.listen(null).cancel().catchError((Object _) {});
        final now = clock.now();
        final prevMax = playlist.effectiveMaxConnections(now, rateLimitCooldown);
        playlist.recordRateLimit(now);
        final nextMax = playlist.effectiveMaxConnections(now, rateLimitCooldown);
        appLogger.w(
          'HLS prefetch rate-limited (HTTP 429): maxConn $prevMax->$nextMax '
          'cooldown=${rateLimitCooldown.inSeconds}s host=${slot.url.host}',
        );
        _cancelBackgroundPrefetches(playlist.playlistKey);
        _failSlot(slot, const StorageException(StorageErrorKind.rateLimited, 'Origin answered HTTP 429'));
        return;
      }
      if (status >= 400) {
        await response.listen(null).cancel().catchError((Object _) {});
        _failSlot(slot, StorageException(_kindFor(status), 'Origin answered HTTP $status'));
        return;
      }

      final contentLength = response.contentLength >= 0 ? response.contentLength : null;
      slot.statusCode = status;
      slot.contentType = response.headers.value(HttpHeaders.contentTypeHeader);
      slot.contentLength = contentLength;

      if (contentLength != null && contentLength > maxSingleSegmentCacheBytes) {
        _markUncacheable(playlist, slot, contentLength);
        if (slot.activeConsumers == 0) {
          await response.listen(null).cancel().catchError((Object _) {});
          slot.cancel();
          return;
        }
      }

      slot.markHeadersReady();

      final body = StreamIterator(response.timeout(stallTimeout));
      slot.activeBody = body;
      try {
        while (await slot.untilCancelled(body.moveNext())) {
          if (slot.cancelled) return;
          final raw = body.current;
          if (raw.isEmpty) continue;
          final copy = Uint8List.fromList(raw);
          playlist.windowUpstreamBytes += copy.length;

          if (!slot.uncacheable) {
            final nextSize = slot.bufferedBytes + copy.length;
            if (nextSize > maxSingleSegmentCacheBytes || !_evictToFit(copy.length)) {
              _markUncacheable(playlist, slot, nextSize);
              if (slot.activeConsumers == 0) {
                slot.cancel();
                return;
              }
            } else if (identical(_lru[slot.key], slot)) {
              slot.trackedBytes += copy.length;
              _reservedBytes += copy.length;
            }
          }

          slot.chunks.add(copy);
          slot.bufferedBytes += copy.length;
          slot.notifyProgress();
        }
        if (slot.cancelled) return;
        final now = clock.now();
        slot.completed = true;
        slot.fetching = false;
        playlist.windowSegmentsCompleted++;
        playlist.windowCompletedBytes += slot.bufferedBytes;
        if (slot.fetchStartedAt case final started?) {
          playlist.windowCompletedMs += max(1, now.difference(started).inMilliseconds);
        }
        slot.notifyProgress();
        _maybeLogStats(playlist, now);
        if (!slot.uncacheable) {
          _schedulePrefetch(playlist, segmentUrls, playlist.effectiveMaxConnections(now, rateLimitCooldown));
        }
      } on _CancelledException {
        return;
      } on Exception catch (e) {
        if (!slot.cancelled) {
          _failSlot(slot, StorageException(StorageErrorKind.network, 'Segment stream interrupted: $e', cause: e));
        }
      } finally {
        slot.activeBody = null;
        await body.cancel().catchError((Object _) {});
      }
    } on _CancelledException {
      return;
    } on StorageException catch (e) {
      if (!slot.cancelled) _failSlot(slot, e);
    } catch (e) {
      if (!slot.cancelled) _failSlot(slot, StorageException(StorageErrorKind.network, '$e', cause: e));
    } finally {
      slot.fetching = false;
      slot.releaseWaiters();
    }
  }

  void _failSlot(_SegmentSlot slot, StorageException error) {
    if (slot.completed || slot.cancelled) return;
    _removeSlotIfExact(slot);
    slot.error = error;
    slot.fetching = false;
    slot.markHeadersReady();
    slot.notifyProgress();
  }

  Stream<List<int>> _consumeSlotBody(_SegmentSlot slot, _PlaylistState playlist, List<Uri> segmentUrls) {
    var disposed = false;
    final cancelCompleter = Completer<void>();
    late StreamSubscription<List<int>> subscription;
    final controller = StreamController<List<int>>(sync: true);

    void disposeConsumer() {
      if (disposed) return;
      disposed = true;
      if (!cancelCompleter.isCompleted) cancelCompleter.complete();
      slot.activeConsumers--;
      if (slot.activeConsumers <= 0 && !slot.completed && (slot.uncacheable || !playlist.isInWindow(slot.key.position))) {
        _removeSlotIfExact(slot);
        slot.cancel();
      }
    }

    Stream<List<int>> pump() async* {
      var chunkIndex = 0;
      try {
        while (!cancelCompleter.isCompleted) {
          if (chunkIndex < slot.chunks.length) {
            final chunk = slot.chunks[chunkIndex];
            if (slot.uncacheable) {
              slot.chunks[chunkIndex] = null;
            }
            chunkIndex++;
            if (chunk != null && chunk.isNotEmpty) {
              yield chunk;
            }
            continue;
          }
          if (slot.error != null) {
            throw slot.error!;
          }
          if (slot.completed) {
            return;
          }
          if (slot.cancelled) {
            throw const StorageException(StorageErrorKind.network, 'Segment request cancelled');
          }
          await Future.any<void>([slot.waitForProgress(), cancelCompleter.future]);
        }
      } finally {
        disposeConsumer();
      }
    }

    controller.onListen = () {
      subscription = pump().listen(
        controller.add,
        onError: controller.addError,
        onDone: () {
          disposeConsumer();
          if (!controller.isClosed) controller.close();
        },
      );
    };
    controller.onPause = () => subscription.pause();
    controller.onResume = () => subscription.resume();
    controller.onCancel = () async {
      disposeConsumer();
      await subscription.cancel();
    };
    return controller.stream;
  }

  Future<HttpClientResponse> _followRedirects(
    _SegmentSlot slot,
    Uri initialUrl,
    Map<String, String> initialHeaders,
  ) async {
    var uri = initialUrl;
    var headers = initialHeaders;
    for (var redirects = 0; ; redirects++) {
      final response = await _sendGet(slot, uri, headers);
      final location = response.isRedirect ? response.headers.value(HttpHeaders.locationHeader) : null;
      if (location == null) return response;
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

  Future<HttpClientResponse> _sendGet(_SegmentSlot slot, Uri uri, Map<String, String> headers) async {
    try {
      if (slot.cancelled) throw const _CancelledException();
      final opening = _client.getUrl(uri).then((request) {
        unawaited(request.done.then<void>((_) {}, onError: (Object _) {}));
        if (slot.cancelled) {
          request.abort(const _CancelledException());
          throw const _CancelledException();
        }
        return request;
      });
      final request = await slot.untilCancelled(opening);
      slot.activeRequest = request;
      headers.forEach(request.headers.set);
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      request.followRedirects = false;

      final responseFuture = request.close();
      unawaited(responseFuture.then<void>((_) {}, onError: (Object _) {}));
      try {
        return await slot.untilCancelled(
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
        if (identical(slot.activeRequest, request)) {
          slot.activeRequest = null;
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

  static StorageErrorKind _kindFor(int status) => switch (status) {
    HttpStatus.unauthorized || HttpStatus.forbidden => StorageErrorKind.unauthorized,
    HttpStatus.notFound || HttpStatus.gone => StorageErrorKind.notFound,
    HttpStatus.tooManyRequests => StorageErrorKind.rateLimited,
    _ => StorageErrorKind.other,
  };
}

class _SegmentKey {
  const _SegmentKey(this.playlistKey, this.position);

  final String playlistKey;
  final int position;

  @override
  bool operator ==(Object other) => other is _SegmentKey && other.playlistKey == playlistKey && other.position == position;

  @override
  int get hashCode => Object.hash(playlistKey, position);
}

class _SegmentSlot {
  _SegmentSlot({required this.key, required this.url});

  final _SegmentKey key;
  final Uri url;

  int statusCode = HttpStatus.ok;
  String? contentType;
  int? contentLength;
  bool headersReady = false;
  bool completed = false;
  bool uncacheable = false;
  bool cancelled = false;
  bool fetching = false;
  Object? error;
  int activeConsumers = 0;
  int bufferedBytes = 0;
  int trackedBytes = 0;
  DateTime? fetchStartedAt;
  final List<Uint8List?> chunks = [];

  HttpClientRequest? activeRequest;
  StreamIterator<List<int>>? activeBody;

  final Completer<void> _cancelled = Completer<void>();
  final Completer<void> _headersReady = Completer<void>();
  Completer<void> _progressSignal = Completer<void>();

  Future<void> waitForHeaders() => headersReady ? Future<void>.value() : _headersReady.future;

  Future<void> waitForProgress() => _progressSignal.future;

  Future<T> untilCancelled<T>(Future<T> future) {
    if (cancelled) return Future<T>.error(const _CancelledException());
    return Future.any([future, _cancelled.future.then<T>((_) => throw const _CancelledException())]);
  }

  void markHeadersReady() {
    headersReady = true;
    if (!_headersReady.isCompleted) {
      _headersReady.complete();
    }
  }

  void notifyProgress() {
    if (!_progressSignal.isCompleted) {
      _progressSignal.complete();
    }
    _progressSignal = Completer<void>();
  }

  void releaseWaiters() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }

  void cancel() {
    if (cancelled) return;
    cancelled = true;
    fetching = false;
    releaseWaiters();
    activeRequest?.abort(const _CancelledException());
    activeRequest = null;
    final body = activeBody;
    activeBody = null;
    if (body != null) {
      unawaited(body.cancel().catchError((Object _) {}));
    }
    markHeadersReady();
    notifyProgress();
  }
}

class _PlaylistState {
  _PlaylistState({required this.playlistKey, required this.configuredMaxConnections, required this.refresher})
    : _dynamicMaxConnections = configuredMaxConnections;

  final String playlistKey;
  int configuredMaxConnections;
  final _HeadersRefresher refresher;

  int activeWindowStart = 0;
  int activeWindowEnd = 0;
  int _dynamicMaxConnections;
  DateTime? _lastRateLimitAt;
  DateTime? statsWindowStart;
  int windowUpstreamBytes = 0;
  int windowSegmentsCompleted = 0;
  int windowCompletedBytes = 0;
  int windowCompletedMs = 0;
  int windowCacheHits = 0;
  int windowPeakActiveConns = 0;
  bool loggedUncacheable = false;

  void recordActiveConns(int active) {
    if (active > windowPeakActiveConns) {
      windowPeakActiveConns = active;
    }
  }

  void resetStatsWindow(DateTime now) {
    statsWindowStart = now;
    windowUpstreamBytes = 0;
    windowSegmentsCompleted = 0;
    windowCompletedBytes = 0;
    windowCompletedMs = 0;
    windowCacheHits = 0;
    windowPeakActiveConns = 0;
  }

  void updateConfig(HlsHeadersResolver resolveHeaders, int maxConnections) {
    refresher.resolveHeaders = resolveHeaders;
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

  bool isInWindow(int position) => position >= activeWindowStart && position <= activeWindowEnd;
}

class _HeadersRefresher {
  _HeadersRefresher(this.resolveHeaders);

  HlsHeadersResolver resolveHeaders;
  Future<Map<String, String>>? _pending;
  Map<String, String>? _latest;

  Future<Map<String, String>> current() {
    final existing = _pending;
    if (existing != null) return existing;
    return _pending = _resolveAndKeep(forceRefresh: false);
  }

  Future<Map<String, String>> refresh(Map<String, String> stale) {
    if (!identical(_latest, stale)) {
      return current();
    }
    _latest = null;
    return _pending = _resolveAndKeep(forceRefresh: true);
  }

  Future<Map<String, String>> _resolveAndKeep({required bool forceRefresh}) async {
    try {
      final headers = await resolveHeaders(forceRefresh: forceRefresh);
      _latest = headers;
      return headers;
    } catch (_) {
      _pending = null;
      rethrow;
    }
  }
}

class _CancelledException implements Exception {
  const _CancelledException();
}
