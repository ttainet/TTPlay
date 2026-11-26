import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ttplay/storage/hls_segment_prefetcher.dart';
import 'package:ttplay/storage/storage_driver.dart';

class _FakeHlsOrigin {
  late HttpServer server;
  final Map<String, List<int>> segments = {};
  final List<String> requests = [];
  int active = 0;
  int maxActive = 0;
  Duration delay = const Duration(milliseconds: 20);

  String acceptedAuth = 'auth-1';
  bool enforceAuth = false;
  final Map<String, int> statusOnceByPath = {};
  final Map<String, Completer<void>> pauseMidAfterHalf = {};
  final Map<String, Completer<void>> halfSent = {};
  final Map<String, Completer<void>> hangHeaders = {};
  final Map<String, Completer<void>> requestSeen = {};
  final Map<String, Completer<void>> requestDisconnected = {};

  Uri url(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_handle);
  }

  Future<void> stop() => server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    final path = request.uri.path;
    requests.add(path);
    requestSeen.remove(path)?.complete();
    active++;
    if (active > maxActive) maxActive = active;
    try {
      final hang = hangHeaders.remove(path);
      if (hang != null) {
        unawaited(
          request.response.done.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
            requestDisconnected.remove(path)?.complete();
          }),
        );
        await hang.future;
        return;
      }

      if (delay > Duration.zero) {
        await Future<void>.delayed(delay);
      }

      if (enforceAuth && request.headers.value(HttpHeaders.cookieHeader) != 'Video-Auth=$acceptedAuth') {
        response.statusCode = HttpStatus.preconditionFailed;
        return;
      }

      final once = statusOnceByPath.remove(path);
      if (once != null) {
        response.statusCode = once;
        return;
      }

      final data = segments[path];
      if (data == null) {
        response.statusCode = HttpStatus.notFound;
        return;
      }

      response.statusCode = HttpStatus.ok;
      response.headers.contentType = ContentType('video', 'mp4');
      response.contentLength = data.length;

      final midGate = pauseMidAfterHalf.remove(path);
      if (midGate != null) {
        final half = data.length ~/ 2;
        response.bufferOutput = false;
        response.add(data.sublist(0, half));
        await response.flush();
        halfSent.remove(path)?.complete();
        await midGate.future;
        response.add(data.sublist(half));
        return;
      }

      response.add(data);
    } catch (_) {
      requestDisconnected.remove(path)?.complete();
    } finally {
      active--;
      await response.close().catchError((Object _) {});
    }
  }
}

