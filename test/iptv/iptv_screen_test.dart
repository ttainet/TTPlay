import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/iptv/iptv_models.dart';
import 'package:plezy/iptv/iptv_provider.dart';
import 'package:plezy/navigation/main_screen_scope.dart';
import 'package:plezy/navigation/navigation_tabs.dart';
import 'package:plezy/providers/hidden_libraries_provider.dart';
import 'package:plezy/providers/libraries_provider.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/iptv/iptv_screen.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/widgets/side_navigation_rail.dart';
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
  }) {
    return InputModeTracker(
      child: ChangeNotifierProvider<IptvProvider>.value(
        value: provider,
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
}
