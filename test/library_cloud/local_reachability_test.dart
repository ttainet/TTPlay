import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ttplay/connection/connection.dart';
import 'package:ttplay/database/app_database.dart';
import 'package:ttplay/library/library_repository.dart';
import 'package:ttplay/library/local_library_client.dart';
import 'package:ttplay/library_cloud/cloud_api_client.dart';
import 'package:ttplay/library_cloud/cloud_keyring.dart';
import 'package:ttplay/library_cloud/cloud_mount_mirror.dart';
import 'package:ttplay/library_cloud/source_repository.dart';
import 'package:ttplay/media/ids.dart';
import 'package:ttplay/media/media_browser_dialect.dart';
import 'package:ttplay/media/media_server_client.dart';
import 'package:ttplay/services/multi_server_manager.dart';
import 'package:ttplay/services/playback_initialization_types.dart';
import 'package:ttplay/storage/mount_manager.dart';
import 'package:ttplay/storage/mount_registry.dart';
import 'package:ttplay/storage/storage_driver.dart';
import 'package:ttplay/storage/storage_mount.dart';
import 'package:ttplay/storage/stream_proxy.dart';

import '../test_helpers/backend_client_fixtures.dart';
import '../test_helpers/prefs.dart';

class _TestMountDriver implements StorageDriver {
  _TestMountDriver({required this.kind, required this.useFallback, required this.onCheck, required this.onClose});

  @override
  final StorageKind kind;
  final bool useFallback;
  final Future<void> Function() onCheck;
  final void Function() onClose;

  @override
  Future<void> check() => onCheck();

  @override
  Future<List<StorageEntry>> list(String path, {StorageEntry? parent}) async => const [];

  @override
  Future<StorageEntry> stat(String path) async =>
      StorageEntry(path: path, name: path.split('/').last, isDirectory: false, size: 1024);

  @override
  Stream<List<int>> openRead(StorageEntry entry, {int start = 0, int? end}) async* {
    final total = end != null ? (end - start + 1) : 16;
    yield List<int>.filled(total.clamp(1, 64), 7);
  }

  @override
  Future<void> close() async => onClose();
}

class _TestMountManager extends MountManager {
  _TestMountManager(super.registry);

  final Map<String, ({bool primaryOk, bool fallbackOk, StorageException? error})> rules = {};
  final Map<String, int> checkCalls = {};
  final Map<String, int> closeCalls = {};
  final List<({String mountId, bool useFallback})> createdDrivers = [];
  Completer<void>? checkGate;

