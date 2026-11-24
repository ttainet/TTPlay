import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ttplay/focus/input_mode_tracker.dart';
import 'package:ttplay/iptv/iptv_channel_cache.dart';
import 'package:ttplay/iptv/iptv_models.dart';
import 'package:ttplay/iptv/iptv_provider.dart';
import 'package:ttplay/navigation/main_screen_scope.dart';
import 'package:ttplay/screens/iptv/iptv_screen.dart';

import '../test_helpers/theme.dart';

class _MemoryIptvChannelCache extends IptvChannelCache {
  _MemoryIptvChannelCache() : super.noop();

  final Map<String, IptvCachedPlaylist> entries = {};

  String _key(String scopeKey, String sourceId) => '$scopeKey\u0000$sourceId';

  @override
  Future<IptvCachedPlaylist?> read({
    required String scopeKey,
    required String sourceId,
    required String expectedFingerprint,
  }) async {
    final entry = entries[_key(scopeKey, sourceId)];
    if (entry == null) return null;
    if (entry.sourceId != sourceId || entry.fingerprint != expectedFingerprint) return null;
    return entry;
  }

  @override
  Future<void> write({required String scopeKey, required IptvCachedPlaylist entry}) async {
    entries[_key(scopeKey, entry.sourceId)] = entry;
  }

