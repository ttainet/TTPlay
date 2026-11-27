import 'dart:async';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:ttplay/storage/http_range_reader.dart';
import 'package:ttplay/storage/playback_prefetch_cache.dart';
import 'package:ttplay/storage/storage_driver.dart';
import 'package:ttplay/utils/app_logger.dart' as logging;

class _RecordingLogOutput extends LogOutput {
  final List<String> lines = [];

  @override
  void output(OutputEvent event) => lines.addAll(event.lines);
}

class _TestOrigin {
  _TestOrigin(this.content);

  final List<int> content;
  late HttpServer _server;

  final List<String?> ranges = [];
  final List<String> paths = [];
  int active = 0;
  int maxActive = 0;

  bool ignoreRange = false;
  final Set<String> refused = {};
  final Map<String, int> statusOnceByPath = {};
  final Map<String, int> expiresAfter = {};
  final Map<int, int> statusByStart = {};
  final Set<int> truncateAfterFirstHalfOnce = {};
  final Map<int, String> contentRanges = {};
  final Map<int, Completer<void>> pauseMidChunkAfterHalf = {};
  final Map<int, Completer<void>> delayBeforeFirstByte = {};
  final Map<int, Completer<void>> firstHalfSent = {};
  final Set<int> abortWhenSecondStarts = {};
  Duration responseDelay = const Duration(milliseconds: 10);

  Uri link(String name) => Uri.parse('http://127.0.0.1:${_server.port}/$name');

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> stop() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    final range = request.headers.value(HttpHeaders.rangeHeader);
    final path = request.uri.path;
    ranges.add(range);
    paths.add(path);
    active++;
    if (active > maxActive) maxActive = active;
    try {
      if (responseDelay > Duration.zero) {
        await Future<void>.delayed(responseDelay);
      }
      final onceStatus = statusOnceByPath.remove(path);
      if (onceStatus != null) {
        response.statusCode = onceStatus;
        return;
      }
      final left = expiresAfter[path];
      if (left != null) {
        if (left <= 0) refused.add(path);
        expiresAfter[path] = left - 1;
      }
      if (refused.contains(path)) {
        response.statusCode = HttpStatus.forbidden;
        return;
      }

      final match = range == null ? null : RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
      if (ignoreRange || match == null) {
        response.contentLength = content.length;
        response.add(content);
        return;
      }

      final start = int.parse(match[1]!);
      final end = match[2]!.isEmpty ? content.length - 1 : int.parse(match[2]!);

      final forcedStatus = statusByStart.remove(start);
      if (forcedStatus != null) {
        response.statusCode = forcedStatus;
        return;
      }

      final firstByteGate = delayBeforeFirstByte.remove(start);
      if (firstByteGate != null) {
        await firstByteGate.future;
      }

      final body = content.sublist(start, end + 1);
      response.statusCode = HttpStatus.partialContent;
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        contentRanges[start] ?? 'bytes $start-$end/${content.length}',
      );

      final midGate = pauseMidChunkAfterHalf.remove(start);
      if (midGate != null) {
        final half = body.length ~/ 2;
        response.bufferOutput = false;
        response.contentLength = body.length;
        response.add(body.sublist(0, half));
        await response.flush();
        firstHalfSent.remove(start)?.complete();
        await midGate.future;
        response.add(body.sublist(half));
        return;
      }

      if (truncateAfterFirstHalfOnce.remove(start)) {
        final half = body.length ~/ 2;
        response.headers.chunkedTransferEncoding = true;
        response.add(body.sublist(0, half));
        await response.flush();
        // Close early without sending the rest.
        return;
      }

      response.contentLength = body.length;
      response.add(body);
    } catch (_) {
      // Client aborted socket mid-response.
    } finally {
      active--;
      await response.close().catchError((Object _) {});
    }
  }
}