  @override
  StorageDriver createDriver(StorageMount mount, {bool? useFallback}) {
    final effectiveFallback = useFallback ?? (statusOf(mount.id) == MountOnlineStatus.onlineFallback);
    createdDrivers.add((mountId: mount.id, useFallback: effectiveFallback));
    return _TestMountDriver(
      kind: mount.kind,
      useFallback: effectiveFallback,
      onCheck: () async {
        checkCalls[mount.id] = (checkCalls[mount.id] ?? 0) + 1;
        final gate = checkGate;
        if (gate != null) {
          await gate.future;
        }
        final rule = rules[mount.id];
        if (rule == null) return;
        if (rule.error != null) throw rule.error!;
        final ok = effectiveFallback ? rule.fallbackOk : rule.primaryOk;
        if (!ok) {
          throw StorageException(
            StorageErrorKind.network,
            'unreachable (${effectiveFallback ? 'fallback' : 'primary'})',
          );
        }
      },
      onClose: () {
        closeCalls[mount.id] = (closeCalls[mount.id] ?? 0) + 1;
      },
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(resetSharedPreferencesForTest);

  group('Cloud Emby/Jellyfin local reachability', () {
    test(
      'syncDirectCloudExternalConnections defaults to offline, promotes on async probe, and supports checkServerHealth + reconnectOfflineServers',
      () async {
        final prevOverrides = HttpOverrides.current;
        HttpOverrides.global = null;
        addTearDown(() => HttpOverrides.global = prevOverrides);

        var reachable = true;
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((req) async {
          if (!reachable) {
            req.response.statusCode = HttpStatus.serviceUnavailable;
            await req.response.close();
            return;
          }
          req.response.headers.contentType = ContentType.json;
          if (req.uri.path.endsWith('/Users/Me')) {
            req.response.statusCode = 200;
            req.response.write(
              jsonEncode({
                'Policy': {'IsAdministrator': false},
              }),
            );
          } else {
            req.response.statusCode = 200;
            req.response.write(jsonEncode({'Id': 'emby-cloud-1', 'ServerName': 'Home Emby', 'Version': '4.9.5'}));
          }
          await req.response.close();
        });

        final connectivityCtrl = StreamController<List<ConnectivityResult>>.broadcast();
        addTearDown(connectivityCtrl.close);
        final manager = MultiServerManager(connectivityChanges: () => connectivityCtrl.stream);
        addTearDown(manager.dispose);

        final conn = JellyfinConnection(
          id: 'cloud-src-emby-1',
          baseUrl: 'http://127.0.0.1:${server.port}',
          baseUrls: ['http://127.0.0.1:${server.port}'],
          serverName: 'Home Emby',
          serverMachineId: 'emby-cloud-1',
          userId: 'u1',
          userName: 'alice',
          accessToken: 'tok-1',
          deviceId: 'dev-1',
          dialect: MediaBrowserDialect.emby,
          isAdministrator: false,
          createdAt: DateTime(2026),
        );

        await manager.syncDirectCloudExternalConnections([conn], probeTimeout: const Duration(seconds: 2));

        // Initially seeded offline synchronously so startup/home/search never block.
        expect(manager.selfHostedServerIds, contains('emby-cloud-1'));
        expect(manager.isServerOnline(ServerId('emby-cloud-1')), isFalse);
        expect(manager.onlineClients.containsKey('emby-cloud-1'), isFalse);

        // Background probe promotes it to online once /Users/Me answers 200.
        for (var i = 0; i < 40 && !manager.isServerOnline(ServerId('emby-cloud-1')); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        expect(manager.isServerOnline(ServerId('emby-cloud-1')), isTrue);
        expect(manager.onlineClients.containsKey('emby-cloud-1'), isTrue);

        // Re-syncing unchanged connection reuses existing client without flickering offline.
        final firstClient = manager.getClient(ServerId('emby-cloud-1'));
        await manager.syncDirectCloudExternalConnections([conn]);
        expect(identical(manager.getClient(ServerId('emby-cloud-1')), firstClient), isTrue);
        expect(manager.isServerOnline(ServerId('emby-cloud-1')), isTrue);

        // Dropping connectivity marks it offline on checkServerHealth (verifies _activeJellyfinMachine tracking).
        reachable = false;
        await manager.checkServerHealth();
        expect(manager.isServerOnline(ServerId('emby-cloud-1')), isFalse);

        // Restoring reachability brings it back on reconnectOfflineServers.
        reachable = true;
        await manager.reconnectOfflineServers();
        expect(manager.isServerOnline(ServerId('emby-cloud-1')), isTrue);
      },
    );

    test(
      'unreachable cloud Emby stays offline and never enters onlineClients, while seedOnlineServerIds starts online',
      () async {
        final prevOverrides = HttpOverrides.current;
        HttpOverrides.global = null;
        addTearDown(() => HttpOverrides.global = prevOverrides);

        // Unbound port -> immediately unreachable.
        final tempSocket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final deadPort = tempSocket.port;
        await tempSocket.close();

        final manager = MultiServerManager(connectivityChanges: () => const Stream.empty());
        addTearDown(manager.dispose);

        final offlineConn = testEmbyConnection(
          machineId: 'emby-dead',
          userId: 'u1',
          id: 'cloud-src-dead',
          baseUrl: 'http://127.0.0.1:$deadPort',
          baseUrls: ['http://127.0.0.1:$deadPort'],
          serverName: 'Dead LAN Emby',
        );
        final seededConn = testEmbyConnection(
          machineId: 'emby-seeded',
          userId: 'u1',
          id: 'cloud-src-seeded',
          baseUrl: 'http://127.0.0.1:$deadPort',
          baseUrls: ['http://127.0.0.1:$deadPort'],
          serverName: 'Freshly Verified Emby',
        );

        await manager.syncDirectCloudExternalConnections(
          [offlineConn, seededConn],
          seedOnlineServerIds: const {'emby-seeded'},
          probeTimeout: const Duration(milliseconds: 500),
        );

        expect(manager.isServerOnline(ServerId('emby-seeded')), isTrue);
        expect(manager.isServerOnline(ServerId('emby-dead')), isFalse);

        // Wait for background probe of emby-dead to finish.
        for (var i = 0; i < 40 && manager.isProbingServer('emby-dead'); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        expect(manager.isServerOnline(ServerId('emby-dead')), isFalse);
        expect(manager.onlineClients.containsKey('emby-dead'), isFalse);
        expect(manager.selfHostedExternalHealth('emby-dead'), HealthStatus.offline);
      },
    );
  });

  group('MountManager Scheme A, Quark TTL, and probeAll coalescing', () {
    test('showOfflineMounts defaults to true so offline mounts remain visible in LibraryRepository', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final mounts = _TestMountManager(MountRegistry(db));
      addTearDown(mounts.dispose);
      final repo = LibraryRepository(db)..hiddenMountIds = () => mounts.hiddenOfflineMountIds;

      await mounts.registry.upsert(
        const StorageMount(
          id: 'cloud:m-offline',
          kind: StorageKind.webdav,
          displayName: 'LAN WebDAV',
          config: {MountKeys.baseUrl: 'http://192.168.1.9/dav'},
        ),
      );
      final itemId = await repo.insertItem(
        LibraryItemsCompanion.insert(
          kind: LibraryKinds.movie,
          libraryType: LibraryTypes.movie,
          title: 'LAN Film',
          sortTitle: 'lan film',
          addedAt: 10,
          updatedAt: 10,
        ),
      );
      final fileId = await repo.upsertFile(
        mountId: 'cloud:m-offline',
        path: '/LAN Film.mkv',
        role: LibraryFileRoles.video,
        scanId: 1,
      );
      await repo.linkFile(fileId, itemId);

      mounts.setStatus('cloud:m-offline', MountOnlineStatus.offline);
      expect(mounts.showOfflineMounts, isTrue);
      expect(mounts.hiddenOfflineMountIds, isEmpty);

      final page = await repo.queryTitles(const LibraryQuery(libraryType: LibraryTypes.movie));
      expect(page.items.map((e) => e.item.title), ['LAN Film']);
    });

    test(
      'applyProbeStatus drops stale primary driver when switching to onlineFallback without resetting status',
      () async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final mounts = _TestMountManager(MountRegistry(db));
        addTearDown(mounts.dispose);

        const mount = StorageMount(
          id: 'dav-1',
          kind: StorageKind.webdav,
          displayName: 'NAS',
          config: {MountKeys.baseUrl: 'http://192.168.1.9/dav', MountKeys.fallbackUrl: 'https://ddns.example/dav'},
        );
        await mounts.registry.upsert(mount);

        // Build primary driver while unknown.
        mounts.driverFor(mount);
        expect(mounts.createdDrivers.last.useFallback, isFalse);

        await mounts.applyProbeStatus(mount.id, MountOnlineStatus.onlineFallback, kind: mount.kind);
        expect(mounts.statusOf(mount.id), MountOnlineStatus.onlineFallback);
        expect(mounts.closeCalls[mount.id], 1);

        // Next driverFor creates a fallback driver.
        mounts.driverFor(mount);
        expect(mounts.createdDrivers.last.useFallback, isTrue);
      },
    );

    test('probeAll queues a trailing probe when called during an in-flight probe', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final mounts = _TestMountManager(MountRegistry(db));
      addTearDown(mounts.dispose);

      await mounts.registry.upsert(
        const StorageMount(
          id: 'dav-1',
          kind: StorageKind.webdav,
          displayName: 'NAS 1',
          config: {MountKeys.baseUrl: 'http://192.168.1.9/dav'},
        ),
      );
      mounts.rules['dav-1'] = (primaryOk: true, fallbackOk: false, error: null);
      mounts.checkGate = Completer<void>();

      final firstProbe = mounts.probeAll();
      // Wait for dav-1 check to hit the gate.
      for (var i = 0; i < 20 && (mounts.checkCalls['dav-1'] ?? 0) == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      // A second mount arrives mid-probe and requests probeAll().
      await mounts.registry.upsert(
        const StorageMount(
          id: 'dav-2',
          kind: StorageKind.webdav,
          displayName: 'NAS 2',
          config: {MountKeys.baseUrl: 'http://192.168.1.10/dav'},
        ),
      );
      mounts.rules['dav-2'] = (primaryOk: true, fallbackOk: false, error: null);

      final queuedProbe = mounts.probeAll();
      mounts.checkGate!.complete();
      mounts.checkGate = null;

      await firstProbe;
      await queuedProbe;

      expect(mounts.statusOf('dav-1'), MountOnlineStatus.onlinePrimary);
      expect(mounts.statusOf('dav-2'), MountOnlineStatus.onlinePrimary);
    });

    test('Quark probe TTL skips redundant checks within 5 minutes unless force is true', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final mounts = _TestMountManager(MountRegistry(db));
      addTearDown(mounts.dispose);

      await mounts.registry.upsert(
        const StorageMount(
          id: 'cloud:q1',
          kind: StorageKind.quark,
          displayName: 'Quark',
          config: {MountKeys.rootFolderId: '0'},
          secrets: {MountKeys.secretCookie: '__puus=abc'},
        ),
      );
      mounts.rules['cloud:q1'] = (primaryOk: true, fallbackOk: false, error: null);

      var now = DateTime(2026, 1, 1, 12, 0, 0);
      await withClock(Clock(() => now), () async {
        await mounts.probeAll();
        expect(mounts.checkCalls['cloud:q1'], 1);

        // Within 5 minutes -> skipped.
        now = now.add(const Duration(minutes: 4));
        await mounts.probeAll();
        expect(mounts.checkCalls['cloud:q1'], 1);

        // force: true overrides TTL.
        await mounts.probeAll(force: true);
        expect(mounts.checkCalls['cloud:q1'], 2);

        // Within 5 minutes after forced check -> skipped; past 5 minutes -> runs.
        now = now.add(const Duration(minutes: 4));
        await mounts.probeAll();
        expect(mounts.checkCalls['cloud:q1'], 2);

        now = now.add(const Duration(minutes: 2));
        await mounts.probeAll();
        expect(mounts.checkCalls['cloud:q1'], 3);
      });
    });

    test(
      'CloudMountMirror seeds new mounts offline, preserves status when unchanged, and respects markSourceRecentlyVerified',
      () async {
        final prevOverrides = HttpOverrides.current;
        HttpOverrides.global = null;
        addTearDown(() => HttpOverrides.global = prevOverrides);

        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final mounts = _TestMountManager(MountRegistry(db));
        addTearDown(mounts.dispose);

        final hk = CloudKeyring.generateMasterKey();
        var baseUrl = 'http://192.168.1.50/dav';
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((req) async {
          if (req.uri.path == '/api/v1/sources') {
            req.response.write(
              jsonEncode({
                'code': 0,
                'sources': [
                  {
                    'id': 'src_dav',
                    'kind': 'webdav',
                    'name': 'Home DAV',
                    'identity_key': 'k1',
                    'status': 'active',
                    'folders': [
                      {'id': 'f1', 'source_id': 'src_dav', 'path': '/Movies'},
                    ],
                  },
                ],
              }),
            );
          } else if (req.uri.path == '/api/v1/sources/src_dav/credential') {
            final cipher = await CloudKeyring.encryptCredentialJson(
              masterKey: hk,
              payload: {'base_url': baseUrl, 'username': 'u', 'password': 'p', 'root_path': '/'},
            );
            req.response.write(
              jsonEncode({
                'code': 0,
                'credential': {
                  'source_id': 'src_dav',
                  'ciphertext': cipher,
                  'version': 1,
                  'key_epoch': 1,
                  'status': 'valid',
                },
              }),
            );
          }
          await req.response.close();
        });

        final api = CloudApiClient(baseUrl: 'http://127.0.0.1:${server.port}', accessToken: 'tok');
        addTearDown(api.close);
        final repo = CloudSourceRepository(api: api, masterKeyProvider: () => hk, keyEpoch: 1);
        final mirror = CloudMountMirror(sourceRepository: repo, mountRegistry: mounts.registry, mountManager: mounts);

        // 1. Fresh cloud mount defaults to offline.
        await mirror.mirrorAllWithExternals();
        expect(mounts.statusOf('cloud:src_dav'), MountOnlineStatus.offline);

        // 2. Once probed online, an unchanged sync must NOT reset status or drop driver.
        mounts.setStatus('cloud:src_dav', MountOnlineStatus.onlinePrimary);
        final m = (await mounts.registry.get('cloud:src_dav'))!;
        mounts.driverFor(m);
        await mirror.mirrorAllWithExternals();
        expect(mounts.statusOf('cloud:src_dav'), MountOnlineStatus.onlinePrimary);
        expect(mounts.closeCalls['cloud:src_dav'], isNull);

        // 3. Config change drops driver and resets to offline unless recently verified.
        baseUrl = 'http://192.168.1.51/dav';
        await mirror.mirrorAllWithExternals();
        expect(mounts.statusOf('cloud:src_dav'), MountOnlineStatus.offline);
        expect(mounts.closeCalls['cloud:src_dav'], 1);

        // 4. markSourceRecentlyVerified seeds onlinePrimary when mirrored after save.
        baseUrl = 'http://192.168.1.52/dav';
        mirror.markSourceRecentlyVerified('src_dav');
        await mirror.mirrorAllWithExternals();
        expect(mounts.statusOf('cloud:src_dav'), MountOnlineStatus.onlinePrimary);
      },
    );
  });

  group('LocalLibraryClient on-demand reachability verification', () {
    test('single unknown WebDAV mount with unreachable primary fails fast after one probe', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = LibraryRepository(db);
      final mounts = _TestMountManager(MountRegistry(db));
      addTearDown(mounts.dispose);
      final client = LocalLibraryClient(repository: repo, mounts: mounts);

      await mounts.registry.upsert(
        const StorageMount(
          id: 'dav-dead',
          kind: StorageKind.webdav,
          displayName: 'Dead DAV',
          config: {MountKeys.baseUrl: 'http://192.168.1.9/dav'},
        ),
      );
      mounts.rules['dav-dead'] = (primaryOk: false, fallbackOk: false, error: null);

      final itemId = await repo.insertItem(
        LibraryItemsCompanion.insert(
          kind: LibraryKinds.movie,
          libraryType: LibraryTypes.movie,
          title: 'Movie',
          sortTitle: 'movie',
          addedAt: 1,
          updatedAt: 1,
        ),
      );
      final fileId = await repo.upsertFile(
        mountId: 'dav-dead',
        path: '/Movie.mkv',
        role: LibraryFileRoles.video,
        scanId: 1,
      );
      await repo.linkFile(fileId, itemId);
      await client.refreshMounts();

      final item = (await client.fetchItem('$itemId'))!;
      await expectLater(
        client.getPlaybackInitialization(PlaybackInitializationOptions(metadata: item, selectedMediaIndex: 0)),
        throwsA(isA<PlaybackException>().having((e) => e.reason, 'reason', PlaybackFailureReason.localFileUnavailable)),
      );
      expect(mounts.statusOf('dav-dead'), MountOnlineStatus.offline);
      expect(mounts.checkCalls['dav-dead'], 1);
    });

    test(
      'single unknown WebDAV mount with fallback_url switches to onlineFallback and opens fallback driver',
      () async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final repo = LibraryRepository(db);
        final mounts = _TestMountManager(MountRegistry(db));
        addTearDown(mounts.dispose);
        final client = LocalLibraryClient(repository: repo, mounts: mounts);

        await mounts.registry.upsert(
          const StorageMount(
            id: 'dav-fb',
            kind: StorageKind.webdav,
            displayName: 'Home NAS',
            config: {MountKeys.baseUrl: 'http://192.168.1.9/dav', MountKeys.fallbackUrl: 'https://ddns.example/dav'},
          ),
        );
        mounts.rules['dav-fb'] = (primaryOk: false, fallbackOk: true, error: null);

        final itemId = await repo.insertItem(
          LibraryItemsCompanion.insert(
            kind: LibraryKinds.movie,
            libraryType: LibraryTypes.movie,
            title: 'Fallback Movie',
            sortTitle: 'fallback movie',
            addedAt: 1,
            updatedAt: 1,
          ),
        );
        final fileId = await repo.upsertFile(
          mountId: 'dav-fb',
          path: '/Fallback.mkv',
          role: LibraryFileRoles.video,
          scanId: 1,
        );
        await repo.linkFile(fileId, itemId);
        await client.refreshMounts();

        final item = (await client.fetchItem('$itemId'))!;
        final init = await client.getPlaybackInitialization(
          PlaybackInitializationOptions(metadata: item, selectedMediaIndex: 0),
        );
        expect(init.videoUrl, startsWith('http://127.0.0.1:'));
        expect(mounts.statusOf('dav-fb'), MountOnlineStatus.onlineFallback);
        expect(mounts.createdDrivers.last, (mountId: 'dav-fb', useFallback: true));
      },
    );

    test('multi-version movie skips offline WebDAV without probing and plays online Quark immediately', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = LibraryRepository(db);
      final mounts = _TestMountManager(MountRegistry(db));
      addTearDown(mounts.dispose);
      final client = LocalLibraryClient(repository: repo, mounts: mounts);

      await mounts.registry.upsert(
        const StorageMount(
          id: 'dav-lan',
          kind: StorageKind.webdav,
          displayName: 'LAN DAV',
          config: {MountKeys.baseUrl: 'http://192.168.1.9/dav'},
        ),
      );
      await mounts.registry.upsert(
        const StorageMount(
          id: 'quark-1',
          kind: StorageKind.quark,
          displayName: 'Quark',
          config: {MountKeys.rootFolderId: '0'},
          secrets: {MountKeys.secretCookie: '__puus=ok'},
        ),
      );
      mounts.setStatus('dav-lan', MountOnlineStatus.offline);
      mounts.setStatus('quark-1', MountOnlineStatus.onlinePrimary);

      final itemId = await repo.insertItem(
        LibraryItemsCompanion.insert(
          kind: LibraryKinds.movie,
          libraryType: LibraryTypes.movie,
          title: 'Multi Source',
          sortTitle: 'multi source',
          addedAt: 1,
          updatedAt: 1,
        ),
      );
      final davFile = await repo.upsertFile(
        mountId: 'dav-lan',
        path: '/Multi.mkv',
        role: LibraryFileRoles.video,
        scanId: 1,
        size: 5000,
      );
      final quarkFile = await repo.upsertFile(
        mountId: 'quark-1',
        path: '/Multi.mkv',
        role: LibraryFileRoles.video,
        scanId: 1,
        size: 3000,
      );
      await repo.linkFile(davFile, itemId);
      await repo.linkFile(quarkFile, itemId);
      await client.refreshMounts();

      final item = (await client.fetchItem('$itemId'))!;
      // Even when caller asks for the offline DAV version, playback skips it and uses online Quark.
      final init = await client.getPlaybackInitialization(
        PlaybackInitializationOptions(metadata: item, selectedMediaIndex: 0, selectedMediaSourceId: '$davFile'),
      );
      expect(init.selectedMediaSourceId, '$quarkFile');
      expect(mounts.checkCalls['dav-lan'], isNull);

      // Version list marks offline mount explicitly.
      expect(
        item.mediaVersions?.any((v) => v.name?.contains('LAN DAV') == true && v.parts.first.accessible == false),
        isTrue,
      );
    });