  @override
  Future<void> delete({required String scopeKey, required String sourceId}) async {
    entries.remove(_key(scopeKey, sourceId));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const initialM3u = '''
#EXTM3U x-tvg-url="https://epg.example.com/guide.xml"
#EXTINF:-1 tvg-id="c1" tvg-name="CCTV1" tvg-logo="https://img.example.com/c1.png" group-title="央视",CCTV1综合
#EXTVLCOPT:http-user-agent=StreamUA
#EXTVLCOPT:http-referrer=https://ref.example.com
https://live.example.com/cctv1-a.m3u8
#EXTINF:-1 tvg-id="c1" tvg-name="CCTV1" group-title="央视",CCTV1综合
https://live.example.com/cctv1-b.m3u8
#EXTINF:-1 group-title="卫视",湖南卫视
https://live.example.com/hunan.m3u8
''';

  const updatedM3u = '''
#EXTM3U x-tvg-url="https://epg.example.com/guide-v2.xml"
#EXTINF:-1 tvg-id="c1" tvg-name="CCTV1" group-title="央视",CCTV1综合
https://live.example.com/cctv1-a.m3u8
#EXTINF:-1 group-title="卫视",湖南卫视
https://live.example.com/hunan.m3u8
#EXTINF:-1 group-title="卫视",东方卫视
https://live.example.com/dragontv.m3u8
''';

  late Directory tempDir;
  late IptvChannelCache diskCache;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('iptv_channel_cache_test_');
    diskCache = IptvChannelCache(directoryProvider: () async => tempDir);
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('persists parsed playlist to disk and serves cached channels when cold-start network fails', () async {
    const src = IptvSource(
      id: 'local:home',
      name: 'Home TV',
      m3uUrl: 'http://10.0.10.48:1905/interface.m3u',
      userAgent: 'TestUA',
      referer: 'https://ref.local',
    );

    final writerProvider = IptvProvider(
      channelCache: diskCache,
      httpClientFactory: () => MockClient((req) async {
        if (req.url.path.endsWith('interface.m3u')) {
          return http.Response.bytes(utf8.encode(initialM3u), 200);
        }
        return http.Response('not found', 404);
      }),
    );
    addTearDown(writerProvider.dispose);

    await writerProvider.addLocalSource(src);
    await writerProvider.ensureLoaded(src);
    expect(writerProvider.channelsFor(src.id), hasLength(2));
    expect(writerProvider.isUsingDiskCache(src.id), isFalse);

    // Cold-start new provider under unreachable network.
    final offlineProvider = IptvProvider(
      channelCache: diskCache,
      httpClientFactory: () => MockClient((_) async => throw const SocketException('unreachable')),
    );
    addTearDown(offlineProvider.dispose);

    await offlineProvider.loadLocalSources();
    final cachedBeforeNetwork = offlineProvider.channelsFor(src.id);
    expect(cachedBeforeNetwork, hasLength(2));
    expect(offlineProvider.isUsingDiskCache(src.id), isTrue);
    expect(offlineProvider.cachedAtFor(src.id), isNotNull);
    expect(cachedBeforeNetwork.first.tvgId, 'c1');
    expect(cachedBeforeNetwork.first.tvgName, 'CCTV1');
    expect(cachedBeforeNetwork.first.logo, 'https://img.example.com/c1.png');
    expect(cachedBeforeNetwork.first.variants, hasLength(2));
    expect(cachedBeforeNetwork.first.variants.first.headers['User-Agent'], 'StreamUA');
    expect(cachedBeforeNetwork.first.variants.first.headers['Referer'], 'https://ref.example.com');

    // ensureLoaded tries network, fails, keeps disk-cached channels, and records error.
    await offlineProvider.ensureLoaded(src);
    expect(offlineProvider.channelsFor(src.id), hasLength(2));
    expect(offlineProvider.errorFor(src.id), isNotNull);
    expect(offlineProvider.isUsingDiskCache(src.id), isTrue);
  });

  test('updates disk cache once network recovers on later refresh', () async {
    const src = IptvSource(id: 'local:home', name: 'Home TV', m3uUrl: 'http://10.0.10.48:1905/interface.m3u');

    final writerProvider = IptvProvider(
      channelCache: diskCache,
      httpClientFactory: () => MockClient((req) async {
        if (req.url.path.endsWith('interface.m3u')) {
          return http.Response.bytes(utf8.encode(initialM3u), 200);
        }
        return http.Response('not found', 404);
      }),
    );
    addTearDown(writerProvider.dispose);
    await writerProvider.addLocalSource(src);
    await writerProvider.ensureLoaded(src);

    var networkRecovered = false;
    final secondProvider = IptvProvider(
      channelCache: diskCache,
      httpClientFactory: () => MockClient((req) async {
        if (!networkRecovered) {
          return http.Response('bad gateway', 502);
        }
        if (req.url.path.endsWith('interface.m3u')) {
          return http.Response.bytes(utf8.encode(updatedM3u), 200);
        }
        return http.Response('not found', 404);
      }),
    );
    addTearDown(secondProvider.dispose);
    await secondProvider.loadLocalSources();
    await secondProvider.ensureLoaded(src);
    expect(secondProvider.channelsFor(src.id), hasLength(2));
    expect(secondProvider.isUsingDiskCache(src.id), isTrue);

    networkRecovered = true;
    await secondProvider.ensureLoaded(src, forceRefresh: true);
    expect(secondProvider.errorFor(src.id), isNull);
    expect(secondProvider.isUsingDiskCache(src.id), isFalse);
    expect(secondProvider.channelsFor(src.id).map((c) => c.name), contains('东方卫视'));

    // Third cold-start sees the updated disk snapshot immediately.
    final thirdProvider = IptvProvider(
      channelCache: diskCache,
      httpClientFactory: () => MockClient((_) async => http.Response('timeout', 504)),
    );
    addTearDown(thirdProvider.dispose);
    await thirdProvider.loadLocalSources();
    expect(thirdProvider.channelsFor(src.id).map((c) => c.name), contains('东方卫视'));
  });

  test('invalidates disk cache when source URL or request headers change', () async {
    const src = IptvSource(
      id: 'local:home',
      name: 'Home TV',
      m3uUrl: 'http://10.0.10.48:1905/v1.m3u',
      userAgent: 'UA1',
    );
    final provider = IptvProvider(
      channelCache: diskCache,
      httpClientFactory: () => MockClient((req) async {
        if (req.url.path.endsWith('v1.m3u')) {
          return http.Response.bytes(utf8.encode(initialM3u), 200);
        }
        return http.Response('not found', 404);
      }),
    );
    addTearDown(provider.dispose);
    await provider.addLocalSource(src);
    await provider.ensureLoaded(src);

    final changedHeaderRead = await diskCache.read(
      scopeKey: 'offline',
      sourceId: src.id,
      expectedFingerprint: IptvChannelCache.buildFingerprint(src.copyWith(userAgent: 'UA2')),
    );
    expect(changedHeaderRead, isNull);

    await provider.updateLocalSource(src.copyWith(m3uUrl: 'http://10.0.10.48:1905/v2.m3u'));
    final staleReadAfterEdit = await diskCache.read(
      scopeKey: 'offline',
      sourceId: src.id,
      expectedFingerprint: IptvChannelCache.buildFingerprint(src),
    );
    expect(staleReadAfterEdit, isNull);
  });

  test('isolates disk caches across offline and self-hosted accounts without wiping on logout', () async {
    const acctASource = IptvSource(
      id: 'cloud:c1',
      name: 'TV',
      m3uUrl: 'http://10.0.10.48:1905/interface.m3u',
      isCloud: true,
      cloudSourceId: 'c1',
    );
    const acctBSource = IptvSource(
      id: 'cloud:c1',
      name: 'TV B',
      m3uUrl: 'http://10.0.10.48:1905/b.m3u',
      isCloud: true,
      cloudSourceId: 'c1',
    );

    final writer = IptvProvider(
      channelCache: diskCache,
      httpClientFactory: () => MockClient((req) async {
        if (req.url.path.endsWith('interface.m3u')) {
          return http.Response.bytes(utf8.encode(initialM3u), 200);
        }
        return http.Response.bytes(utf8.encode(updatedM3u), 200);
      }),
    );
    addTearDown(writer.dispose);

    await writer.setSessionScope(isSelfHosted: true, accountScopeKey: 'acct_a');
    writer.setCloudSources([acctASource]);
    await writer.ensureLoaded(acctASource);
    expect(writer.channelsFor('cloud:c1'), hasLength(2));

    await writer.setSessionScope(isSelfHosted: true, accountScopeKey: 'acct_b');
    writer.setCloudSources([acctBSource]);
    await writer.ensureLoaded(acctBSource);
    expect(writer.channelsFor('cloud:c1'), hasLength(3));

    // Simulate logout & new session under unreachable M3U network.
    final reader = IptvProvider(
      channelCache: diskCache,
      httpClientFactory: () => MockClient((_) async => throw const SocketException('offline')),
    );
    addTearDown(reader.dispose);

    await reader.setSessionScope(isSelfHosted: true, accountScopeKey: 'acct_a');
    reader.setCloudSources([acctASource]);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(reader.channelsFor('cloud:c1'), hasLength(2));

    // Logout clears cloud in-memory sources without erasing disk cache.
    reader.setCloudSources(const []);
    await reader.setSessionScope(isSelfHosted: false);
    expect(reader.channelsFor('cloud:c1'), isEmpty);

    // Signing back into acct_a still has disk cache intact; acct_b keeps its own cache.
    await reader.setSessionScope(isSelfHosted: true, accountScopeKey: 'acct_a');
    reader.setCloudSources([acctASource]);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(reader.channelsFor('cloud:c1'), hasLength(2));

    await reader.setSessionScope(isSelfHosted: true, accountScopeKey: 'acct_b');
    reader.setCloudSources([acctBSource]);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(reader.channelsFor('cloud:c1'), hasLength(3));

    // Clearing cloud disk cache deletes only the active scope's entry.
    await reader.clearSourceDiskCache('cloud:c1');
    final bRead = await diskCache.read(
      scopeKey: 'cloud:acct_b',
      sourceId: 'cloud:c1',
      expectedFingerprint: IptvChannelCache.buildFingerprint(acctBSource),
    );
    final aRead = await diskCache.read(
      scopeKey: 'cloud:acct_a',
      sourceId: 'cloud:c1',
      expectedFingerprint: IptvChannelCache.buildFingerprint(acctASource),
    );
    expect(bRead, isNull);
    expect(aRead, isNotNull);
  });

  test('removes disk cache file when local source is deleted', () async {
    const src = IptvSource(id: 'local:del', name: 'Delete Me', m3uUrl: 'http://10.0.10.48:1905/del.m3u');
    final provider = IptvProvider(
      channelCache: diskCache,
      httpClientFactory: () => MockClient((req) async {
        if (req.url.path.endsWith('del.m3u')) {
          return http.Response.bytes(utf8.encode(initialM3u), 200);
        }
        return http.Response('not found', 404);
      }),
    );
    addTearDown(provider.dispose);

    await provider.addLocalSource(src);
    await provider.ensureLoaded(src);
    final cacheDir = Directory('${tempDir.path}${Platform.pathSeparator}iptv_cache');
    expect(cacheDir.listSync().whereType<File>(), hasLength(1));

    await provider.removeLocalSource(src.id);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(cacheDir.listSync().whereType<File>(), isEmpty);
  });

  testWidgets('IptvScreen shows disk-cached channels immediately when M3U fails and updates on retry', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    const src = IptvSource(
      id: 'cloud:c1',
      name: 'TV',
      m3uUrl: 'http://10.0.10.48:1905/interface.m3u',
      isCloud: true,
      cloudSourceId: 'c1',
    );
    final memoryCache = _MemoryIptvChannelCache();
    await memoryCache.write(
      scopeKey: 'cloud:acct_1',
      entry: IptvCachedPlaylist(
        sourceId: src.id,
        fingerprint: IptvChannelCache.buildFingerprint(src),
        cachedAt: DateTime(2026, 11, 24, 14, 30),
        channels: const [
          IptvChannel(
            id: 'ch1',
            sourceId: 'cloud:c1',
            name: 'CCTV1综合',
            group: '央视',
            variants: [IptvStreamVariant(url: 'https://live.example.com/c1.m3u8', sourceId: 'cloud:c1')],
          ),
        ],
      ),
    );

    var shouldFail = true;
    final provider = IptvProvider(
      channelCache: memoryCache,
      httpClientFactory: () => MockClient((req) async {
        if (shouldFail) {
          return http.Response('gateway timeout', 504);
        }
        if (req.url.path.endsWith('interface.m3u')) {
          return http.Response.bytes(utf8.encode(updatedM3u), 200);
        }
        return http.Response('not found', 404);
      }),
    );

    try {
      await provider.setSessionScope(isSelfHosted: true, accountScopeKey: 'acct_1');
      provider.setCloudSources([src]);
      await tester.pumpWidget(
        InputModeTracker(
          child: ChangeNotifierProvider<IptvProvider>.value(
            value: provider,
            child: MaterialApp(
              theme: ThemeData(extensions: const [testMonoTokens]),
              home: MainScreenFocusScope(
                focusSidebar: () {},
                sideNavigationWidth: 200,
                child: const IptvScreen(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Cached channels render even though network failed, with non-blocking offline notice.
      expect(find.text('CCTV1综合'), findsOneWidget);
      expect(find.text('订阅刷新失败，当前显示本地缓存（11-24 14:30）'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);

      // Recover network and tap retry.
      shouldFail = false;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();

      expect(find.text('东方卫视'), findsOneWidget);
      expect(find.text('重试'), findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      provider.dispose();
    }
  });
}