void main() {
  late _TestOrigin origin;
  late HttpClient client;
  final content = List<int>.generate(10240, (i) => (i * 13) % 256);

  setUp(() async {
    HttpOverrides.global = null;
    origin = _TestOrigin(content);
    await origin.start();
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await origin.stop();
  });

  StorageLinkResolver resolverFor(List<String> names, [List<bool>? calls]) {
    var index = 0;
    return ({required bool forceRefresh}) async {
      calls?.add(forceRefresh);
      if (forceRefresh && index + 1 < names.length) index++;
      return StorageLink(origin.link(names[index]));
    };
  }

  Future<List<int>> collect(Stream<List<int>> stream) async => (await stream.toList()).expand((c) => c).toList();

  test('streams chunk 0 immediately without waiting for the full chunk to finish', () async {
    final releaseRest = Completer<void>();
    final halfSent = Completer<void>();
    addTearDown(() {
      if (!releaseRest.isCompleted) releaseRest.complete();
    });
    origin.pauseMidChunkAfterHalf[0] = releaseRest;
    origin.firstHalfSent[0] = halfSent;

    final cache = PlaybackPrefetchCache(
      client,
      chunkSize: 1000,
      maxCacheBytes: 8000,
      defaultMaxConnections: 2,
      hedgeDelay: const Duration(seconds: 10),
    );
    addTearDown(cache.clear);

    final received = <int>[];
    final firstEmission = Completer<void>();
    final done = Completer<void>();
    final sub = cache
        .read(
          fileKey: 'f1',
          resolve: resolverFor(['a']),
          start: 0,
          end: 1999,
          totalSize: content.length,
        )
        .listen(
          (bytes) {
            received.addAll(bytes);
            if (!firstEmission.isCompleted) firstEmission.complete();
          },
          onDone: done.complete,
        );
    addTearDown(sub.cancel);

    await halfSent.future.timeout(const Duration(seconds: 2));
    await firstEmission.future.timeout(const Duration(seconds: 2));
    expect(received.length, 500);
    expect(received, content.sublist(0, 500));

    releaseRest.complete();
    await done.future.timeout(const Duration(seconds: 2));
    expect(received, content.sublist(0, 2000));
  });

  test('small probe requests use a single direct connection without prefetch', () async {
    final cache = PlaybackPrefetchCache(
      client,
      chunkSize: 1000,
      maxCacheBytes: 8000,
      defaultMaxConnections: 4,
    );
    addTearDown(cache.clear);

    final head = await collect(
      cache.read(fileKey: 'f1', resolve: resolverFor(['a']), start: 0, end: 255, totalSize: content.length),
    );
    final tail = await collect(
      cache.read(
        fileKey: 'f1',
        resolve: resolverFor(['a']),
        start: content.length - 200,
        end: content.length - 1,
        totalSize: content.length,
      ),
    );

    expect(head, content.sublist(0, 256));
    expect(tail, content.sublist(content.length - 200));
    expect(origin.ranges, ['bytes=0-255', 'bytes=${content.length - 200}-${content.length - 1}']);
    expect(cache.cachedChunkCount, 0);
  });

  test('sequential large reads ramp up concurrent prefetch and assemble exact bytes', () async {
    origin.responseDelay = const Duration(milliseconds: 25);
    final cache = PlaybackPrefetchCache(
      client,
      chunkSize: 1000,
      maxCacheBytes: 12000,
      defaultMaxConnections: 4,
      rampUpFirstBytes: 200,
      rampUpFullBytes: 500,
    );
    addTearDown(cache.clear);

    final bytes = await collect(
      cache.read(
        fileKey: 'f1',
        resolve: resolverFor(['a']),
        start: 300,
        end: 7699,
        totalSize: content.length,
      ),
    );

    expect(bytes, content.sublist(300, 7700));
    expect(origin.maxActive, greaterThan(1));
    expect(origin.maxActive, lessThanOrEqualTo(4));
  });

  test('completed chunks stay in LRU cache for re-reads and evict oldest inactive chunks at budget', () async {
    final cache = PlaybackPrefetchCache(
      client,
      chunkSize: 1000,
      maxCacheBytes: 4000,
      defaultMaxConnections: 2,
      rampUpFirstBytes: 100,
      rampUpFullBytes: 200,
    );
    addTearDown(cache.clear);

    final first = await collect(
      cache.read(fileKey: 'f1', resolve: resolverFor(['a']), start: 0, end: 3999, totalSize: content.length),
    );
    expect(first, content.sublist(0, 4000));
    final countBeforeHit = origin.ranges.length;

    // Re-read chunks 1..2 should hit cache with 0 upstream requests.
    final hit = await collect(
      cache.read(fileKey: 'f1', resolve: resolverFor(['a']), start: 1200, end: 2799, totalSize: content.length),
    );
    expect(hit, content.sublist(1200, 2800));
    expect(origin.ranges.length, countBeforeHit);

    // Read further in another file; LRU budget must be respected.
    final second = await collect(
      cache.read(fileKey: 'f2', resolve: resolverFor(['a']), start: 0, end: 5999, totalSize: content.length),
    );
    expect(second, content.sublist(0, 6000));
    expect(cache.cachedBytes, lessThanOrEqualTo(4000));
  });

  test('cancelling a playback read aborts orphaned in-flight connections while keeping completed chunks', () async {
    final accepted = Completer<void>();
    final disconnected = Completer<void>();
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((socket) {
      socket.listen(
        (_) {
          if (!accepted.isCompleted) accepted.complete();
        },
        onDone: () {
          socket.destroy();
          if (!disconnected.isCompleted) disconnected.complete();
        },
      );
    });

    final cache = PlaybackPrefetchCache(
      client,
      chunkSize: 1000,
      maxCacheBytes: 8000,
      defaultMaxConnections: 3,
      hedgeDelay: const Duration(seconds: 10),
    );
    addTearDown(cache.clear);

    final uri = Uri.parse('http://127.0.0.1:${server.port}/video');
    final sub = cache
        .read(
          fileKey: 'hang',
          resolve: ({required forceRefresh}) async => StorageLink(uri),
          start: 0,
          end: 4999,
          totalSize: 10000,
        )
        .listen((_) {});
    addTearDown(sub.cancel);

    await accepted.future.timeout(const Duration(seconds: 2));
    await sub.cancel().timeout(const Duration(seconds: 2));
    await disconnected.future.timeout(const Duration(seconds: 2));
    expect(cache.cachedChunkCount, 0);
  });

  test('slow first chunk does not block background prefetching of subsequent chunks', () async {
    final releaseChunk0 = Completer<void>();
    final halfSent0 = Completer<void>();
    addTearDown(() {
      if (!releaseChunk0.isCompleted) releaseChunk0.complete();
    });
    origin.pauseMidChunkAfterHalf[0] = releaseChunk0;
    origin.firstHalfSent[0] = halfSent0;

    final cache = PlaybackPrefetchCache(
      client,
      chunkSize: 1000,
      maxCacheBytes: 10000,
      defaultMaxConnections: 4,
      rampUpFirstBytes: 100,
      rampUpFullBytes: 200,
      hedgeDelay: const Duration(seconds: 10),
    );
    addTearDown(cache.clear);

    final bytes = <int>[];
    final done = Completer<void>();
    final sub = cache
        .read(
          fileKey: 'hol',
          resolve: resolverFor(['a']),
          start: 0,
          end: 4999,
          totalSize: content.length,
        )
        .listen(bytes.addAll, onDone: done.complete);
    addTearDown(sub.cancel);

    await halfSent0.future.timeout(const Duration(seconds: 2));
    // Give background workers a moment to fetch chunks 1..4 while chunk 0 is paused.
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (!origin.ranges.contains('bytes=3000-3999') && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(origin.ranges, containsAll(['bytes=1000-1999', 'bytes=2000-2999', 'bytes=3000-3999']));

    releaseChunk0.complete();
    await done.future.timeout(const Duration(seconds: 2));
    expect(bytes, content.sublist(0, 5000));
  });

  test('hedges a stalled active chunk from its written offset without duplicating bytes', () async {
    final stalledPrimary = Completer<void>();
    final halfSent = Completer<void>();
    addTearDown(() {
      if (!stalledPrimary.isCompleted) stalledPrimary.complete();
    });
    origin.pauseMidChunkAfterHalf[0] = stalledPrimary;
    origin.firstHalfSent[0] = halfSent;

    final cache = PlaybackPrefetchCache(
      client,
      chunkSize: 1000,
      maxCacheBytes: 8000,
      defaultMaxConnections: 3,
      hedgeDelay: const Duration(milliseconds: 80),
      stallTimeout: const Duration(seconds: 5),
    );
    addTearDown(cache.clear);

    final result = await collect(
      cache.read(fileKey: 'hedge', resolve: resolverFor(['a']), start: 0, end: 1999, totalSize: content.length),
    ).timeout(const Duration(seconds: 3));

    expect(result, content.sublist(0, 2000));
    expect(origin.ranges, contains('bytes=500-999'));
  });

  test('resumes a truncated chunk from its already written offset', () async {
    origin.truncateAfterFirstHalfOnce.add(0);
    final cache = PlaybackPrefetchCache(
      client,
      chunkSize: 1000,
      maxCacheBytes: 8000,
      defaultMaxConnections: 2,
    );
    addTearDown(cache.clear);

    final result = await collect(
      cache.read(fileKey: 'trunc', resolve: resolverFor(['a']), start: 0, end: 1999, totalSize: content.length),
    );

    expect(result, content.sublist(0, 2000));
    expect(origin.ranges, contains('bytes=500-999'));
  });

  test('refreshes expired links (403/412) across multiple windows beyond 2 total refreshes', () async {
    var fakeNow = DateTime(2026, 11, 26, 21, 0, 0);
    await withClock(Clock(() => fakeNow), () async {
      origin.statusOnceByPath['/l1'] = HttpStatus.forbidden;
      origin.statusOnceByPath['/l2'] = HttpStatus.preconditionFailed;
      origin.statusOnceByPath['/l3'] = HttpStatus.forbidden;
      origin.statusOnceByPath['/l4'] = HttpStatus.preconditionFailed;

      final calls = <bool>[];
      var idx = 0;
      final names = ['l1', 'l2', 'l3', 'l4', 'l5'];
      Future<StorageLink> resolve({required bool forceRefresh}) async {
        calls.add(forceRefresh);
        if (forceRefresh) {
          fakeNow = fakeNow.add(const Duration(seconds: 15));
          idx++;
        }
        return StorageLink(origin.link(names[idx]));
      }

      final cache = PlaybackPrefetchCache(
        client,
        chunkSize: 1000,
        maxCacheBytes: 8000,
        defaultMaxConnections: 2,
        refreshWindow: const Duration(seconds: 30),
        maxRefreshesInWindow: 3,
      );
      addTearDown(cache.clear);

      final result = await collect(
        cache.read(fileKey: 'exp', resolve: resolve, start: 0, end: 1999, totalSize: content.length),
      );
      expect(result, content.sublist(0, 2000));
      expect(calls.where((f) => f), hasLength(4));
    });
  });

  test('fails when link refreshes exceed maxRefreshesInWindow inside one window', () async {
    origin.refused.addAll({'/l1', '/l2', '/l3', '/l4'});
    final cache = PlaybackPrefetchCache(
      client,
      chunkSize: 1000,
      maxCacheBytes: 8000,
      defaultMaxConnections: 2,
      refreshWindow: const Duration(seconds: 30),
      maxRefreshesInWindow: 2,
    );
    addTearDown(cache.clear);

    await expectLater(
      collect(
        cache.read(
          fileKey: 'refuse',
          resolve: resolverFor(['l1', 'l2', 'l3', 'l4']),
          start: 0,
          end: 1999,
          totalSize: content.length,
        ),
      ),
      throwsA(isA<StorageException>().having((e) => e.kind, 'kind', StorageErrorKind.unauthorized)),
    );
  });

  test('halves concurrency on HTTP 429 rate limit responses', () async {
    origin.statusByStart[1000] = HttpStatus.tooManyRequests;
    final cache = PlaybackPrefetchCache(
      client,
      chunkSize: 1000,
      maxCacheBytes: 12000,
      defaultMaxConnections: 4,
      rampUpFirstBytes: 100,
      rampUpFullBytes: 200,
    );
    addTearDown(cache.clear);

    final first = await collect(
      cache.read(fileKey: 'rl', resolve: resolverFor(['a']), start: 0, end: 3999, totalSize: content.length),
    );
    expect(first, content.sublist(0, 4000));

    origin.maxActive = 0;
    origin.responseDelay = const Duration(milliseconds: 25);
    final second = await collect(
      cache.read(fileKey: 'rl', resolve: resolverFor(['a']), start: 4000, end: 8999, totalSize: content.length),
    );
    expect(second, content.sublist(4000, 9000));
    expect(origin.maxActive, lessThanOrEqualTo(2));
  });

  test('falls back cleanly when origin ignores Range and returns 200 OK', () async {
    origin.ignoreRange = true;
    final cache = PlaybackPrefetchCache(
      client,
      chunkSize: 1000,
      maxCacheBytes: 8000,
      defaultMaxConnections: 4,
    );
    addTearDown(cache.clear);

    final first = await collect(
      cache.read(fileKey: 'no-range', resolve: resolverFor(['a']), start: 500, end: 2499, totalSize: content.length),
    );
    expect(first, content.sublist(500, 2500));

    // Subsequent reads on the same file stay on single direct connection.
    final second = await collect(
      cache.read(fileKey: 'no-range', resolve: resolverFor(['a']), start: 3000, end: 4999, totalSize: content.length),
    );
    expect(second, content.sublist(3000, 5000));
    expect(origin.ranges, hasLength(2));
  });

  test('rejects mismatched Content-Range offsets or total size', () async {
    origin.contentRanges[1000] = 'bytes 2000-2999/${content.length}';
    final cache = PlaybackPrefetchCache(
      client,
      chunkSize: 1000,
      maxCacheBytes: 8000,
      defaultMaxConnections: 2,
      rampUpFirstBytes: 100,
      rampUpFullBytes: 200,
    );
    addTearDown(cache.clear);

    await expectLater(
      collect(
        cache.read(fileKey: 'bad-range', resolve: resolverFor(['a']), start: 0, end: 2999, totalSize: content.length),
      ),
      throwsA(isA<StorageException>().having((e) => e.message, 'message', contains('Invalid Content-Range'))),
    );
  });

  test('logs prefetch stats at configured interval and warns on HTTP 429 without leaking query tokens', () async {
    final originalLogger = logging.appLogger;
    final logOutput = _RecordingLogOutput();
    logging.appLogger = Logger(printer: SimplePrinter(), output: logOutput);
    addTearDown(() => logging.appLogger = originalLogger);

    origin.responseDelay = Duration.zero;
    final cache = PlaybackPrefetchCache(
      client,
      chunkSize: 1000,
      maxCacheBytes: 12000,
      defaultMaxConnections: 2,
      rampUpFirstBytes: 100,
      rampUpFullBytes: 200,
      statsLogInterval: const Duration(milliseconds: 40),
    );
    addTearDown(cache.clear);

    Future<StorageLink> resolveSecret({required bool forceRefresh}) async =>
        StorageLink(origin.link('secret-video').replace(queryParameters: {'token': 'supersecret123'}));

    final first = await collect(
      cache.read(fileKey: 'stats', resolve: resolveSecret, start: 0, end: 1999, totalSize: content.length),
    );
    expect(first, content.sublist(0, 2000));

    await Future<void>.delayed(const Duration(milliseconds: 60));

    final second = await collect(
      cache.read(fileKey: 'stats', resolve: resolveSecret, start: 4000, end: 5999, totalSize: content.length),
    );
    expect(second, content.sublist(4000, 6000));

    final statsLines = logOutput.lines.where((l) => l.contains('Prefetch stats')).toList();
    expect(statsLines, hasLength(1));
    expect(statsLines.single, contains('chunks='));
    expect(statsLines.single, contains('perConn='));
    expect(statsLines.single, contains('ttfb='));
    expect(statsLines.single, contains('redir=0'));
    expect(statsLines.single, contains('host=127.0.0.1'));

    origin.statusByStart[6000] = HttpStatus.tooManyRequests;
    final third = await collect(
      cache.read(fileKey: 'stats', resolve: resolveSecret, start: 6000, end: 7999, totalSize: content.length),
    );
    expect(third, content.sublist(6000, 8000));

    final rateLimitLines = logOutput.lines.where((l) => l.contains('Prefetch rate-limited (HTTP 429):')).toList();
    expect(rateLimitLines, hasLength(1));
    expect(rateLimitLines.single, contains('host=127.0.0.1'));
    expect(logOutput.lines.join('\n'), isNot(contains('supersecret123')));
    expect(logOutput.lines.join('\n'), isNot(contains('secret-video')));
  });
}
