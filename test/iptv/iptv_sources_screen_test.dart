import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ttplay/database/app_database.dart';
import 'package:ttplay/focus/input_mode_tracker.dart';
import 'package:ttplay/iptv/iptv_models.dart';
import 'package:ttplay/iptv/iptv_provider.dart';
import 'package:ttplay/library/library_repository.dart';
import 'package:ttplay/library/local_library_client.dart';
import 'package:ttplay/library_cloud/cloud_keyring.dart';
import 'package:ttplay/screens/iptv/iptv_sources_screen.dart';
import 'package:ttplay/services/credential_vault.dart';
import 'package:ttplay/services/multi_server_manager.dart';
import 'package:ttplay/session/app_session_controller.dart';
import 'package:ttplay/session/app_session_models.dart';
import 'package:ttplay/storage/mount_manager.dart';
import 'package:ttplay/storage/mount_registry.dart';
import 'package:ttplay/ttplay/ttplay_session_binder.dart';
import 'package:ttplay/utils/platform_detector.dart';

import '../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  const sampleM3u = '''
#EXTM3U
#EXTINF:-1 group-title="央视",CCTV1综合
https://live.example.com/cctv1.m3u8
''';

  const updatedM3u = '''
#EXTM3U
#EXTINF:-1 group-title="央视",CCTV1综合
https://live.example.com/cctv1.m3u8
#EXTINF:-1 group-title="卫视",湖南卫视
https://live.example.com/hunan.m3u8
''';

  setUp(() {
    resetSharedPreferencesForTest();
    CredentialVault.resetKeyForTesting();
    TvDetectionService.debugSetAppleTVOverride(false);
    TvDetectionService.setForceTVSync(false);
  });

  tearDown(() {
    TvDetectionService.debugSetAppleTVOverride(null);
    TvDetectionService.setForceTVSync(false);
  });

  test('IptvProvider isolates sources and favorites strictly by session mode and account', () async {
    final provider = IptvProvider();
    addTearDown(provider.dispose);

    const localSrc = IptvSource(id: 'local:1', name: 'Local IPTV', m3uUrl: 'http://127.0.0.1:1001/a.m3u');
    const cloudSrc = IptvSource(
      id: 'cloud:c1',
      name: 'Cloud IPTV',
      m3uUrl: 'http://10.0.0.1:1001/c.m3u',
      isCloud: true,
      cloudSourceId: 'c1',
    );
    await provider.addLocalSource(localSrc);
    provider.setCloudSources([cloudSrc]);

    const chLocal = IptvChannel(
      id: 'ch_l',
      sourceId: 'local:1',
      name: 'CCTV1',
      group: '央视',
      variants: [IptvStreamVariant(url: 'https://live.example.com/1.m3u8', sourceId: 'local:1')],
    );
    const chCloud = IptvChannel(
      id: 'ch_c',
      sourceId: 'cloud:c1',
      name: 'CCTV5',
      group: '体育',
      variants: [IptvStreamVariant(url: 'https://live.example.com/5.m3u8', sourceId: 'cloud:c1')],
    );

    // Offline scope: sees only local sources & stores offline favorites.
    expect(provider.isCloudMode, isFalse);
    expect(provider.sources.map((s) => s.id), ['local:1']);
    await provider.toggleFavorite(chLocal);
    expect(provider.isFavorite(chLocal), isTrue);

    // Switch to Self-Hosted account A: local source and offline favorites are hidden.
    await provider.setSessionScope(isSelfHosted: true, accountScopeKey: 'acct_a');
    expect(provider.isCloudMode, isTrue);
    expect(provider.sources.map((s) => s.id), ['cloud:c1']);
    expect(provider.isFavorite(chLocal), isFalse);
    await provider.toggleFavorite(chCloud);
    expect(provider.isFavorite(chCloud), isTrue);

    // Switch to Self-Hosted account B: account A's favorites are isolated.
    await provider.setSessionScope(isSelfHosted: true, accountScopeKey: 'acct_b');
    expect(provider.isFavorite(chCloud), isFalse);

    // Back to Offline: local source and offline favorite return unchanged.
    await provider.setSessionScope(isSelfHosted: false);
    expect(provider.sources.map((s) => s.id), ['local:1']);
    expect(provider.isFavorite(chLocal), isTrue);
    expect(provider.isFavorite(chCloud), isFalse);
  });

  testWidgets('Sync mode IptvSourcesScreen manages cloud IPTV directly without local empty card', (tester) async {
    final hk = CloudKeyring.generateMasterKey();
    final storedSources = <Map<String, dynamic>>[];
    final storedCreds = <String, ({String cipher, int version})>{};
    var nextId = 1;

    // Seed initial cloud IPTV source on server.
    final initialCipher = await CloudKeyring.encryptCredentialJson(
      masterKey: hk,
      payload: {'m3u_url': 'http://10.0.10.48:1905/interface.m3u', 'epg_url': 'http://10.0.10.48:1905/playback.xml'},
    );
    storedSources.add({
      'id': 'src_0',
      'kind': 'iptv',
      'name': 'TV',
      'identity_key': 'iptv:init',
      'status': 'active',
    });
    storedCreds['src_0'] = (cipher: initialCipher, version: 1);

    http.Response jsonResponse(Object data, [int status = 200]) => http.Response.bytes(
      utf8.encode(jsonEncode(data)),
      status,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );

    final mockCloudClient = MockClient((req) async {
      final path = req.url.path;
      if (req.method == 'GET' && path == '/api/v1/sources') {
        return jsonResponse({'code': 0, 'sources': storedSources});
      } else if (req.method == 'POST' && path == '/api/v1/sources') {
        final reqJson = jsonDecode(req.body) as Map<String, dynamic>;
        final id = 'src_${nextId++}';
        final src = {
          'id': id,
          'kind': reqJson['kind'],
          'name': reqJson['name'],
          'identity_key': reqJson['identity_key'],
          'status': 'active',
        };
        storedSources.add(src);
        storedCreds[id] = (cipher: reqJson['ciphertext'] as String, version: 1);
        return jsonResponse({'code': 0, 'source': src});
      } else if (req.method == 'PATCH' && path.startsWith('/api/v1/sources/')) {
        final id = path.split('/')[4];
        final reqJson = jsonDecode(req.body) as Map<String, dynamic>;
        for (var i = 0; i < storedSources.length; i++) {
          if (storedSources[i]['id'] == id) {
            storedSources[i] = {...storedSources[i], 'name': reqJson['name']};
            return jsonResponse({'code': 0, 'source': storedSources[i]});
          }
        }
        return jsonResponse({'code': 404, 'error': 'not found'}, 404);
      } else if (req.method == 'GET' && path.endsWith('/credential')) {
        final id = path.split('/')[4];
        final cred = storedCreds[id]!;
        return jsonResponse({
          'code': 0,
          'credential': {
            'source_id': id,
            'ciphertext': cred.cipher,
            'version': cred.version,
            'key_epoch': 1,
            'status': 'valid',
          },
        });
      } else if (req.method == 'PUT' && path.endsWith('/credential')) {
        final id = path.split('/')[4];
        final reqJson = jsonDecode(req.body) as Map<String, dynamic>;
        final nextVer = (storedCreds[id]?.version ?? 0) + 1;
        storedCreds[id] = (cipher: reqJson['ciphertext'] as String, version: nextVer);
        return jsonResponse({
          'code': 0,
          'credential': {'source_id': id, 'version': nextVer, 'key_epoch': 1, 'status': 'valid'},
        });
      } else if (req.method == 'DELETE' && path.startsWith('/api/v1/sources/')) {
        final id = path.split('/')[4];
        storedSources.removeWhere((s) => s['id'] == id);
        storedCreds.remove(id);
        return jsonResponse({'code': 0});
      } else if (req.method == 'GET' && path == '/api/v1/library/snapshot') {
        return jsonResponse({
          'code': 0,
          'snapshot_seq': 1,
          'total': 0,
          'page': 1,
          'page_size': 100,
          'has_more': false,
          'items': const [],
        });
      } else if (req.method == 'GET' && (path == '/api/v1/progress' || path == '/api/v1/favorites')) {
        return jsonResponse({'code': 0, 'items': const []});
      } else if (req.method == 'GET' && path == '/api/v1/user/unmatched') {
        return jsonResponse({'code': 0, 'items': const []});
      }
      return jsonResponse({'code': 404, 'error': 'not found'}, 404);
    });

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final repo = LibraryRepository(db);
    final mounts = MountManager(MountRegistry(db));
    final localClient = LocalLibraryClient(repository: repo, mounts: mounts);
    final serverManager = MultiServerManager();
    final sessionController = AppSessionController(db: db, mountManager: mounts);
    final session = SelfHostedSession(
      serverUrl: 'http://127.0.0.1:20001',
      username: 'alice',
      accessToken: 'tok',
      householdId: 'hh1',
      memberId: 'm1',
      masterKeyB64: base64Encode(hk),
    );
    sessionController.debugSetStateForTesting(mode: AppLoginMode.selfHosted, selfHostedSession: session);

    var useUpdatedPlaylist = false;
    final iptvProvider = IptvProvider(
      httpClientFactory: () => MockClient((request) async {
        final body = useUpdatedPlaylist ? updatedM3u : sampleM3u;
        return http.Response.bytes(utf8.encode(body), 200);
      }),
    );
    final binder = TtplaySessionBinder(
      sessionController: sessionController,
      serverManager: serverManager,
      localLibraryClient: localClient,
      isTv: () => false,
      httpClientFactory: () => mockCloudClient,
    );
    binder.attachIptvProvider(iptvProvider);
    try {
      await binder.syncFromSession(refreshExternalServers: true, awaitCloudSync: true);
      binder.cloudProjectionEngine?.stopListeningEvents();

      await tester.pumpWidget(
        InputModeTracker(
          child: MultiProvider(
            providers: [
              ChangeNotifierProvider<AppSessionController>.value(value: sessionController),
              ChangeNotifierProvider<TtplaySessionBinder>.value(value: binder),
              ChangeNotifierProvider<IptvProvider>.value(value: iptvProvider),
            ],
            child: const MaterialApp(home: IptvSourcesScreen()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Existing cloud source is shown without any "尚未添加本地 IPTV 订阅" card or local section.
      expect(find.text('TV'), findsOneWidget);
      expect(find.text('云端同步'), findsOneWidget);
      expect(find.text('尚未添加本地 IPTV 订阅'), findsNothing);
      expect(find.text('添加第一个 IPTV 源'), findsNothing);
      expect(find.text('本地直播源'), findsNothing);

      // Add a second cloud IPTV source directly from IptvSourcesScreen.
      await tester.tap(find.byTooltip('添加 IPTV 源'));
      await tester.pumpAndSettle();
      expect(find.text('添加云端 IPTV 源'), findsOneWidget);

      await tester.enterText(find.widgetWithText(TextFormField, '显示名称（可选）'), '卧室直播');
      await tester.enterText(find.widgetWithText(TextFormField, 'M3U / TXT 订阅地址 *'), 'http://10.0.10.48:1905/room.m3u');
      await tester.tap(find.text('校验并保存'));
      await tester.pumpAndSettle();

      expect(find.text('卧室直播'), findsOneWidget);
      expect(storedSources, hasLength(2));

      // Edit the newly created cloud IPTV source.
      useUpdatedPlaylist = true;
      await tester.tap(find.byTooltip('编辑').last);
      await tester.pumpAndSettle();
      expect(find.text('编辑云端 IPTV 源'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextFormField, '显示名称（可选）'), '客厅直播');
      await tester.tap(find.text('校验并保存'));
      await tester.pumpAndSettle();
      expect(find.text('客厅直播'), findsOneWidget);
      expect(find.text('卧室直播'), findsNothing);

      // Delete the cloud source and confirm it is removed from server & provider.
      await tester.tap(find.byTooltip('删除').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();
      expect(find.text('客厅直播'), findsNothing);
      expect(storedSources, hasLength(1));
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      binder.dispose();
      iptvProvider.dispose();
      serverManager.dispose();
      sessionController.dispose();
      await tester.runAsync(() async {
        await mounts.dispose();
        await db.close();
      });
    }
  });

  testWidgets('Sync mode on TV shows read-only cloud list with footer hint and no local empty state', (tester) async {
    SharedPreferences.setMockInitialValues({});
    TvDetectionService.setForceTVSync(true);

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final mounts = MountManager(MountRegistry(db));
    final sessionController = AppSessionController(db: db, mountManager: mounts);
    final session = SelfHostedSession(
      serverUrl: 'http://127.0.0.1:20001',
      username: 'alice',
      accessToken: 'tok',
      householdId: 'hh1',
      memberId: 'm1',
    );
    sessionController.debugSetStateForTesting(mode: AppLoginMode.selfHosted, selfHostedSession: session);

    final iptvProvider = IptvProvider();
    try {
      await iptvProvider.setSessionScope(isSelfHosted: true, accountScopeKey: 'acct');
      iptvProvider.setCloudSources(const [
        IptvSource(
          id: 'cloud:c1',
          name: 'TV',
          m3uUrl: 'http://10.0.10.48:1905/interface.m3u',
          epgUrl: 'http://10.0.10.48:1905/playback.xml',
          isCloud: true,
          cloudSourceId: 'c1',
        ),
      ]);

      await tester.pumpWidget(
        InputModeTracker(
          child: MultiProvider(
            providers: [
              ChangeNotifierProvider<AppSessionController>.value(value: sessionController),
              ChangeNotifierProvider<IptvProvider>.value(value: iptvProvider),
            ],
            child: const MaterialApp(home: IptvSourcesScreen()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('TV'), findsOneWidget);
      expect(find.text('尚未添加本地 IPTV 订阅'), findsNothing);
      expect(find.text('添加第一个 IPTV 源'), findsNothing);
      expect(find.byTooltip('添加 IPTV 源'), findsNothing);
      expect(find.byTooltip('编辑'), findsNothing);
      expect(find.byTooltip('删除'), findsNothing);
      expect(find.byTooltip('刷新频道列表'), findsOneWidget);
      expect(find.text('直播源由同步服务器管理，请在手机或电脑端添加或编辑。'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      iptvProvider.dispose();
      sessionController.dispose();
      await tester.runAsync(() async {
        await mounts.dispose();
        await db.close();
      });
    }
  });

  testWidgets('Offline mode IptvSourcesScreen manages single local list without cloud split', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final mounts = MountManager(MountRegistry(db));
    final sessionController = AppSessionController(db: db, mountManager: mounts);
    sessionController.debugSetStateForTesting(mode: AppLoginMode.offline);

    final iptvProvider = IptvProvider(
      httpClientFactory: () => MockClient((_) async => http.Response.bytes(utf8.encode(sampleM3u), 200)),
    );

    try {
      await tester.pumpWidget(
        InputModeTracker(
          child: MultiProvider(
            providers: [
              ChangeNotifierProvider<AppSessionController>.value(value: sessionController),
              ChangeNotifierProvider<IptvProvider>.value(value: iptvProvider),
            ],
            child: const MaterialApp(home: IptvSourcesScreen()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('云端同步直播源'), findsNothing);
      expect(find.text('本地直播源'), findsNothing);
      expect(find.text('尚未添加 IPTV 订阅'), findsOneWidget);
      expect(find.text('添加第一个 IPTV 源'), findsOneWidget);

      await tester.tap(find.text('添加第一个 IPTV 源'));
      await tester.pumpAndSettle();
      expect(find.text('添加 IPTV 源'), findsOneWidget);

      await tester.enterText(find.widgetWithText(TextFormField, '显示名称（可选）'), '本地测试源');
      await tester.enterText(find.widgetWithText(TextFormField, 'M3U / TXT 订阅地址 *'), 'http://127.0.0.1:1905/local.m3u');
      await tester.tap(find.text('校验并保存'));
      await tester.pumpAndSettle();

      expect(find.text('本地测试源'), findsOneWidget);
      expect(find.text('尚未添加 IPTV 订阅'), findsNothing);
      expect(iptvProvider.localSources, hasLength(1));
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      iptvProvider.dispose();
      sessionController.dispose();
      await tester.runAsync(() async {
        await mounts.dispose();
        await db.close();
      });
    }
  });
}
