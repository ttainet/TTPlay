import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ttplay/connection/connection.dart';
import 'package:ttplay/connection/connection_registry.dart';
import 'package:ttplay/database/app_database.dart';
import 'package:ttplay/library/library_repository.dart';
import 'package:ttplay/library/library_scan_service.dart';
import 'package:ttplay/library/library_scanner.dart';
import 'package:ttplay/library/library_settings.dart';
import 'package:ttplay/library/local_workspace_archive.dart';
import 'package:ttplay/media/ids.dart';
import 'package:ttplay/profiles/active_profile_binder.dart';
import 'package:ttplay/profiles/active_profile_provider.dart';
import 'package:ttplay/profiles/plex_home_service.dart';
import 'package:ttplay/profiles/profile.dart';
import 'package:ttplay/profiles/profile_connection.dart';
import 'package:ttplay/profiles/profile_connection_registry.dart';
import 'package:ttplay/profiles/profile_registry.dart';
import 'package:ttplay/services/credential_vault.dart';
import 'package:ttplay/services/multi_server_manager.dart';
import 'package:ttplay/services/storage_service.dart';
import 'package:ttplay/session/app_session_controller.dart';
import 'package:ttplay/storage/mount_manager.dart';
import 'package:ttplay/storage/mount_registry.dart';
import 'package:ttplay/storage/storage_mount.dart';

import '../test_helpers/backend_client_fixtures.dart';
import '../test_helpers/multi_server_fixtures.dart';
import '../test_helpers/prefs.dart';

class _TestPlexHome extends PlexHomeService {
  _TestPlexHome({required super.connections, required super.profileConnections, required super.storage})
    : super(plexHomeUserFetcher: (_) async => const []);

  @override
  Future<void> start() async {}

  @override
  Future<void> reloadFromStorage() async {}

  @override
  Future<void> dispose() async {}
}

class _SuppressibleServerManager extends MultiServerManager {
  final List<String> attemptedConnectionIds = [];

  @override
  Future<bool> addJellyfinConnection(JellyfinConnection connection) async {
    attemptedConnectionIds.add(connection.serverMachineId);
    updateServerStatus(ServerId(connection.serverMachineId), true);
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() {
    resetSharedPreferencesForTest();
    CredentialVault.resetKeyForTesting();
  });

