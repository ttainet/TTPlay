import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ttplay/database/app_database.dart';
import 'package:ttplay/focus/input_mode_tracker.dart';
import 'package:ttplay/i18n/strings.g.dart';
import 'package:ttplay/library/library_repository.dart';
import 'package:ttplay/library/library_scrape_runner.dart';
import 'package:ttplay/library/library_settings.dart';
import 'package:ttplay/library/local_library_client.dart';
import 'package:ttplay/screens/storage/scraper_settings_screen.dart';
import 'package:ttplay/services/credential_vault.dart';
import 'package:ttplay/session/app_session_controller.dart';
import 'package:ttplay/session/app_session_models.dart';
import 'package:ttplay/storage/mount_manager.dart';
import 'package:ttplay/storage/mount_registry.dart';
import 'package:ttplay/utils/platform_detector.dart';

import '../../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUpAll(() {
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

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

  testWidgets('Offline mode ScraperSettingsScreen edits and persists TMDB key, mirrors, proxy, and Bangumi toggle', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final store = LibrarySettingsStore(db);
    final mounts = MountManager(MountRegistry(db));
    final repo = LibraryRepository(db);
    final localClient = LocalLibraryClient(repository: repo, mounts: mounts);
    final runner = LibraryScrapeRunner(database: db, repository: repo, settings: store, mounts: mounts);
    final sessionController = AppSessionController(db: db, mountManager: mounts);
    sessionController.debugSetStateForTesting(mode: AppLoginMode.offline);

    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      sessionController.dispose();
      await mounts.dispose();
      await db.close();
    });

    await tester.pumpWidget(
      TranslationProvider(
        child: InputModeTracker(
          child: MultiProvider(
            providers: [
              Provider<LibrarySettingsStore>.value(value: store),
              Provider<LibraryScrapeRunner>.value(value: runner),
              Provider<LocalLibraryClient>.value(value: localClient),
              ChangeNotifierProvider<AppSessionController>.value(value: sessionController),
            ],
            child: MaterialApp(
              home: Builder(
                builder: (context) => Scaffold(
                  body: Center(
                    child: ElevatedButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(builder: (_) => const ScraperSettingsScreen()),
                      ),
                      child: const Text('Open scraper'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open scraper'));
    await tester.pumpAndSettle();

    expect(find.byType(ScraperSettingsScreen), findsOneWidget);
    expect(find.text(t.storage.metadataServiceSelfHosted), findsNothing);

    await tester.enterText(
      find.byWidgetPredicate((w) => w is TextField && w.decoration?.labelText == t.storage.tmdbKey),
      'my-tmdb-v3-key',
    );
    await tester.enterText(
      find.byWidgetPredicate((w) => w is TextField && w.decoration?.labelText == t.storage.metadataProxy),
      '127.0.0.1:7897',
    );
    await tester.enterText(
      find.byWidgetPredicate((w) => w is TextField && w.decoration?.labelText == t.storage.tmdbApiBase),
      'https://tmdb-api.example.com/3',
    );
    await tester.enterText(
      find.byWidgetPredicate((w) => w is TextField && w.decoration?.labelText == t.storage.tmdbImageBase),
      'https://tmdb-img.example.com/t/p',
    );
    await tester.tap(find.text(t.storage.bangumiForAnime));
    await tester.pump();

    await tester.tap(find.widgetWithText(FilledButton, t.common.save));
    await tester.pumpAndSettle();

    expect(find.byType(ScraperSettingsScreen), findsNothing);
    final saved = await store.loadScraper();
    expect(saved.tmdbApiKey, 'my-tmdb-v3-key');
    expect(saved.proxy, '127.0.0.1:7897');
    expect(saved.tmdbApiBase, 'https://tmdb-api.example.com/3');
    expect(saved.tmdbImageBase, 'https://tmdb-img.example.com/t/p');
    expect(saved.bangumiEnabled, isFalse);
    expect(localClient.tmdbImageBase, 'https://tmdb-img.example.com/t/p');
  });

  testWidgets('Sync mode ScraperSettingsScreen shows read-only sync metadata service view without local TMDB key', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final store = LibrarySettingsStore(db);
    final mounts = MountManager(MountRegistry(db));
    final repo = LibraryRepository(db);
    final runner = LibraryScrapeRunner(
      database: db,
      repository: repo,
      settings: store,
      mounts: mounts,
      resolveMetadataEndpoint: () async => (
        serverUrl: 'http://123.57.195.60:20001',
        accessToken: 'tok',
        isOfficial: false,
      ),
    );
    final sessionController = AppSessionController(db: db, mountManager: mounts);
    sessionController.debugSetStateForTesting(
      mode: AppLoginMode.selfHosted,
      selfHostedSession: SelfHostedSession(
        serverUrl: 'http://123.57.195.60:20001',
        username: 'alice',
        accessToken: 'tok',
        householdId: 'hh1',
        memberId: 'm1',
      ),
    );

    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      sessionController.dispose();
      await mounts.dispose();
      await db.close();
    });

    await tester.pumpWidget(
      TranslationProvider(
        child: InputModeTracker(
          child: MultiProvider(
            providers: [
              Provider<LibrarySettingsStore>.value(value: store),
              Provider<LibraryScrapeRunner>.value(value: runner),
              ChangeNotifierProvider<AppSessionController>.value(value: sessionController),
            ],
            child: const MaterialApp(home: ScraperSettingsScreen()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(t.storage.metadataServiceSelfHosted), findsOneWidget);
    expect(find.text('http://123.57.195.60:20001'), findsOneWidget);
    expect(find.text(t.storage.metadataServerTest), findsOneWidget);
    expect(find.text(t.storage.tmdbKey), findsNothing);
    expect(find.widgetWithText(FilledButton, t.common.save), findsNothing);
  });
}
