import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/connection/connection_registry.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_library.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/server_capabilities.dart';
import 'package:plezy/navigation/navigation_tabs.dart';
import 'package:plezy/profiles/active_profile_provider.dart';
import 'package:plezy/profiles/plex_home_service.dart';
import 'package:plezy/profiles/profile.dart';
import 'package:plezy/profiles/profile_connection.dart';
import 'package:plezy/profiles/profile_connection_registry.dart';
import 'package:plezy/profiles/profile_registry.dart';
import 'package:plezy/providers/hidden_libraries_provider.dart';
import 'package:plezy/providers/libraries_provider.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/storage_service.dart';
import 'package:plezy/ttplay/ttplay_server_client.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/widgets/side_navigation_rail.dart';
import 'package:provider/provider.dart';

import '../test_helpers/multi_server_fixtures.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/theme.dart';

class _EmptyConnections extends ConnectionRegistry {
  _EmptyConnections(super.db);

  @override
  Stream<List<Connection>> watchConnections() => Stream.value(const []);
}

class _EmptyBindings extends ProfileConnectionRegistry {
  _EmptyBindings(super.db);

  @override
  Stream<List<ProfileConnection>> watchForProfile(String profileId) => Stream.value(const []);
}

class _FixedActiveProfile extends ActiveProfileProvider {
  _FixedActiveProfile({
    required super.registry,
    required super.plexHome,
    required super.connections,
    required super.profileConnections,
    required super.storage,
    required Profile profile,
  }) : _fixedProfile = profile;

  final Profile _fixedProfile;

  @override
  String? get activeId => _fixedProfile.id;

  @override
  Profile? get active => _fixedProfile;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    TvDetectionService.debugSetAppleTVOverride(null);
    TvDetectionService.setForceTVSync(false);
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