  Future<HttpServer> startSelfHostedAuthServer() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final path = req.uri.path;
      final bodyText = await utf8.decoder.bind(req).join();
      req.response.statusCode = 200;
      req.response.headers.contentType = ContentType.json;
      if (path == '/api/v1/public/bootstrap') {
        req.response.write(
          jsonEncode({
            'code': 0,
            'initialized': true,
            'protocol_version': 1,
            'min_protocol_version': 1,
            'server_name': 'Sync Node',
            'registration_mode': 'closed',
          }),
        );
      } else if (path == '/api/v1/auth/login') {
        final reqJson = jsonDecode(bodyText) as Map<String, dynamic>;
        final user = reqJson['username'] as String? ?? 'user';
        req.response.write(
          jsonEncode({
            'code': 0,
            'username': user,
            'access_token': 'tok_$user',
            'token_id': 'tid_$user',
            'household': {'id': 'hh_$user'},
            'member': {'id': 'mem_$user'},
          }),
        );
      } else {
        req.response.write(jsonEncode({'code': 0}));
      }
      await req.response.close();
    });
    return server;
  }

  test('offline archive is preserved across self-hosted logout and account switch without overwriting', () async {
    final prevOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = prevOverrides);

    final authServer = await startSelfHostedAuthServer();
    addTearDown(() => authServer.close(force: true));
    final serverUrl = 'http://127.0.0.1:${authServer.port}';

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final registry = MountRegistry(db);
    final manager = MountManager(registry);
    addTearDown(manager.dispose);
    final archive = LocalWorkspaceArchive(db);
    final settingsStore = LibrarySettingsStore(db);
    final controller = AppSessionController(db: db, archive: archive, mountManager: manager);
    addTearDown(controller.dispose);

    // 1. Seed Offline workspace: mount, library item, and local TMDB scraper key.
    await controller.selectOfflineMode();
    await registry.upsert(
      const StorageMount(
        id: 'offline_mount_1',
        kind: StorageKind.webdav,
        displayName: 'Offline NAS',
        config: {MountKeys.baseUrl: 'https://nas.offline/dav', MountKeys.rootPath: '/'},
      ),
    );
    await db.into(db.libraryItems).insert(
      LibraryItemsCompanion.insert(
        kind: LibraryKinds.movie,
        libraryType: LibraryTypes.movie,
        title: 'Offline Only Movie',
        sortTitle: 'offline only movie',
        addedAt: 1,
        updatedAt: 1,
      ),
    );
    await settingsStore.saveScraper(const ScraperSettings(tmdbApiKey: 'local-secret-tmdb-key', language: 'zh-CN'));

    // 2. Log into Sync account #1: offline workspace must be archived and cleared.
    await controller.loginSelfHosted(serverUrl: serverUrl, username: 'alice', password: 'pw1');
    expect(controller.isSelfHosted, isTrue);
    expect(await archive.hasArchive(), isTrue);
    expect(await registry.list(), isEmpty);
    expect(await db.select(db.libraryItems).get(), isEmpty);
    expect((await settingsStore.loadScraper()).tmdbApiKey, isEmpty);

    // Simulate cloud projection data arriving in working tables while in Sync Mode.
    await registry.upsert(
      const StorageMount(
        id: 'cloud:src_alice',
        kind: StorageKind.webdav,
        displayName: 'Alice Cloud DAV',
        config: {MountKeys.baseUrl: 'https://alice.cloud/dav', MountKeys.rootPath: '/'},
      ),
    );
    await db.into(db.libraryItems).insert(
      LibraryItemsCompanion.insert(
        workKey: const Value('tmdb:movie:999'),
        kind: LibraryKinds.movie,
        libraryType: LibraryTypes.movie,
        title: 'Alice Cloud Movie',
        sortTitle: 'alice cloud movie',
        addedAt: 2,
        updatedAt: 2,
      ),
    );

    // 3. Log out to mode selection: working cloud tables must be cleared WITHOUT touching the 'local' snapshot.
    await controller.logoutToModeSelection();
    expect(controller.hasSelectedMode, isFalse);
    expect(await registry.list(), isEmpty);
    expect(await db.select(db.libraryItems).get(), isEmpty);
    expect(await archive.hasArchive(), isTrue);

    // 4. Re-enter Sync Mode as account #2 and confirm cloud rows from account #2 don't clobber local archive.
    await controller.loginSelfHosted(serverUrl: serverUrl, username: 'bob', password: 'pw2');
    await db.into(db.libraryItems).insert(
      LibraryItemsCompanion.insert(
        workKey: const Value('tmdb:movie:888'),
        kind: LibraryKinds.movie,
        libraryType: LibraryTypes.movie,
        title: 'Bob Cloud Movie',
        sortTitle: 'bob cloud movie',
        addedAt: 3,
        updatedAt: 3,
      ),
    );
    await controller.logoutToModeSelection();

    // 5. Switch back to Offline Mode: original offline mount, item, and TMDB key are restored intact!
    await controller.selectOfflineMode();
    expect(controller.isOffline, isTrue);
    final restoredMounts = await registry.list();
    expect(restoredMounts.map((m) => m.id), ['offline_mount_1']);
    final restoredItems = await db.select(db.libraryItems).get();
    expect(restoredItems.map((i) => i.title), ['Offline Only Movie']);
    expect((await settingsStore.loadScraper()).tmdbApiKey, 'local-secret-tmdb-key');
  });

  test('ActiveProfileBinder suppresses local Jellyfin/Emby bindings when suppressProfileConnections is true', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final profiles = ProfileRegistry(db);
    final connections = ConnectionRegistry(db);
    final profileConnections = ProfileConnectionRegistry(db);
    final storage = await StorageService.getInstance();
    final plexHome = _TestPlexHome(connections: connections, profileConnections: profileConnections, storage: storage);
    addTearDown(plexHome.dispose);
    final activeProfile = ActiveProfileProvider(
      registry: profiles,
      plexHome: plexHome,
      connections: connections,
      profileConnections: profileConnections,
      storage: storage,
    );
    addTearDown(() async {
      await activeProfile.resetForTesting();
      activeProfile.dispose();
    });
    final serverManager = _SuppressibleServerManager();
    addTearDown(serverManager.dispose);
    final multiServer = testMultiServerProvider(serverManager);
    addTearDown(multiServer.dispose);

    final profile = Profile.local(id: 'p1', displayName: 'Local', createdAt: DateTime(2026));
    final jf = testJellyfinConnection(machineId: 'jf_local_1', userId: 'u1');
    await profiles.upsert(profile);
    await connections.upsert(jf);
    await profileConnections.upsert(
      ProfileConnection(profileId: profile.id, connectionId: jf.id, userToken: 'tok', userIdentifier: 'u1'),
    );
    await activeProfile.reloadFromStorage();
    await activeProfile.activate(profile);

    var suppress = true;
    final binder = ActiveProfileBinder(
      activeProfile: activeProfile,
      connections: connections,
      profileConnections: profileConnections,
      serverManager: serverManager,
      multiServerProvider: multiServer,
      suppressProfileConnections: () => suppress,
    );
    addTearDown(binder.dispose);

    binder.start();
    await binder.rebindActive();
    expect(serverManager.attemptedConnectionIds, isEmpty);
    expect(activeProfile.lastBindingSucceeded, isTrue);

    suppress = false;
    await binder.rebindActive();
    expect(serverManager.attemptedConnectionIds, ['jf_local_1']);
    expect(activeProfile.lastBindingSucceeded, isTrue);
  });

  test('LibraryScanService blocks local mutations when isLocalLibraryWritable returns false', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = LibraryRepository(db);
    final mounts = MountManager(MountRegistry(db));
    addTearDown(mounts.dispose);
    await mounts.registry.upsert(
      const StorageMount(
        id: 'm1',
        kind: StorageKind.local,
        displayName: 'Local',
        config: {MountKeys.rootPath: '/nonexistent'},
      ),
    );
    await db.into(db.libraryItems).insert(
      LibraryItemsCompanion.insert(
        kind: LibraryKinds.movie,
        libraryType: LibraryTypes.movie,
        title: 'Protected Item',
        sortTitle: 'protected item',
        addedAt: 1,
        updatedAt: 1,
      ),
    );

    var scrapeCalls = 0;
    final scanService = LibraryScanService(
      repository: repo,
      scanner: LibraryScanner(db, repo),
      mounts: mounts,
      scrape: ({
        bool retryUnmatched = false,
        Set<String>? mountIds,
        bool refreshMatched = false,
        bool allowKindChange = true,
        int? refreshBeforeMs,
        bool Function()? isCancelled,
        void Function(int done, int total)? onProgress,
      }) async {
        scrapeCalls++;
        return const LibraryScrapeOutcome();
      },
      isLocalLibraryWritable: () => false,
    );
    addTearDown(scanService.dispose);

    expect(await scanService.scanAllMounts(), isFalse);
    expect(await scanService.rebuildAllMounts(), isFalse);
    expect(await scanService.refileAll(), 0);
    await scanService.scrapeLibrary(retryUnmatched: true);
    final refreshResult = await scanService.triggerManualIncrementalRefresh(canRun: () => true);
    expect(refreshResult.triggered, isFalse);
    expect(scrapeCalls, 0);
    // rebuildAllMounts must NOT have wiped library_items when blocked!
    expect((await db.select(db.libraryItems).get()).single.title, 'Protected Item');
  });
}
