import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ttplay/database/app_database.dart';
import 'package:ttplay/focus/input_mode_tracker.dart';
import 'package:ttplay/i18n/strings.g.dart';
import 'package:ttplay/iptv/iptv_models.dart';
import 'package:ttplay/iptv/iptv_provider.dart';
import 'package:ttplay/library/library_repository.dart';
import 'package:ttplay/library/local_library_client.dart';
import 'package:ttplay/library_cloud/cloud_keyring.dart';
import 'package:ttplay/navigation/main_screen_scope.dart';
import 'package:ttplay/navigation/navigation_tabs.dart';
import 'package:ttplay/providers/hidden_libraries_provider.dart';
import 'package:ttplay/providers/libraries_provider.dart';
import 'package:ttplay/providers/multi_server_provider.dart';
import 'package:ttplay/screens/iptv/iptv_screen.dart';
import 'package:ttplay/services/credential_vault.dart';
import 'package:ttplay/services/multi_server_manager.dart';
import 'package:ttplay/services/settings_service.dart';
import 'package:ttplay/session/app_session_controller.dart';
import 'package:ttplay/session/app_session_models.dart';
import 'package:ttplay/storage/mount_manager.dart';
import 'package:ttplay/storage/mount_registry.dart';
import 'package:ttplay/ttplay/ttplay_session_binder.dart';
import 'package:ttplay/utils/platform_detector.dart';
import 'package:ttplay/widgets/side_navigation_rail.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers/multi_server_fixtures.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/theme.dart';