  testWidgets(
    'renders ttplay-server shelves under main Libraries section and external Emby/Jellyfin servers separately under active profile scope',
    (tester) async {
      await SettingsService.getInstance();
      final storage = await StorageService.getInstance();
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final connections = _EmptyConnections(db);
      final bindings = _EmptyBindings(db);
      final plexHome = PlexHomeService(
        connections: connections,
        profileConnections: bindings,
        storage: storage,
        plexHomeUserFetcher: (_) async => const [],
      );
      final ownerProfile = Profile.local(id: 'local-owner', displayName: 'Owner', createdAt: DateTime(2026));
      final activeProfile = _FixedActiveProfile(
        registry: ProfileRegistry(db),
        plexHome: plexHome,
        connections: connections,
        profileConnections: bindings,
        storage: storage,
        profile: ownerProfile,
      );

      final librariesProvider = LibrariesProvider();
      await librariesProvider.updateLibraryOrder([
        const MediaLibrary(
          id: 'movie',
          backend: MediaBackend.jellyfin,
          title: 'Movies',
          kind: MediaKind.movie,
          serverId: TtplayServerClient.primaryServerId,
          serverName: 'NAS Server',
        ),
        const MediaLibrary(
          id: 'show',
          backend: MediaBackend.jellyfin,
          title: 'TV Shows',
          kind: MediaKind.show,
          serverId: TtplayServerClient.primaryServerId,
          serverName: 'NAS Server',
        ),
        const MediaLibrary(
          id: 'v-emby-1',
          backend: MediaBackend.emby,
          title: 'Emby Films',
          kind: MediaKind.movie,
          serverId: 'ttplay-ext:emby-1',
          serverName: 'Emby Living Room',
        ),
        const MediaLibrary(
          id: 'v-jf-2',
          backend: MediaBackend.jellyfin,
          title: 'Jellyfin Series',
          kind: MediaKind.show,
          serverId: 'ttplay-ext:jf-2',
          serverName: 'Jellyfin NAS',
        ),
      ]);

      final hiddenProvider = HiddenLibrariesProvider();
      await hiddenProvider.ensureInitialized();

      final manager = MultiServerManager();
      final multiServer = testMultiServerProvider(manager);

      addTearDown(() async {
        activeProfile.dispose();
        await plexHome.dispose();
        await db.close();
        multiServer.dispose();
        manager.dispose();
        librariesProvider.dispose();
        hiddenProvider.dispose();
      });

      await tester.pumpWidget(
        TranslationProvider(
          child: MultiProvider(
            providers: [
              ChangeNotifierProvider<ActiveProfileProvider>.value(value: activeProfile),
              Provider<ConnectionRegistry>.value(value: connections),
              Provider<ProfileConnectionRegistry>.value(value: bindings),
              ChangeNotifierProvider<LibrariesProvider>.value(value: librariesProvider),
              ChangeNotifierProvider<HiddenLibrariesProvider>.value(value: hiddenProvider),
              ChangeNotifierProvider<MultiServerProvider>.value(value: multiServer),
            ],
            child: MaterialApp(
              theme: ThemeData(extensions: const [testMonoTokens]),
              home: Scaffold(
                body: SideNavigationRail(
                  selectedTab: NavigationTabId.libraries,
                  selectedLibraryKey: 'ttplay-server:movie',
                  alwaysExpanded: true,
                  onDestinationSelected: (_) {},
                  onLibrarySelected: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Main Libraries shelves from ttplay-server render directly under Libraries,
      // never under a separate "NAS Server" remote header.
      expect(find.text('Movies'), findsOneWidget);
      expect(find.text('TV Shows'), findsOneWidget);
      expect(find.text('NAS Server'), findsNothing);
      expect(tester.getTopLeft(find.text('Movies')).dx, greaterThan(tester.getTopLeft(find.text('Libraries')).dx));

      // External Emby & Jellyfin servers render in separate server sections even
      // with _hasProfileScope == true and empty local ConnectionRegistry.
      expect(find.text('Emby Living Room'), findsOneWidget);
      expect(find.text('Emby Films'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Emby Films')).dx,
        greaterThan(tester.getTopLeft(find.text('Emby Living Room')).dx),
      );
      expect(find.text('Jellyfin NAS'), findsOneWidget);
      expect(find.text('Jellyfin Series'), findsOneWidget);
    },
  );

  testWidgets(
    'renders direct cloud-mounted Emby servers in selfHostedServerIds under active profile scope while filtering unbound local ones',
    (tester) async {
      await SettingsService.getInstance();
      final storage = await StorageService.getInstance();
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final connections = _EmptyConnections(db);
      final bindings = _EmptyBindings(db);
      final plexHome = PlexHomeService(
        connections: connections,
        profileConnections: bindings,
        storage: storage,
        plexHomeUserFetcher: (_) async => const [],
      );
      final ownerProfile = Profile.local(id: 'local-owner', displayName: 'Owner', createdAt: DateTime(2026));
      final activeProfile = _FixedActiveProfile(
        registry: ProfileRegistry(db),
        plexHome: plexHome,
        connections: connections,
        profileConnections: bindings,
        storage: storage,
        profile: ownerProfile,
      );

      final directEmby = _FakeDirectServerClient(
        serverId: ServerId('emby-machine-123'),
        serverName: 'Direct Emby',
        backend: MediaBackend.emby,
      );
      final emptyEmby = _FakeDirectServerClient(
        serverId: ServerId('emby-machine-empty'),
        serverName: 'Empty Emby',
        backend: MediaBackend.emby,
      );

      final manager = MultiServerManager();
      manager.registerSelfHostedExternals([directEmby, emptyEmby]);
      final multiServer = testMultiServerProvider(manager);

      final librariesProvider = LibrariesProvider();
      await librariesProvider.updateLibraryOrder([
        const MediaLibrary(
          id: 'emby-lib-1',
          backend: MediaBackend.emby,
          title: 'Direct Emby Movies',
          kind: MediaKind.movie,
          serverId: 'emby-machine-123',
          serverName: 'Direct Emby',
        ),
        const MediaLibrary(
          id: 'unbound-lib-1',
          backend: MediaBackend.emby,
          title: 'Unbound Emby Movies',
          kind: MediaKind.movie,
          serverId: 'unbound-emby-999',
          serverName: 'Unbound Emby',
        ),
      ]);

      final hiddenProvider = HiddenLibrariesProvider();
      await hiddenProvider.ensureInitialized();

      addTearDown(() async {
        activeProfile.dispose();
        await plexHome.dispose();
        await db.close();
        multiServer.dispose();
        manager.dispose();
        librariesProvider.dispose();
        hiddenProvider.dispose();
      });

      await tester.pumpWidget(
        TranslationProvider(
          child: MultiProvider(
            providers: [
              ChangeNotifierProvider<ActiveProfileProvider>.value(value: activeProfile),
              Provider<ConnectionRegistry>.value(value: connections),
              Provider<ProfileConnectionRegistry>.value(value: bindings),
              ChangeNotifierProvider<LibrariesProvider>.value(value: librariesProvider),
              ChangeNotifierProvider<HiddenLibrariesProvider>.value(value: hiddenProvider),
              ChangeNotifierProvider<MultiServerProvider>.value(value: multiServer),
            ],
            child: MaterialApp(
              theme: ThemeData(extensions: const [testMonoTokens]),
              home: Scaffold(
                body: SideNavigationRail(
                  selectedTab: NavigationTabId.discover,
                  alwaysExpanded: true,
                  onDestinationSelected: (_) {},
                  onLibrarySelected: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Direct Emby'), findsOneWidget);
      expect(find.text('Direct Emby Movies'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Direct Emby Movies')).dx,
        greaterThan(tester.getTopLeft(find.text('Direct Emby')).dx),
      );
      expect(find.text('Empty Emby'), findsOneWidget);
      expect(find.text('Unbound Emby'), findsNothing);
      expect(find.text('Unbound Emby Movies'), findsNothing);
    },
  );
}

class _FakeDirectServerClient implements MediaServerClient {
  _FakeDirectServerClient({required this.serverId, required this.serverName, required this.backend});

  @override
  final ServerId serverId;

  @override
  final String serverName;

  @override
  final MediaBackend backend;

  @override
  ServerCapabilities get capabilities => ServerCapabilities.emby;

  @override
  Object get authenticationSessionId => const Object();

  @override
  Future<List<MediaLibrary>> fetchLibraries() async => const [];

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