void main() {
  late _FakeHlsOrigin origin;
  late HttpClient client;

  setUp(() async {
    HttpOverrides.global = null;
    origin = _FakeHlsOrigin();
    await origin.start();
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await origin.stop();
  });

  Future<List<int>> readAll(HlsSegmentResponse seg) => seg.body.expand((c) => c).toList();

  test('reading segment 0 prefetches subsequent segments concurrently and serves them from cache', () async {
    final urls = <Uri>[];
    for (var i = 0; i < 5; i++) {
      final path = '/seg$i.m4s';
      origin.segments[path] = List<int>.generate(1024, (j) => (i * 31 + j) % 251);
      urls.add(origin.url(path));
    }

    final prefetcher = HlsSegmentPrefetcher(client, maxCacheBytes: 16 * 1024, defaultMaxConnections: 3);
    addTearDown(prefetcher.clear);

    final seg0 = await prefetcher.openSegment(
      playlistKey: 'm1\u0000/v.mkv\u0000high',
      segmentUrls: urls,
      segmentPosition: 0,
      resolveHeaders: ({required bool forceRefresh}) async => const {},
    );
    expect(await readAll(seg0), origin.segments['/seg0.m4s']);

    // Wait briefly for concurrent prefetches of seg1..seg3 to settle.
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (prefetcher.cachedSegmentCount < 4 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(origin.maxActive, greaterThan(1));
    expect(origin.maxActive, lessThanOrEqualTo(3));

    final seg1 = await prefetcher.openSegment(
      playlistKey: 'm1\u0000/v.mkv\u0000high',
      segmentUrls: urls,
      segmentPosition: 1,
      resolveHeaders: ({required bool forceRefresh}) async => const {},
    );
    final seg2 = await prefetcher.openSegment(
      playlistKey: 'm1\u0000/v.mkv\u0000high',
      segmentUrls: urls,
      segmentPosition: 2,
      resolveHeaders: ({required bool forceRefresh}) async => const {},
    );
    expect(await readAll(seg1), origin.segments['/seg1.m4s']);
    expect(await readAll(seg2), origin.segments['/seg2.m4s']);
    expect(origin.requests.where((p) => p == '/seg1.m4s'), hasLength(1));
    expect(origin.requests.where((p) => p == '/seg2.m4s'), hasLength(1));
  });

  test('streams the active segment immediately as bytes arrive', () async {
    origin.segments['/seg0.m4s'] = List<int>.generate(1000, (i) => i % 251);
    final release = Completer<void>();
    final halfSent = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    origin.pauseMidAfterHalf['/seg0.m4s'] = release;
    origin.halfSent['/seg0.m4s'] = halfSent;

    final prefetcher = HlsSegmentPrefetcher(client, maxCacheBytes: 8192, defaultMaxConnections: 2);
    addTearDown(prefetcher.clear);

    final seg0 = await prefetcher.openSegment(
      playlistKey: 'pl',
      segmentUrls: [origin.url('/seg0.m4s')],
      segmentPosition: 0,
      resolveHeaders: ({required bool forceRefresh}) async => const {},
    );

    final received = <int>[];
    final firstChunk = Completer<void>();
    final done = Completer<void>();
    final sub = seg0.body.listen(
      (bytes) {
        received.addAll(bytes);
        if (!firstChunk.isCompleted) firstChunk.complete();
      },
      onDone: done.complete,
    );
    addTearDown(sub.cancel);

    await halfSent.future.timeout(const Duration(seconds: 2));
    await firstChunk.future.timeout(const Duration(seconds: 2));
    expect(received, origin.segments['/seg0.m4s']!.sublist(0, 500));

    release.complete();
    await done.future.timeout(const Duration(seconds: 2));
    expect(received, origin.segments['/seg0.m4s']);
  });

  test('seeking beyond the current window cancels orphaned in-flight prefetches', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final seg1Accepted = Completer<void>();
    final seg1Closed = Completer<void>();
    final sockets = <Socket>[];
    addTearDown(() {
      for (final s in sockets) {
        s.destroy();
      }
    });
    server.listen((socket) {
      sockets.add(socket);
      socket.listen(
        (data) {
          final text = String.fromCharCodes(data);
          if (text.contains('/seg1.m4s')) {
            if (!seg1Accepted.isCompleted) seg1Accepted.complete();
          } else if (text.contains('/seg0.m4s') || text.contains('/seg4.m4s')) {
            final body = Uint8List.fromList([1, 2, 3, 4]);
            socket.write('HTTP/1.1 200 OK\r\nContent-Length: ${body.length}\r\nConnection: close\r\n\r\n');
            socket.add(body);
            unawaited(socket.close());
          }
        },
        onDone: () {
          socket.destroy();
          if (seg1Accepted.isCompleted && !seg1Closed.isCompleted) {
            seg1Closed.complete();
          }
        },
      );
    });

    final urls = [for (var i = 0; i < 6; i++) Uri.parse('http://127.0.0.1:${server.port}/seg$i.m4s')];
    final prefetcher = HlsSegmentPrefetcher(client, maxCacheBytes: 8192, defaultMaxConnections: 2);
    addTearDown(prefetcher.clear);

    final seg0 = await prefetcher.openSegment(
      playlistKey: 'seek',
      segmentUrls: urls,
      segmentPosition: 0,
      resolveHeaders: ({required bool forceRefresh}) async => const {},
    );
    expect(await readAll(seg0), [1, 2, 3, 4]);
    await seg1Accepted.future.timeout(const Duration(seconds: 2));

    // Seek to segment 4 (outside old window 0..2), so in-flight seg1 must abort.
    final seg4 = await prefetcher.openSegment(
      playlistKey: 'seek',
      segmentUrls: urls,
      segmentPosition: 4,
      resolveHeaders: ({required bool forceRefresh}) async => const {},
    );
    expect(await readAll(seg4), [1, 2, 3, 4]);
    await seg1Closed.future.timeout(const Duration(seconds: 2));
  });

  test('refreshes headers on 412/403 and backs off concurrency on 429', () async {
    origin.segments['/seg0.m4s'] = [1, 2, 3];
    origin.segments['/seg1.m4s'] = [4, 5, 6];
    origin.segments['/seg2.m4s'] = [7, 8, 9];
    origin.enforceAuth = true;
    origin.acceptedAuth = 'auth-2';

    var refreshes = 0;
    Future<Map<String, String>> resolveHeaders({required bool forceRefresh}) async {
      if (forceRefresh) refreshes++;
      return {HttpHeaders.cookieHeader: 'Video-Auth=${forceRefresh ? 'auth-2' : 'auth-1'}'};
    }

    final prefetcher = HlsSegmentPrefetcher(client, maxCacheBytes: 8192, defaultMaxConnections: 4);
    addTearDown(prefetcher.clear);

    final seg0 = await prefetcher.openSegment(
      playlistKey: 'auth',
      segmentUrls: [origin.url('/seg0.m4s'), origin.url('/seg1.m4s')],
      segmentPosition: 0,
      resolveHeaders: resolveHeaders,
    );
    expect(await readAll(seg0), [1, 2, 3]);
    expect(refreshes, 1);

    // 429 on seg2 surfaces rateLimited and halves dynamicMaxConnections (4 -> 2).
    origin.enforceAuth = false;
    origin.statusOnceByPath['/seg2.m4s'] = HttpStatus.tooManyRequests;
    await expectLater(
      prefetcher.openSegment(
        playlistKey: 'auth',
        segmentUrls: [origin.url('/seg0.m4s'), origin.url('/seg1.m4s'), origin.url('/seg2.m4s')],
        segmentPosition: 2,
        resolveHeaders: ({required bool forceRefresh}) async => const {},
      ),
      throwsA(isA<StorageException>().having((e) => e.kind, 'kind', StorageErrorKind.rateLimited)),
    );

    // Retry seg2 succeeds and caps concurrency at <= 2.
    origin.maxActive = 0;
    final urls = [
      for (var i = 0; i < 6; i++)
        origin.url('/s$i.m4s'),
    ];
    for (var i = 0; i < 6; i++) {
      origin.segments['/s$i.m4s'] = List<int>.filled(512, i);
    }
    origin.statusOnceByPath['/s0.m4s'] = HttpStatus.tooManyRequests;
    await expectLater(
      prefetcher.openSegment(
        playlistKey: 'rl',
        segmentUrls: urls,
        segmentPosition: 0,
        resolveHeaders: ({required bool forceRefresh}) async => const {},
      ),
      throwsA(isA<StorageException>().having((e) => e.kind, 'kind', StorageErrorKind.rateLimited)),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    origin.maxActive = 0;
    final okSeg = await prefetcher.openSegment(
      playlistKey: 'rl',
      segmentUrls: urls,
      segmentPosition: 0,
      resolveHeaders: ({required bool forceRefresh}) async => const {},
    );
    expect(await readAll(okSeg), origin.segments['/s0.m4s']);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(origin.maxActive, lessThanOrEqualTo(2));
  });

  test('enforces LRU cache cap and streams oversized segments without caching them', () async {
    for (var i = 0; i < 5; i++) {
      origin.segments['/seg$i.m4s'] = List<int>.filled(400, i + 1);
    }
    origin.segments['/huge.m4s'] = List<int>.generate(2500, (i) => i % 251);

    final prefetcher = HlsSegmentPrefetcher(
      client,
      maxCacheBytes: 1200,
      maxSingleSegmentCacheBytes: 800,
      defaultMaxConnections: 2,
    );
    addTearDown(prefetcher.clear);

    final urls = [for (var i = 0; i < 5; i++) origin.url('/seg$i.m4s')];
    for (var i = 0; i < 5; i++) {
      final seg = await prefetcher.openSegment(
        playlistKey: 'lru',
        segmentUrls: urls,
        segmentPosition: i,
        resolveHeaders: ({required bool forceRefresh}) async => const {},
      );
      expect(await readAll(seg), origin.segments['/seg$i.m4s']);
    }
    expect(prefetcher.cachedBytes, lessThanOrEqualTo(1200));

    final huge = await prefetcher.openSegment(
      playlistKey: 'huge',
      segmentUrls: [origin.url('/huge.m4s')],
      segmentPosition: 0,
      resolveHeaders: ({required bool forceRefresh}) async => const {},
    );
    expect(await readAll(huge), origin.segments['/huge.m4s']);
    expect(prefetcher.cachedBytes, lessThanOrEqualTo(1200));
  });
}
