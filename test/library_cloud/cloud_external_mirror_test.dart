import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ttplay/connection/connection.dart';
import 'package:ttplay/database/app_database.dart';
import 'package:ttplay/iptv/iptv_channel_cache.dart';
import 'package:ttplay/iptv/iptv_models.dart';
import 'package:ttplay/iptv/iptv_provider.dart';
import 'package:ttplay/library/library_repository.dart';
import 'package:ttplay/library/local_library_client.dart';
import 'package:ttplay/library_cloud/cloud_external_mirror_store.dart';
import 'package:ttplay/library_cloud/cloud_keyring.dart';
import 'package:ttplay/media/ids.dart';
import 'package:ttplay/media/media_browser_dialect.dart';
import 'package:ttplay/services/credential_vault.dart';
import 'package:ttplay/services/multi_server_manager.dart';
import 'package:ttplay/session/app_session_controller.dart';
import 'package:ttplay/session/app_session_models.dart';
import 'package:ttplay/storage/mount_manager.dart';
import 'package:ttplay/storage/mount_registry.dart';
import 'package:ttplay/ttplay/ttplay_session_binder.dart';

import '../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  const sampleM3u = '''
#EXTM3U
#EXTINF:-1 group-title="央视",CCTV1综合
https://live.example.com/cctv1.m3u8
''';

  http.Response jsonResponse(Object data, [int status = 200]) => http.Response.bytes(
    utf8.encode(jsonEncode(data)),
    status,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );

  setUp(() {
    resetSharedPreferencesForTest();
    CredentialVault.resetKeyForTesting();
  });

  test('CloudExternalMirrorStore encrypts credentials at rest and isolates accounts', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final store = CloudExternalMirrorStore(db);

    final snapshotA = CloudExternalMirrorSnapshot(
      iptvSources: const [
        IptvSource(
          id: 'cloud:tv_a',
          name: 'TV',
          m3uUrl: 'http://10.0.10.48:1905/interface.m3u',
          epgUrl: 'http://10.0.10.48:1905/playback.xml',
          userAgent: 'SecretUA',
          isCloud: true,
          cloudSourceId: 'tv_a',
        ),
      ],
      externalConnections: [
        JellyfinConnection(
          id: 'cloud-emby_a',
          baseUrl: 'http://10.0.10.20:8096',
          serverName: 'Home Emby',
          serverMachineId: 'emby-machine-a',
          userId: 'user-a',
          userName: 'alice',
          accessToken: 'super-secret-emby-token-xyz',
          deviceId: 'dev-a',
          dialect: MediaBrowserDialect.emby,
          createdAt: DateTime(2026, 11, 24),
        ),
      ],
    );
    const snapshotB = CloudExternalMirrorSnapshot(
      iptvSources: [
        IptvSource(
          id: 'cloud:tv_b',
          name: 'TV B',
          m3uUrl: 'http://10.0.20.48:1905/b.m3u',
          isCloud: true,
          cloudSourceId: 'tv_b',
        ),
      ],
      externalConnections: [],
    );

    await store.save('scope_a', snapshotA);
    await store.save('scope_b', snapshotB);

    // Raw DB value must be encrypted via CredentialVault without plaintext tokens or URLs.
    final rawRowA = await (db.select(
      db.syncMetadata,
    )..where((t) => t.key.equals(CloudExternalMirrorStore.keyForScope('scope_a')))).getSingleOrNull();
    expect(rawRowA, isNotNull);
    expect(CredentialVault.isProtected(rawRowA!.value), isTrue);
    expect(rawRowA.value, isNot(contains('super-secret-emby-token-xyz')));
    expect(rawRowA.value, isNot(contains('10.0.10.48')));

    final loadedA = await store.load('scope_a');
    final loadedB = await store.load('scope_b');
    expect(loadedA, isNotNull);
    expect(loadedA!.iptvSources, hasLength(1));
    expect(loadedA.iptvSources.single.name, 'TV');
    expect(loadedA.iptvSources.single.m3uUrl, 'http://10.0.10.48:1905/interface.m3u');
    expect(loadedA.iptvSources.single.epgUrl, 'http://10.0.10.48:1905/playback.xml');
    expect(loadedA.iptvSources.single.userAgent, 'SecretUA');
    expect(loadedA.externalConnections, hasLength(1));
    expect(loadedA.externalConnections.single.dialect, MediaBrowserDialect.emby);
    expect(loadedA.externalConnections.single.accessToken, 'super-secret-emby-token-xyz');
    expect(loadedA.externalConnections.single.serverMachineId, 'emby-machine-a');

    expect(loadedB, isNotNull);
    expect(loadedB!.iptvSources.single.name, 'TV B');
    expect(loadedB.externalConnections, isEmpty);
  });

  test('cold start keeps cloud IPTV, cached channels, and reachable LAN Emby working when sync server is down', () async {
    final prevOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = prevOverrides);

    // Spin up a local Emby mock server that answers health checks.
    var embyReachable = true;
    final embyServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => embyServer.close(force: true));
    embyServer.listen((req) async {
      if (!embyReachable) {
        req.response.statusCode = HttpStatus.serviceUnavailable;
        await req.response.close();
        return;
      }
      req.response.statusCode = HttpStatus.ok;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({'Id': 'u_emby', 'Policy': {'IsAdministrator': false}}));
      await req.response.close();
    });

    final tempCacheDir = await Directory.systemTemp.createTemp('cloud_mirror_iptv_');
    addTearDown(() async {
      if (tempCacheDir.existsSync()) {
        await tempCacheDir.delete(recursive: true);
      }
    });
    final channelCache = IptvChannelCache(directoryProvider: () async => tempCacheDir);

    final hk = CloudKeyring.generateMasterKey();
    final iptvCipher = await CloudKeyring.encryptCredentialJson(
      masterKey: hk,
      payload: {'m3u_url': 'http://10.0.10.48:1905/interface.m3u', 'epg_url': 'http://10.0.10.48:1905/playback.xml'},
    );
    final embyCipher = await CloudKeyring.encryptCredentialJson(
      masterKey: hk,
      payload: {
        'base_url': 'http://127.0.0.1:${embyServer.port}',
        'access_token': 'emby_tok',
        'user_id': 'u_emby',
        'username': 'bob',
        'server_machine_id': 'lan-emby-1',
      },
    );
    final davCipher = await CloudKeyring.encryptCredentialJson(
      masterKey: hk,
      payload: {'base_url': 'http://10.0.10.50:5244/dav'},
    );

    final serverSources = <Map<String, dynamic>>[
      {'id': 'src_iptv', 'kind': 'iptv', 'name': 'TV', 'identity_key': 'iptv:1', 'status': 'active'},
      {'id': 'src_emby', 'kind': 'emby', 'name': 'LAN Emby', 'identity_key': 'emby:1', 'status': 'active'},
      {'id': 'src_dav', 'kind': 'webdav', 'name': 'Home NAS', 'identity_key': 'webdav:1', 'status': 'active'},
    ];
    final serverCreds = <String, String>{
      'src_iptv': iptvCipher,
      'src_emby': embyCipher,
      'src_dav': davCipher,
    };

    var syncServerDown = false;
    final syncClient = MockClient((req) async {
      if (syncServerDown) {
        throw const SocketException('sync server permanently offline');
      }
      final p = req.url.path;
      if (p == '/api/v1/sources') {
        return jsonResponse({'code': 0, 'sources': serverSources});
      }
      if (p.endsWith('/credential')) {
        final id = p.split('/')[4];
        return jsonResponse({
          'code': 0,
          'credential': {'source_id': id, 'ciphertext': serverCreds[id], 'version': 1, 'key_epoch': 1, 'status': 'valid'},
        });
      }
      if (p == '/api/v1/library/snapshot') {
        return jsonResponse({
          'code': 0,
          'snapshot_seq': 1,
          'total': 0,
          'page': 1,
          'page_size': 100,
          'has_more': false,
          'items': const [],
        });
      }
      if (p == '/api/v1/progress' || p == '/api/v1/favorites' || p == '/api/v1/user/unmatched') {
        return jsonResponse({'code': 0, 'items': const []});
      }
      return jsonResponse({'code': 404}, 404);
    });

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final session = SelfHostedSession(
      serverUrl: 'http://123.57.195.60:20001',
      username: 'alice',
      accessToken: 'tok',
      householdId: 'hh1',
      memberId: 'm1',
      masterKeyB64: base64Encode(hk),
    );

    // Session 1: sync from live sync server and warm IPTV channel disk cache.
    final mounts1 = MountManager(MountRegistry(db));
    final localClient1 = LocalLibraryClient(repository: LibraryRepository(db), mounts: mounts1);
    final sm1 = MultiServerManager();
    final sc1 = AppSessionController(db: db, mountManager: mounts1);
    sc1.debugSetStateForTesting(mode: AppLoginMode.selfHosted, selfHostedSession: session);
    final iptv1 = IptvProvider(
      channelCache: channelCache,
      httpClientFactory: () => MockClient((req) async {
        if (req.url.toString().contains('10.0.10.48:1905/interface.m3u')) {
          return http.Response.bytes(utf8.encode(sampleM3u), 200);
        }
        return http.Response('not found', 404);
      }),
    );
    final binder1 = TtplaySessionBinder(
      sessionController: sc1,
      serverManager: sm1,
      localLibraryClient: localClient1,
      isTv: () => false,
      httpClientFactory: () => syncClient,
    );
    binder1.attachIptvProvider(iptv1);
    await binder1.syncFromSession(refreshExternalServers: true, awaitCloudSync: true);
    binder1.cloudProjectionEngine?.stopListeningEvents();

    expect(iptv1.sources.map((s) => s.name), ['TV']);
    await iptv1.ensureLoaded(iptv1.sources.single);
    expect(iptv1.channelsFor('cloud:src_iptv').map((c) => c.name), ['CCTV1综合']);

    binder1.dispose();
    iptv1.dispose();
    sm1.dispose();
    sc1.dispose();
    await mounts1.dispose();

    // Session 2: cold restart with sync server COMPLETELY DOWN.
    syncServerDown = true;
    final mounts2 = MountManager(MountRegistry(db));
    final localClient2 = LocalLibraryClient(repository: LibraryRepository(db), mounts: mounts2);
    final sm2 = MultiServerManager();
    final sc2 = AppSessionController(db: db, mountManager: mounts2);
    sc2.debugSetStateForTesting(mode: AppLoginMode.selfHosted, selfHostedSession: session);
    final iptv2 = IptvProvider(
      channelCache: channelCache,
      httpClientFactory: () => MockClient((_) async => throw const SocketException('m3u also offline')),
    );
    final binder2 = TtplaySessionBinder(
      sessionController: sc2,
      serverManager: sm2,
      localLibraryClient: localClient2,
      isTv: () => false,
      httpClientFactory: () => syncClient,
    );

    final persistedMirror = await CloudExternalMirrorStore(db).load(TtplaySessionBinder.accountScopeKeyFor(session));
    expect(persistedMirror, isNotNull);

    binder2.attachIptvProvider(iptv2);
    // Synchronous Frame-1 seed makes TV immediately visible before async sync attempt.
    binder2.seedSelfHostedSynchronously(session, cachedMirror: persistedMirror);
    expect(iptv2.sources.map((s) => s.name), ['TV']);

    // Wait briefly for disk cache warmup & LAN Emby direct probe.
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(iptv2.channelsFor('cloud:src_iptv').map((c) => c.name), ['CCTV1综合']);
    expect(sm2.isServerOnline(ServerId('lan-emby-1')), isTrue);

    // Sync attempt against down sync server fails gracefully without wiping TV, Emby, or WebDAV mirror.
    await binder2.syncFromSession(refreshExternalServers: true, awaitCloudSync: true);
    binder2.cloudProjectionEngine?.stopListeningEvents();
    expect(iptv2.sources.map((s) => s.name), ['TV']);
    expect(sm2.isServerOnline(ServerId('lan-emby-1')), isTrue);
    expect((await mounts2.registry.list()).map((m) => m.id), contains('cloud:src_dav'));

    // When LAN Emby becomes unreachable, Emby automatically marks offline (hidden from library/home).
    embyReachable = false;
    await binder2.probeCloudReachability();
    expect(sm2.isServerOnline(ServerId('lan-emby-1')), isFalse);

    binder2.dispose();
    iptv2.dispose();
    sm2.dispose();
    sc2.dispose();
    await mounts2.dispose();
  });

  test('sync server recovery reconciles deletions and Offline Mode keeps mirror isolated', () async {
    final hk = CloudKeyring.generateMasterKey();
    final iptvCipher = await CloudKeyring.encryptCredentialJson(
      masterKey: hk,
      payload: {'m3u_url': 'http://10.0.10.48:1905/interface.m3u'},
    );
    final embyCipher = await CloudKeyring.encryptCredentialJson(
      masterKey: hk,
      payload: {
        'base_url': 'http://10.0.10.99:8096',
        'access_token': 'emby_tok',
        'user_id': 'u1',
        'server_machine_id': 'emby-gone',
      },
    );

    final serverSources = <Map<String, dynamic>>[
      {'id': 'src_iptv', 'kind': 'iptv', 'name': 'TV Old', 'identity_key': 'iptv:1', 'status': 'active'},
      {'id': 'src_emby', 'kind': 'emby', 'name': 'Old Emby', 'identity_key': 'emby:1', 'status': 'active'},
    ];
    final mockSync = MockClient((req) async {
      final p = req.url.path;
      if (p == '/api/v1/sources') {
        return jsonResponse({'code': 0, 'sources': serverSources});
      }
      if (p.endsWith('/credential')) {
        final id = p.split('/')[4];
        return jsonResponse({
          'code': 0,
          'credential': {
            'source_id': id,
            'ciphertext': id == 'src_iptv' ? iptvCipher : embyCipher,
            'version': 1,
            'key_epoch': 1,
            'status': 'valid',
          },
        });
      }
      if (p == '/api/v1/library/snapshot') {
        return jsonResponse({
          'code': 0,
          'snapshot_seq': 1,
          'total': 0,
          'page': 1,
          'page_size': 100,
          'has_more': false,
          'items': const [],
        });
      }
      if (p == '/api/v1/progress' || p == '/api/v1/favorites' || p == '/api/v1/user/unmatched') {
        return jsonResponse({'code': 0, 'items': const []});
      }
      return jsonResponse({'code': 404}, 404);
    });

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final mounts = MountManager(MountRegistry(db));
    final localClient = LocalLibraryClient(repository: LibraryRepository(db), mounts: mounts);
    final sm = MultiServerManager();
    final sc = AppSessionController(db: db, mountManager: mounts);
    final session = SelfHostedSession(
      serverUrl: 'http://123.57.195.60:20001',
      username: 'alice',
      accessToken: 'tok',
      householdId: 'hh1',
      memberId: 'm1',
      masterKeyB64: base64Encode(hk),
    );
    sc.debugSetStateForTesting(mode: AppLoginMode.selfHosted, selfHostedSession: session);
    final iptv = IptvProvider();
    final binder = TtplaySessionBinder(
      sessionController: sc,
      serverManager: sm,
      localLibraryClient: localClient,
      isTv: () => false,
      httpClientFactory: () => mockSync,
    );
    binder.attachIptvProvider(iptv);

    await binder.syncFromSession(refreshExternalServers: true, awaitCloudSync: true);
    binder.cloudProjectionEngine?.stopListeningEvents();
    expect(iptv.sources.map((s) => s.name), ['TV Old']);

    // Update IPTV name and delete cloud Emby on sync server, then run full sync.
    serverSources
      ..clear()
      ..add({'id': 'src_iptv', 'kind': 'iptv', 'name': 'TV New', 'identity_key': 'iptv:1', 'status': 'active'});
    await binder.syncCloudProjection(full: true);
    binder.cloudProjectionEngine?.stopListeningEvents();
    expect(iptv.sources.map((s) => s.name), ['TV New']);

    final mirrorAfterDelete = await CloudExternalMirrorStore(db).load(TtplaySessionBinder.accountScopeKeyFor(session));
    expect(mirrorAfterDelete, isNotNull);
    expect(mirrorAfterDelete!.iptvSources.map((s) => s.name), ['TV New']);
    expect(mirrorAfterDelete.externalConnections, isEmpty);

    // Switch to Offline Mode: cloud IPTV disappears from Offline scope without erasing the encrypted mirror.
    await sc.switchToOfflineMode();
    await binder.syncFromSession(refreshExternalServers: true, awaitCloudSync: false);
    await Future<void>.delayed(Duration.zero);
    expect(iptv.isCloudMode, isFalse);
    expect(iptv.sources, isEmpty);
    final mirrorStillSaved = await CloudExternalMirrorStore(db).load(TtplaySessionBinder.accountScopeKeyFor(session));
    expect(mirrorStillSaved, isNotNull);
    expect(mirrorStillSaved!.iptvSources.map((s) => s.name), ['TV New']);

    binder.dispose();
    iptv.dispose();
    sm.dispose();
    sc.dispose();
    await mounts.dispose();
  });
}
