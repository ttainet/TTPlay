import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ttplay/i18n/strings.g.dart';
import 'package:ttplay/media/media_item.dart';
import 'package:ttplay/media/media_kind.dart';
import 'package:ttplay/services/online_subtitle_store.dart';
import 'package:ttplay/services/subtitle_search/online_subtitle_models.dart';
import 'package:ttplay/services/subtitle_search/online_subtitle_service.dart';
import 'package:ttplay/utils/platform_detector.dart';
import 'package:ttplay/widgets/overlay_sheet.dart';
import 'package:ttplay/widgets/video_controls/models/track_controls_state.dart';
import 'package:ttplay/widgets/video_controls/sheets/subtitle_search_sheet.dart';

import '../test_helpers/theme.dart';

class _InMemoryOnlineSubtitleStore implements OnlineSubtitleStore {
  final List<CachedOnlineSubtitle> _rows = [];
  int _nextId = 1;

  @override
  Future<CachedOnlineSubtitle> saveAndSelect({
    required String itemGlobalKey,
    String? mediaSourceId,
    required String provider,
    required String remoteId,
    required String title,
    String? language,
    required String format,
    required String sha256,
    required String contentUtf8,
  }) async {
    for (var i = 0; i < _rows.length; i++) {
      if (_rows[i].itemGlobalKey == itemGlobalKey) {
        _rows[i] = _copyWithSelected(_rows[i], false);
      }
    }
    final created = CachedOnlineSubtitle(
      id: _nextId++,
      itemGlobalKey: itemGlobalKey,
      mediaSourceId: mediaSourceId,
      provider: provider,
      remoteId: remoteId,
      title: title,
      language: language,
      format: format,
      relativePath: '$sha256.$format',
      absPath: '/tmp/online_subtitles/$sha256.$format',
      sha256: sha256,
      isSelected: true,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    _rows.add(created);
    return created;
  }

  @override
  Future<List<CachedOnlineSubtitle>> listForItem(String itemGlobalKey, {String? mediaSourceId}) async {
    return _rows.where((r) => r.itemGlobalKey == itemGlobalKey).toList();
  }

  @override
  Future<Map<String, CachedOnlineSubtitle>> findCachedRemoteIds(String itemGlobalKey, {String? mediaSourceId}) async {
    final items = await listForItem(itemGlobalKey, mediaSourceId: mediaSourceId);
    return {for (final item in items) item.cacheIdentity: item};
  }

  @override
  Future<void> markSelected(int rowId, {required String itemGlobalKey, String? mediaSourceId}) async {
    for (var i = 0; i < _rows.length; i++) {
      if (_rows[i].itemGlobalKey == itemGlobalKey) {
        _rows[i] = _copyWithSelected(_rows[i], _rows[i].id == rowId);
      }
    }
  }

  @override
  Future<void> clearSelection(String itemGlobalKey, {String? mediaSourceId}) async {
    for (var i = 0; i < _rows.length; i++) {
      if (_rows[i].itemGlobalKey == itemGlobalKey) {
        _rows[i] = _copyWithSelected(_rows[i], false);
      }
    }
  }

  @override
  Future<void> delete(int rowId) async {
    _rows.removeWhere((r) => r.id == rowId);
  }

  static CachedOnlineSubtitle _copyWithSelected(CachedOnlineSubtitle s, bool selected) => CachedOnlineSubtitle(
    id: s.id,
    itemGlobalKey: s.itemGlobalKey,
    mediaSourceId: s.mediaSourceId,
    provider: s.provider,
    remoteId: s.remoteId,
    title: s.title,
    language: s.language,
    format: s.format,
    relativePath: s.relativePath,
    absPath: s.absPath,
    sha256: s.sha256,
    isSelected: selected,
    createdAt: s.createdAt,
  );
}

void main() {
  group('resolveSubtitleSearchLanguageCode', () {
    test('prefers saved language over system language', () {
      expect(resolveSubtitleSearchLanguageCode(savedLanguageCode: 'fr', systemLocale: const Locale('nl')), 'fr');
    });

    test('normalizes saved locale or three-letter language', () {
      expect(resolveSubtitleSearchLanguageCode(savedLanguageCode: 'pt_BR', systemLocale: const Locale('nl')), 'pt');
      expect(resolveSubtitleSearchLanguageCode(savedLanguageCode: 'eng', systemLocale: const Locale('nl')), 'en');
    });

    test('falls back to system language when saved language is invalid', () {
      expect(resolveSubtitleSearchLanguageCode(savedLanguageCode: 'zz', systemLocale: const Locale('nl')), 'nl');
    });

    test('falls back to English when saved and system languages are invalid', () {
      expect(resolveSubtitleSearchLanguageCode(savedLanguageCode: 'zz', systemLocale: const Locale('xx')), 'en');
    });
  });

  group('sheet geometry', () {
    setUp(() {
      LocaleSettings.setLocaleSync(AppLocale.en);
      // The 720 assertion below is the desktop-window ceiling, so pin both
      // gates it reads rather than inheriting the host OS.
      PlatformDetector.debugSetIsDesktopOSOverride(true);
      TvDetectionService.debugSetAppleTVOverride(false);
    });

    tearDown(() {
      PlatformDetector.debugSetIsDesktopOSOverride(null);
      TvDetectionService.debugSetAppleTVOverride(null);
    });

    testWidgets('search body keeps a stable height so the focused field cannot slide', (tester) async {
      tester.view.physicalSize = const Size(1280, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await _pumpSearchSheet(tester);

      final emptyHeight = _sheetHeight(tester);
      final fieldTop = tester.getTopLeft(find.byType(TextField)).dy;
      expect(emptyHeight, 720, reason: 'search surface fills the windowed height ceiling');

      // Switching to the language picker and filtering it down to a couple of
      // matches must not move the geometry either.
      await tester.tap(find.text('English'));
      await tester.pumpAndSettle();
      expect(_sheetHeight(tester), emptyHeight);

      await tester.enterText(find.byType(TextField), 'zulu');
      await tester.pumpAndSettle();
      expect(find.text('Zulu'), findsOneWidget);
      expect(_sheetHeight(tester), emptyHeight, reason: 'per-keystroke match count must not resize the sheet');
      expect(tester.getTopLeft(find.byType(TextField)).dy, fieldTop);
    });
  });

  group('online search & cache contract', () {
    late _InMemoryOnlineSubtitleStore store;

    setUp(() {
      LocaleSettings.setLocaleSync(AppLocale.en);
      store = _InMemoryOnlineSubtitleStore();
    });

    testWidgets('HTTP 500 from search shows the sheet error state, not "no subtitles found"', (tester) async {
      final service = OnlineSubtitleService(client: MockClient((_) async => http.Response('{}', 500)));

      await _pumpSearchSheet(
        tester,
        service: service,
        store: store,
        serverConfig: const OnlineSubtitleServerConfig(serverUrl: 'https://lib.example.com'),
      );

      expect(find.text(t.errors.searchFailed(error: t.errors.reasonServerError)), findsOneWidget);
      expect(find.textContaining('HTTP 500'), findsNothing);
      expect(find.text(t.videoControls.noSubtitlesFound), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('download failure to apply surfaces timedOut error text', (tester) async {
      final service = OnlineSubtitleService(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/subtitles/search')) {
            return http.Response(
              jsonEncode({
                'code': 0,
                'enabled_providers': ['xunlei'],
                'candidates': [
                  {
                    'id': '1',
                    'provider': 'xunlei',
                    'title': 'Film.2024.srt',
                    'language': 'en',
                    'format': 'srt',
                    'download_token': 'tok-1',
                  },
                ],
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'code': 0,
              'provider': 'xunlei',
              'filename': 'Film.2024.srt',
              'format': 'srt',
              'language': 'en',
              'sha256': 'f' * 64,
              'content': '1\n00:00:01,000 --> 00:00:02,000\nHi\n',
            }),
            200,
          );
        }),
      );

      await _pumpSearchSheet(
        tester,
        service: service,
        store: store,
        serverConfig: const OnlineSubtitleServerConfig(serverUrl: 'https://lib.example.com'),
        onOnlineSubtitleApplied: (_) async => SubtitleDownloadApplyOutcome.timedOut,
      );

      await tester.tap(find.text('Film.2024.srt'));
      await tester.pumpAndSettle();

      expect(find.text(t.videoControls.subtitleDownloadTimedOut), findsOneWidget);
      expect(find.text(t.videoControls.subtitleDownloadedNotApplied), findsNothing);
    });

    testWidgets('cached candidate skips /download and applies immediately', (tester) async {
      await store.saveAndSelect(
        itemGlobalKey: 'local-library:7',
        provider: 'subdl',
        remoteId: 'cached-99',
        title: 'Cached.2024.ass',
        language: 'en',
        format: 'ass',
        sha256: '1' * 64,
        contentUtf8: '[Script Info]\nTitle: Cached',
      );

      var downloadCalls = 0;
      final service = OnlineSubtitleService(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/subtitles/download')) {
            downloadCalls++;
          }
          return http.Response(
            jsonEncode({
              'code': 0,
              'enabled_providers': ['subdl'],
              'candidates': [
                {
                  'id': 'cached-99',
                  'provider': 'subdl',
                  'title': 'Cached.2024.ass',
                  'language': 'en',
                  'format': 'ass',
                  'download_token': 'tok-99',
                },
              ],
            }),
            200,
          );
        }),
      );

      CachedOnlineSubtitle? applied;
      await _pumpSearchSheet(
        tester,
        metadata: MediaItem.jellyfin(id: '7', kind: MediaKind.movie, title: 'Cached Movie', serverId: 'local-library'),
        service: service,
        store: store,
        serverConfig: const OnlineSubtitleServerConfig(serverUrl: 'https://lib.example.com'),
        onOnlineSubtitleApplied: (sub) async {
          applied = sub;
          return SubtitleDownloadApplyOutcome.applied;
        },
      );

      expect(find.text(t.videoControls.subtitleCached), findsOneWidget);
      await tester.tap(find.text('Cached.2024.ass'));
      await tester.pumpAndSettle();

      expect(downloadCalls, 0);
      expect(applied?.remoteId, 'cached-99');
      expect(find.text(t.videoControls.subtitleDownloaded), findsOneWidget);
    });
  });
}

/// Height of the sheet box the host lays out, i.e. what the user sees.
double _sheetHeight(WidgetTester tester) {
  return tester.getSize(find.descendant(of: find.byType(OverlaySheetHost), matching: find.byType(AnimatedSize))).height;
}

Future<void> _pumpSearchSheet(
  WidgetTester tester, {
  MediaItem? metadata,
  OnlineSubtitleService? service,
  OnlineSubtitleStore? store,
  OnlineSubtitleServerConfig? serverConfig,
  Future<SubtitleDownloadApplyOutcome> Function(CachedOnlineSubtitle subtitle)? onOnlineSubtitleApplied,
}) async {
  final app = MaterialApp(
    theme: ThemeData(extensions: const [testMonoTokens]),
    home: OverlaySheetHost(
      child: Builder(
        builder: (context) => Scaffold(
          body: ElevatedButton(
            onPressed: () => OverlaySheetController.of(context).show<void>(
              builder: (_) => SubtitleSearchSheet(
                metadata: metadata,
                mediaTitle: metadata?.title ?? 'Film',
                subtitleService: service,
                subtitleStore: store,
                serverConfig: serverConfig,
                onOnlineSubtitleApplied: onOnlineSubtitleApplied,
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
  await tester.pumpWidget(app);
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}