    test(
      'single offline mount recovers when reachable via last-resort probe, and getFileInfo skips offline probe',
      () async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final repo = LibraryRepository(db);
        final mounts = _TestMountManager(MountRegistry(db));
        addTearDown(mounts.dispose);
        final client = LocalLibraryClient(repository: repo, mounts: mounts);

        await mounts.registry.upsert(
          const StorageMount(
            id: 'dav-recover',
            kind: StorageKind.webdav,
            displayName: 'Recover DAV',
            config: {MountKeys.baseUrl: 'http://192.168.1.9/dav'},
          ),
        );
        mounts.setStatus('dav-recover', MountOnlineStatus.offline);
        mounts.rules['dav-recover'] = (primaryOk: false, fallbackOk: false, error: null);

        final itemId = await repo.insertItem(
          LibraryItemsCompanion.insert(
            kind: LibraryKinds.movie,
            libraryType: LibraryTypes.movie,
            title: 'Recoverable',
            sortTitle: 'recoverable',
            addedAt: 1,
            updatedAt: 1,
          ),
        );
        final fileId = await repo.upsertFile(
          mountId: 'dav-recover',
          path: '/Recover.mkv',
          role: LibraryFileRoles.video,
          scanId: 1,
        );
        await repo.linkFile(fileId, itemId);
        await client.refreshMounts();

        final item = (await client.fetchItem('$itemId'))!;

        // getFileInfo must not attempt a slow file-header probe while mount is offline.
        final info = await client.getFileInfo(item);
        expect(info, isNotNull);
        expect(mounts.createdDrivers.where((d) => d.mountId == 'dav-recover'), isEmpty);

        // Now user turns on VPN -> server becomes reachable -> playback recovers via last-resort probe.
        mounts.rules['dav-recover'] = (primaryOk: true, fallbackOk: false, error: null);
        final init = await client.getPlaybackInitialization(
          PlaybackInitializationOptions(metadata: item, selectedMediaIndex: 0),
        );
        expect(init.selectedMediaSourceId, '$fileId');
        expect(mounts.statusOf('dav-recover'), MountOnlineStatus.onlinePrimary);
      },
    );

    test('AccountProbeSource probe caches tier snapshot, seeds live driver, and detects authExpired', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      var unauthorized = false;
      final created = <_AccountProbeTestDriver>[];
      final mounts = MountManager(
        MountRegistry(db),
        proxy: StreamProxy(),
        driverFactory: (mount, {useFallback = false}) {
          final d = _AccountProbeTestDriver(
            kind: mount.kind,
            onProbe: () async {
              if (unauthorized) {
                throw const StorageException(StorageErrorKind.unauthorized, 'expired cookie');
              }
              return const DriveAccountSnapshot(memberTier: 'SUPER_VIP', usedBytes: 10, totalBytes: 100);
            },
          );
          created.add(d);
          return d;
        },
      );
      addTearDown(mounts.dispose);

      const mount = StorageMount(
        id: 'cloud:q-probe',
        kind: StorageKind.quark,
        displayName: 'Quark Probe',
        config: {MountKeys.rootFolderId: '0'},
        secrets: {MountKeys.secretCookie: '__puus=ok'},
      );
      await mounts.registry.upsert(mount);

      final status = await mounts.probeMount(mount);
      expect(status, MountOnlineStatus.onlinePrimary);
      expect(mounts.accountSnapshotOf(mount.id)?.memberTier, 'SUPER_VIP');

      final liveDriver = mounts.driverFor(mount) as _AccountProbeTestDriver;
      expect(liveDriver.seededTier, 'SUPER_VIP');

      unauthorized = true;
      final expired = await mounts.probeMount(mount);
      expect(expired, MountOnlineStatus.authExpired);
      expect(mounts.accountSnapshotOf(mount.id), isNull);
    });

    test(
      'concurrent probeMount calls deduplicate, save invalidates stale snapshot, and optimistic online still probes once',
      () async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        var probeCalls = 0;
        Completer<DriveAccountSnapshot>? gate;

        final mounts = MountManager(
          MountRegistry(db),
          proxy: StreamProxy(),
          driverFactory: (mount, {useFallback = false}) => _AccountProbeTestDriver(
            kind: mount.kind,
            onProbe: () {
              probeCalls++;
              final activeGate = gate;
              if (activeGate != null) return activeGate.future;
              return Future.value(const DriveAccountSnapshot(memberTier: 'Z_VIP'));
            },
          ),
        );
        addTearDown(mounts.dispose);

        const mount = StorageMount(
          id: 'cloud:q-dedup',
          kind: StorageKind.quark,
          displayName: 'Quark Dedup',
          config: {MountKeys.rootFolderId: '0'},
          secrets: {MountKeys.secretCookie: '__puus=old'},
        );
        await mounts.registry.upsert(mount);

        // 1. Two concurrent probes share one in-flight call.
        gate = Completer<DriveAccountSnapshot>();
        final p1 = mounts.probeMount(mount);
        final p2 = mounts.probeMount(mount);
        expect(probeCalls, 1);
        gate.complete(const DriveAccountSnapshot(memberTier: 'SUPER_VIP'));
        expect(await Future.wait([p1, p2]), [MountOnlineStatus.onlinePrimary, MountOnlineStatus.onlinePrimary]);
        expect(mounts.accountSnapshotOf(mount.id)?.memberTier, 'SUPER_VIP');

        // 2. Saving a modified mount while a probe is in flight discards the stale snapshot.
        gate = Completer<DriveAccountSnapshot>();
        final staleProbe = mounts.probeMount(mount);
        await Future<void>.delayed(Duration.zero);
        expect(probeCalls, 2);
        final updated = mount.copyWith(secrets: {MountKeys.secretCookie: '__puus=new'});
        await mounts.save(updated);
        gate.complete(const DriveAccountSnapshot(memberTier: 'OLD_VIP'));
        expect(await staleProbe, MountOnlineStatus.onlinePrimary);
        expect(mounts.accountSnapshotOf(mount.id), isNull);

        // 3. Optimistic onlinePrimary after dropCachedDriver does not stamp TTL: next probeAll fetches tier once, then TTL skips.
        gate = null;
        probeCalls = 0;
        await mounts.dropCachedDriver(mount.id, nextStatus: MountOnlineStatus.onlinePrimary, kind: StorageKind.quark);
        var now = DateTime(2026, 1, 1, 13, 0, 0);
        await withClock(Clock(() => now), () async {
          await mounts.probeAll();
          expect(probeCalls, 1);
          expect(mounts.accountSnapshotOf(mount.id)?.memberTier, 'Z_VIP');

          now = now.add(const Duration(minutes: 2));
          await mounts.probeAll();
          expect(probeCalls, 1);
        });
      },
    );
  });
}

class _AccountProbeTestDriver implements StorageDriver, AccountProbeSource {
  _AccountProbeTestDriver({required this.kind, required this.onProbe});

  @override
  final StorageKind kind;
  final Future<DriveAccountSnapshot> Function() onProbe;
  String? seededTier;

  @override
  Future<void> check() async {}

  @override
  Future<DriveAccountSnapshot> probeAccount() => onProbe();

  @override
  void seedAccountSnapshot(DriveAccountSnapshot snapshot) {
    seededTier = snapshot.memberTier;
  }

  @override
  Future<void> close() async {}

  @override
  Future<List<StorageEntry>> list(String path, {StorageEntry? parent}) async => const [];

  @override
  Stream<List<int>> openRead(StorageEntry entry, {int start = 0, int? end}) async* {}

  @override
  Future<StorageEntry> stat(String path) async =>
      const StorageEntry(path: '/a.mkv', name: 'a.mkv', isDirectory: false, size: 1024);
}
