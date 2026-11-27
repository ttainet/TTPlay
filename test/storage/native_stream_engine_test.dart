import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ttplay/storage/direct_url_source.dart';
import 'package:ttplay/storage/http_range_reader.dart';
import 'package:ttplay/storage/native_stream_engine.dart';
import 'package:ttplay/storage/storage_driver.dart';
import 'package:ttplay/storage/storage_mount.dart';
import 'package:ttplay/storage/stream_proxy.dart';

class _DirectOrigin {
  _DirectOrigin(this.content);

  final Uint8List content;
  late HttpServer _redirectServer;
  late HttpServer _cdnServer;
  int redirectHits = 0;
  bool staleOnce = true;

  Uri get entryUri => Uri.parse('http://127.0.0.1:${_redirectServer.port}/entry');
  Uri get freshUri => Uri.parse('http://127.0.0.1:${_redirectServer.port}/fresh');

  Future<void> start() async {
    _cdnServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _cdnServer.listen((request) async {
      final response = request.response;
      try {
        if (request.uri.path == '/stale') {
          response.statusCode = HttpStatus.preconditionFailed;
          return;
        }
        final range = request.headers.value(HttpHeaders.rangeHeader);
        final match = range == null ? null : RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
        if (match == null) {
          response.contentLength = content.length;
          response.add(content);
          return;
        }
        final start = int.parse(match[1]!);
        final end = match[2]!.isEmpty ? content.length - 1 : int.parse(match[2]!);
        final slice = content.sublist(start, end + 1);
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/${content.length}');
        response.contentLength = slice.length;
        response.add(slice);
      } finally {
        await response.close();
      }
    });

    _redirectServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _redirectServer.listen((request) async {
      redirectHits++;
      final targetPath = request.uri.path == '/fresh'
          ? '/video'
          : staleOnce
          ? '/stale'
          : '/video';
      if (targetPath == '/stale') staleOnce = false;
      await request.response.redirect(Uri.parse('http://localhost:${_cdnServer.port}$targetPath'));
    });
  }

  Future<void> stop() async {
    await _redirectServer.close(force: true);
    await _cdnServer.close(force: true);
  }
}

class _DirectDrive implements StorageDriver, DirectUrlReadSource {
  _DirectDrive(this.origin);

  final _DirectOrigin origin;
  int resolveCalls = 0;
  int refreshCalls = 0;

  @override
  StorageKind get kind => StorageKind.quark;

  @override
  bool get nativeStreamEnabled => true;

  @override
  Future<DirectPlaybackSource> resolveDirectPlayback(StorageEntry entry, {bool forceRefresh = false}) async {
    resolveCalls++;
    if (forceRefresh) refreshCalls++;
    return DirectPlaybackSource(
      link: StorageLink(forceRefresh ? origin.freshUri : origin.entryUri, headers: const {'Cookie': 'secret=1'}),
      totalSize: origin.content.length,
      profile: const DriveTransferProfile(
        minConnections: 2,
        maxConnections: 3,
        windowBytes: 1536 * 1024,
        minSegmentBytes: 256 * 1024,
        maxSegmentBytes: 512 * 1024,
        probeBypassBytes: 64 * 1024,
        redirectCacheTtlSecs: 60,
      ),
    );
  }

  @override
  Future<void> check() async {}

  @override
  Future<void> close() async {}

  @override
  Future<List<StorageEntry>> list(String path, {StorageEntry? parent}) async => const [];

  @override
  Stream<List<int>> openRead(StorageEntry entry, {int start = 0, int? end}) =>
      throw UnimplementedError('DirectUrlReadSource handles playback reads natively');

  @override
  Future<StorageEntry> stat(String path) async =>
      StorageEntry(path: path, name: 'movie.mkv', isDirectory: false, size: origin.content.length);
}

class _FailingDirectDrive implements StorageDriver, DirectUrlReadSource {
  bool openReadCalled = false;

  @override
  StorageKind get kind => StorageKind.quark;

  @override
  bool get nativeStreamEnabled => true;

  @override
  Future<DirectPlaybackSource> resolveDirectPlayback(StorageEntry entry, {bool forceRefresh = false}) {
    return Future.error(const StorageException(StorageErrorKind.unauthorized, 'expired'));
  }

  @override
  Future<void> check() async {}

  @override
  Future<void> close() async {}

  @override
  Future<List<StorageEntry>> list(String path, {StorageEntry? parent}) async => const [];

  @override
  Stream<List<int>> openRead(StorageEntry entry, {int start = 0, int? end}) {
    openReadCalled = true;
    throw StateError('openRead must not be called as fallback');
  }

  @override
  Future<StorageEntry> stat(String path) async =>
      StorageEntry(path: path, name: 'broken.mkv', isDirectory: false, size: 2 * 1024 * 1024);
}