void main() {
  const sampleM3u = '''
#EXTM3U
#EXTINF:-1 group-title="央视",CCTV1综合
https://live.example.com/cctv1-a.m3u8
#EXTINF:-1 group-title="央视",CCTV1综合
https://live.example.com/cctv1-b.m3u8
#EXTINF:-1 group-title="卫视",湖南卫视高清直播频道名称很长展示测试
https://live.example.com/hunan.m3u8
''';

  Future<IptvProvider> createLoadedProvider() async {
    SharedPreferences.setMockInitialValues({});
    final provider = IptvProvider(
      httpClientFactory: () => MockClient((request) async {
        return http.Response.bytes(utf8.encode(sampleM3u), 200);
      }),
    );
    const source = IptvSource(
      id: 'local:test',
      name: 'Test IPTV',
      m3uUrl: 'http://127.0.0.1:1905/all.m3u',
    );
    await provider.addLocalSource(source);
    await provider.ensureLoaded(source);
    return provider;
  }

  FocusNode findFocusNodeByLabel(String debugLabel) {
    return FocusManager.instance.rootScope.descendants.firstWhere((n) => n.debugLabel == debugLabel);
  }

  Widget buildHarness({
    required IptvProvider provider,
    required VoidCallback onFocusSidebar,
    AppSessionController? appSession,
    TtplaySessionBinder? binder,
  }) {
    return InputModeTracker(
      child: MultiProvider(
        providers: [
          ChangeNotifierProvider<IptvProvider>.value(value: provider),
          if (appSession != null) ChangeNotifierProvider<AppSessionController>.value(value: appSession),
          if (binder != null) ChangeNotifierProvider<TtplaySessionBinder>.value(value: binder),
        ],
        child: MaterialApp(
          theme: ThemeData(extensions: const [testMonoTokens]),
          home: MainScreenFocusScope(
            focusSidebar: onFocusSidebar,
            sideNavigationWidth: 200,
            child: const IptvScreen(),
          ),
        ),
      ),
    );
  }

  testWidgets('renders left-right split layout and filters channels by category', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final provider = await createLoadedProvider();
    addTearDown(provider.dispose);

    await tester.pumpWidget(buildHarness(provider: provider, onFocusSidebar: () {}));
    await tester.pumpAndSettle();

    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.text('全部'), findsOneWidget);
    expect(find.text('央视'), findsWidgets);
    expect(find.text('卫视'), findsWidgets);
    expect(find.text('CCTV1综合'), findsOneWidget);
    expect(find.text('湖南卫视高清直播频道名称很长展示测试'), findsOneWidget);

    final allRect = tester.getRect(find.text('全部'));
    final firstCardRect = tester.getRect(find.text('CCTV1综合'));
    expect(allRect.right, lessThan(firstCardRect.left));

    await tester.tap(find.text('卫视').first);
    await tester.pumpAndSettle();

    expect(find.text('CCTV1综合'), findsNothing);
    expect(find.text('湖南卫视高清直播频道名称很长展示测试'), findsOneWidget);
  });

  testWidgets('supports TV D-pad traversal between sidebar, category list, grid, and channel action menu', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final provider = await createLoadedProvider();
    addTearDown(provider.dispose);

    var sidebarFocusCalls = 0;
    await tester.pumpWidget(
      buildHarness(provider: provider, onFocusSidebar: () => sidebarFocusCalls++),
    );
    await tester.pumpAndSettle();

    final weishiNode = findFocusNodeByLabel('iptv_group_g:卫视');
    weishiNode.requestFocus();
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'iptv_group_g:卫视');

    // Pressing RIGHT from category selects it and moves focus to first channel card in grid.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.text('CCTV1综合'), findsNothing);
    expect(find.text('湖南卫视高清直播频道名称很长展示测试'), findsOneWidget);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'iptv_first_content');

    // Pressing BACK from channel card returns focus to the selected category tile.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'iptv_group_g:卫视');

    // Pressing LEFT from category tile returns to the main sidebar.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(sidebarFocusCalls, 1);

    // Context menu on a multi-variant channel card opens the TV actions dialog.
    findFocusNodeByLabel('iptv_group___iptv_all__').requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'iptv_first_content');

    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();
    expect(find.text('立即播放'), findsOneWidget);
    expect(find.text('选择线路（2 条）'), findsOneWidget);
    expect(find.text('收藏频道'), findsOneWidget);
  });

  testWidgets('SideNavigationRail lists each IPTV source by custom name and selects active source on tap', (
    tester,
  ) async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    TvDetectionService.debugSetAppleTVOverride(null);
    TvDetectionService.setForceTVSync(false);
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();

    final librariesProvider = LibrariesProvider();
    addTearDown(librariesProvider.dispose);
    final hiddenLibrariesProvider = HiddenLibrariesProvider();
    await hiddenLibrariesProvider.ensureInitialized();
    addTearDown(hiddenLibrariesProvider.dispose);
    final bundle = testMultiServer();

    final iptvProvider = IptvProvider();
    addTearDown(iptvProvider.dispose);
    await iptvProvider.addLocalSource(
      const IptvSource(id: 'local:s1', name: '客厅直播', m3uUrl: 'http://127.0.0.1:1905/a.m3u'),
    );
    await iptvProvider.addLocalSource(
      const IptvSource(id: 'local:s2', name: '体育源', m3uUrl: 'http://127.0.0.1:1905/b.m3u'),
    );

    NavigationTabId? selectedTab;
    await tester.pumpWidget(
      TranslationProvider(
        child: MultiProvider(
          providers: [
            ChangeNotifierProvider<LibrariesProvider>.value(value: librariesProvider),
            ChangeNotifierProvider<HiddenLibrariesProvider>.value(value: hiddenLibrariesProvider),
            ChangeNotifierProvider<MultiServerProvider>.value(value: bundle.provider),
            ChangeNotifierProvider<IptvProvider>.value(value: iptvProvider),
          ],
          child: MaterialApp(
            theme: ThemeData(extensions: const [testMonoTokens]),
            home: Scaffold(
              body: SideNavigationRail(
                selectedTab: NavigationTabId.discover,
                alwaysExpanded: true,
                onDestinationSelected: (tab) => selectedTab = tab,
                onLibrarySelected: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('客厅直播'), findsOneWidget);
    expect(find.text('体育源'), findsOneWidget);
    expect(find.text('IPTV'), findsNothing);

    final livingRoomRect = tester.getRect(find.text('客厅直播'));
    final sportsRect = tester.getRect(find.text('体育源'));
    final searchRect = tester.getRect(find.text('Search'));
    expect(livingRoomRect.bottom, lessThan(sportsRect.top));
    expect(sportsRect.bottom, lessThan(searchRect.top));

    await tester.tap(find.text('体育源'));
    await tester.pumpAndSettle();
    expect(iptvProvider.activeSource?.id, 'local:s2');
    expect(selectedTab, NavigationTabId.iptv);
  });

  testWidgets('TV sync mode hides source management button and refreshes cloud projection plus playlist', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    TvDetectionService.debugSetAppleTVOverride(true);
    TvDetectionService.setForceTVSync(false);
    addTearDown(() {
      TvDetectionService.debugSetAppleTVOverride(null);
      TvDetectionService.setForceTVSync(false);
    });

    const updatedM3u = '''
#EXTM3U
#EXTINF:-1 group-title="卫视",东方卫视
https://live.example.com/dongfang.m3u8
''';

    final env = await _TvSyncIptvHarness.create(
      initialHasRemoteSource: true,
      initialPlaylist: sampleM3u,
    );
    try {
      await tester.pumpWidget(
        buildHarness(
          provider: env.iptvProvider,
          appSession: env.appSession,
          binder: env.binder,
          onFocusSidebar: () {},
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('管理 IPTV 源'), findsNothing);
      expect(find.byTooltip('同步并刷新频道列表'), findsOneWidget);
      expect(find.text('CCTV1综合'), findsOneWidget);
      expect(env.playlistCalls, 1);

      env.playlistBody = updatedM3u;
      await tester.tap(find.byTooltip('同步并刷新频道列表'));
      await tester.pumpAndSettle();

      expect(env.changesCalls, greaterThanOrEqualTo(1));
      expect(env.playlistCalls, 2);
      expect(find.text('东方卫视'), findsOneWidget);
      expect(find.text('CCTV1综合'), findsNothing);
    } finally {
      await env.dispose(tester);
    }
  });

  testWidgets('TV sync mode empty state triggers immediate sync without source management button', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    TvDetectionService.debugSetAppleTVOverride(true);
    TvDetectionService.setForceTVSync(false);
    addTearDown(() {
      TvDetectionService.debugSetAppleTVOverride(null);
      TvDetectionService.setForceTVSync(false);
    });

    final env = await _TvSyncIptvHarness.create(
      initialHasRemoteSource: false,
      initialPlaylist: sampleM3u,
    );
    try {
      await tester.pumpWidget(
        buildHarness(
          provider: env.iptvProvider,
          appSession: env.appSession,
          binder: env.binder,
          onFocusSidebar: () {},
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('管理 IPTV 源'), findsNothing);
      expect(find.byTooltip('同步并刷新频道列表'), findsOneWidget);
      expect(find.text('立即同步'), findsOneWidget);
      expect(find.text('管理 IPTV 源'), findsNothing);

      env.hasRemoteSource = true;
      env.emitSourceChangeOnPoll = true;
      await tester.tap(find.text('立即同步'));
      await tester.pumpAndSettle();

      expect(find.text('CCTV1综合'), findsOneWidget);
    } finally {
      await env.dispose(tester);
    }
  });

  testWidgets('Non-TV mode keeps manage IPTV sources button', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    TvDetectionService.debugSetAppleTVOverride(false);
    TvDetectionService.setForceTVSync(false);
    addTearDown(() {
      TvDetectionService.debugSetAppleTVOverride(null);
      TvDetectionService.setForceTVSync(false);
    });

    final provider = await createLoadedProvider();
    addTearDown(provider.dispose);

    await tester.pumpWidget(buildHarness(provider: provider, onFocusSidebar: () {}));
    await tester.pumpAndSettle();

    expect(find.byTooltip('管理 IPTV 源'), findsOneWidget);
    expect(find.byTooltip('刷新频道列表'), findsOneWidget);
  });
}

class _TvSyncIptvHarness {
  _TvSyncIptvHarness._({
    required this.db,
    required this.mounts,
    required this.serverManager,
    required this.appSession,
    required this.iptvProvider,
    required this.binder,
    required this.hasRemoteSource,
    required this.playlistBody,
  });

  final AppDatabase db;
  final MountManager mounts;
  final MultiServerManager serverManager;
  final AppSessionController appSession;
  final IptvProvider iptvProvider;
  final TtplaySessionBinder binder;

  int changesCalls = 0;
  int playlistCalls = 0;
  bool hasRemoteSource;
  bool emitSourceChangeOnPoll = false;
  String playlistBody;

  static http.Response _jsonResponse(Object data, [int status = 200]) => http.Response.bytes(
    utf8.encode(jsonEncode(data)),
    status,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );

  static Future<_TvSyncIptvHarness> create({
    required bool initialHasRemoteSource,
    required String initialPlaylist,
  }) async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    resetSharedPreferencesForTest();
    CredentialVault.resetKeyForTesting();

    final hk = CloudKeyring.generateMasterKey();
    final cipher = await CloudKeyring.encryptCredentialJson(
      masterKey: hk,
      payload: {'m3u_url': 'http://10.0.10.48:1905/interface.m3u'},
    );

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final mounts = MountManager(MountRegistry(db));
    final localClient = LocalLibraryClient(repository: LibraryRepository(db), mounts: mounts);
    final serverManager = MultiServerManager();
    final appSession = AppSessionController(db: db, mountManager: mounts);
    final session = SelfHostedSession(
      serverUrl: 'http://127.0.0.1:20001',
      username: 'alice',
      accessToken: 'tok',
      householdId: 'hh1',
      memberId: 'm1',
      masterKeyB64: base64Encode(hk),
    );
    appSession.debugSetStateForTesting(mode: AppLoginMode.selfHosted, selfHostedSession: session);

    late _TvSyncIptvHarness harness;
    final mockSyncClient = MockClient((req) async {
      final path = req.url.path;
      if (req.method == 'GET' && path == '/api/v1/sources') {
        return _jsonResponse({
          'code': 0,
          'sources': harness.hasRemoteSource
              ? [
                  {'id': 'src_0', 'kind': 'iptv', 'name': '客厅电视', 'identity_key': 'iptv:0', 'status': 'active'},
                ]
              : const [],
        });
      }
      if (req.method == 'GET' && path == '/api/v1/sources/src_0/credential') {
        return _jsonResponse({
          'code': 0,
          'credential': {'source_id': 'src_0', 'ciphertext': cipher, 'version': 1, 'key_epoch': 1, 'status': 'valid'},
        });
      }
      if (req.method == 'GET' && path == '/api/v1/library/snapshot') {
        return _jsonResponse({
          'code': 0,
          'snapshot_seq': 5,
          'total': 0,
          'page': 1,
          'page_size': 100,
          'has_more': false,
          'items': const [],
        });
      }
      if (req.method == 'GET' && path == '/api/v1/library/changes') {
        harness.changesCalls++;
        return _jsonResponse({
          'code': 0,
          'latest_seq': 6,
          'reset_required': false,
          'has_more': false,
          'changes': harness.emitSourceChangeOnPoll
              ? [
                  {'seq': 6, 'entity': 'source', 'op': 'create', 'entity_id': 'src_0'},
                ]
              : const [],
        });
      }
      if (req.method == 'GET' && (path == '/api/v1/progress' || path == '/api/v1/favorites')) {
        return _jsonResponse({'code': 0, 'items': const []});
      }
      if (req.method == 'GET' && path == '/api/v1/user/unmatched') {
        return _jsonResponse({'code': 0, 'items': const []});
      }
      return _jsonResponse({'code': 404, 'error': 'not found'}, 404);
    });

    final iptvProvider = IptvProvider(
      httpClientFactory: () => MockClient((_) async {
        harness.playlistCalls++;
        return http.Response.bytes(utf8.encode(harness.playlistBody), 200);
      }),
    );
    final binder = TtplaySessionBinder(
      sessionController: appSession,
      serverManager: serverManager,
      localLibraryClient: localClient,
      isTv: () => true,
      httpClientFactory: () => mockSyncClient,
    );
    harness = _TvSyncIptvHarness._(
      db: db,
      mounts: mounts,
      serverManager: serverManager,
      appSession: appSession,
      iptvProvider: iptvProvider,
      binder: binder,
      hasRemoteSource: initialHasRemoteSource,
      playlistBody: initialPlaylist,
    );
    binder.attachIptvProvider(iptvProvider);
    await binder.syncFromSession(refreshExternalServers: true, awaitCloudSync: true);
    binder.cloudProjectionEngine?.stopListeningEvents();
    return harness;
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    binder.cloudProjectionEngine?.stopListeningEvents();
    binder.dispose();
    iptvProvider.dispose();
    serverManager.dispose();
    appSession.dispose();
    await tester.runAsync(() async {
      await mounts.dispose();
      await db.close();
    });
  }
}