void main() {
  final windowsDll = File('native/ttplay_stream/target/release/ttplay_stream.dll');

  test(
    'StreamProxy routes DirectUrlReadSource through NativeStreamEngine, refreshes 412 via FFI, and caches 302',
    () async {
      final origin = _DirectOrigin(Uint8List.fromList(List<int>.generate(2 * 1024 * 1024, (i) => (i * 17 + 3) % 251)));
      await origin.start();
      addTearDown(origin.stop);

      final engine = NativeStreamEngine.create(libraryPathOverride: windowsDll.absolute.path);
      final proxy = StreamProxy(nativeEngine: engine);
      addTearDown(proxy.stop);

      final drive = _DirectDrive(origin);
      final entry = StorageEntry(
        path: '/movie.mkv',
        name: 'movie.mkv',
        isDirectory: false,
        size: origin.content.length,
      );
      final url = await proxy.register(mountId: 'm1', driver: drive, entry: entry);
      expect(url.port, engine.port);

      final client = HttpClient();
      addTearDown(() => client.close(force: true));

      final req1 = await client.getUrl(url);
      final resp1 = await req1.close();
      expect(resp1.statusCode, HttpStatus.ok);
      final body = await resp1.expand((c) => c).toList();
      expect(body, origin.content);
      expect(drive.resolveCalls, 2);
      expect(drive.refreshCalls, 1);

      final hitsAfterFirst = origin.redirectHits;
      // Second bounded read should hit the cached CDN URL without hitting redirectServer again.
      final req2 = await client.getUrl(url);
      req2.headers.set(HttpHeaders.rangeHeader, 'bytes=0-131071');
      final resp2 = await req2.close();
      expect(resp2.statusCode, HttpStatus.partialContent);
      final slice = await resp2.expand((c) => c).toList();
      expect(slice, origin.content.sublist(0, 131072));
      expect(origin.redirectHits, hitsAfterFirst);

      final stats = engine.pollStats();
      expect(stats, hasLength(1));
      expect((stats.single['upstream_bytes'] as num).toInt(), greaterThan(0));
      expect((stats.single['delivered_bytes'] as num).toInt(), greaterThan(0));
    },
    skip: !(Platform.isWindows && windowsDll.existsSync()) ? 'Native Windows DLL not built' : false,
  );

  test('StreamProxy updates native playback demand and deferred maxConnections via FFI', () async {
    final origin = _DirectOrigin(Uint8List.fromList(List<int>.generate(2 * 1024 * 1024, (i) => (i * 19 + 5) % 251)));
    await origin.start();
    addTearDown(origin.stop);

    final engine = NativeStreamEngine.create(libraryPathOverride: windowsDll.absolute.path);
    final proxy = StreamProxy(nativeEngine: engine);
    addTearDown(proxy.stop);

    final drive = _DeferredTierDrive(origin);
    final entry = StorageEntry(
      path: '/demand.mkv',
      name: 'demand.mkv',
      isDirectory: false,
      size: origin.content.length,
    );
    final url = await proxy.register(mountId: 'm2', driver: drive, entry: entry);
    expect(proxy.isNativeStreamUrl(url.toString()), isTrue);
    expect(proxy.isNativeStreamUrl('http://127.0.0.1:${engine.port}/v/other/a.mp4'), isFalse);

    // Give background deferred tier resolution a moment to apply max_connections=4.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // Push playbackStarted=true with bitrate=0 + durationMs=1000 -> fallback bitrate = totalSize * 8 bps.
    proxy.updateNativePlaybackDemand(
      url: url.toString(),
      playbackStarted: true,
      bitrateBps: 0,
      bufferedSecs: 12.0,
      isBuffering: false,
      durationMs: 1000,
    );

    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final req = await client.getUrl(url);
    final resp = await req.close();
    expect(resp.statusCode, HttpStatus.ok);
    final body = await resp.expand((c) => c).toList();
    expect(body, origin.content);

    final peek = proxy.peekNativeStreamStatus(url.toString());
    expect(peek, isNotNull);
    expect(peek!.maxConns, 4);

    final stats = engine.pollStats();
    expect(stats, hasLength(1));
    expect((stats.single['upstream_bytes'] as num).toInt(), greaterThan(0));
    expect(stats.single['playback_started'], isTrue);
    expect((stats.single['demand_bitrate_bps'] as num).toInt(), origin.content.length * 8);
    expect((stats.single['effective_max_conns'] as num).toInt(), 4);
  }, skip: !(Platform.isWindows && windowsDll.existsSync()) ? 'Native Windows DLL not built' : false);

  test('NativeStreamEngine.create throws StateError when native library cannot be loaded', () {
    expect(
      () => NativeStreamEngine.create(libraryPathOverride: 'Z:/nonexistent/ttplay_stream_missing.dll'),
      throwsA(isA<StateError>()),
    );
  });

  test('StreamProxy.register throws instead of falling back when DirectUrlReadSource resolution fails', () async {
    final proxy = StreamProxy();
    addTearDown(proxy.stop);

    final drive = _FailingDirectDrive();
    const entry = StorageEntry(path: '/broken.mkv', name: 'broken.mkv', isDirectory: false, size: 2 * 1024 * 1024);
    await expectLater(
      proxy.register(mountId: 'm-fail', driver: drive, entry: entry),
      throwsA(isA<StorageException>().having((e) => e.kind, 'kind', StorageErrorKind.unauthorized)),
    );
    expect(drive.openReadCalled, isFalse);
  });
}

class _DeferredTierDrive extends _DirectDrive {
  _DeferredTierDrive(super.origin);

  @override
  Future<DirectPlaybackSource> resolveDirectPlayback(StorageEntry entry, {bool forceRefresh = false}) async {
    resolveCalls++;
    if (forceRefresh) refreshCalls++;
    return DirectPlaybackSource(
      link: StorageLink(origin.freshUri),
      totalSize: origin.content.length,
      profile: const DriveTransferProfile(
        minConnections: 1,
        maxConnections: 1,
        windowBytes: 1536 * 1024,
        minSegmentBytes: 256 * 1024,
        maxSegmentBytes: 512 * 1024,
        probeBypassBytes: 64 * 1024,
        allowRuntimeMaxUpgrade: true,
      ),
      resolveDeferredMaxConnections: () async => 4,
    );
  }
}
