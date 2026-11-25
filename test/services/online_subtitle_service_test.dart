import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ttplay/database/app_database.dart';
import 'package:ttplay/exceptions/media_server_exceptions.dart';
import 'package:ttplay/media/media_item.dart';
import 'package:ttplay/media/media_kind.dart';
import 'package:ttplay/services/jellyfin_api_cache.dart';
import 'package:ttplay/services/online_subtitle_store.dart';
import 'package:ttplay/services/subtitle_search/online_subtitle_models.dart';
import 'package:ttplay/services/subtitle_search/online_subtitle_service.dart';
import 'package:ttplay/utils/external_ids.dart';

import '../test_helpers/backend_client_fixtures.dart';

void main() {
  group('OnlineSubtitleService.buildQuery', () {
    test('uses series-level external IDs for episodes', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      JellyfinApiCache.initialize(db);
      addTearDown(db.close);
      final client = testJellyfinClient(
        handler: (request) async {
          if (request.url.path.contains('/Items/show-1')) {
            return http.Response(
              jsonEncode({
                'Id': 'show-1',
                'Name': 'Severance',
                'Type': 'Series',
                'ProviderIds': {'Imdb': 'tt11280740', 'Tmdb': '95396'},
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response(
            jsonEncode({
              'Id': 'ep-1',
              'Name': 'Good News About Hell',
              'Type': 'Episode',
              'ProviderIds': {'Imdb': 'tt14500001'},
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        },
      );

      final ep = MediaItem.jellyfin(
        id: 'ep-1',
        kind: MediaKind.episode,
        title: 'Good News About Hell',
        grandparentId: 'show-1',
        grandparentTitle: 'Severance',
        parentIndex: 1,
        index: 1,
        serverId: client.serverId.value,
      );

      final query = await OnlineSubtitleService.buildQuery(
        metadata: ep,
        client: client,
        activeFilePath: '/media/Severance.S01E01.1080p.mkv',
        language: 'zh',
      );

      expect(query.kind, 'episode');
      expect(query.showTitle, 'Severance');
      expect(query.season, 1);
      expect(query.episode, 1);
      expect(query.imdbId, 'tt11280740');
      expect(query.tmdbId, '95396');
      expect(query.fileName, 'Severance.S01E01.1080p.mkv');
      expect(ExternalIds.fromJellyfinProviderIds({'Imdb': 'tt11280740'}).imdb, 'tt11280740');
    });
  });

  group('OnlineSubtitleService HTTP', () {
    test('routes authenticated vs public endpoints and caches downloaded subtitle', () async {
      final seenRequests = <Uri>[];
      final seenAuth = <String?>[];
      final mockClient = MockClient((request) async {
        seenRequests.add(request.url);
        seenAuth.add(request.headers['Authorization']);
        if (request.url.path.endsWith('/subtitles/search')) {
          return http.Response(
            jsonEncode({
              'code': 0,
              'enabled_providers': ['xunlei', 'subdl'],
              'candidates': [
                {
                  'id': 'c1',
                  'provider': 'xunlei',
                  'title': 'Movie.2024.chs.ass',
                  'language': 'zh',
                  'format': 'ass',
                  'perfect_match': true,
                  'downloads': 42,
                  'download_token': 'tok-1',
                },
              ],
            }),
            200,
          );
        }
        if (request.url.path.endsWith('/subtitles/download')) {
          return http.Response(
            jsonEncode({
              'code': 0,
              'provider': 'xunlei',
              'filename': 'Movie.2024.chs.ass',
              'format': 'ass',
              'language': 'zh',
              'sha256': 'e' * 64,
              'content': '[Script Info]\nTitle: Cached',
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      });

      final service = OnlineSubtitleService(client: mockClient);
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final tempRoot = await Directory.systemTemp.createTemp('ttplay_sub_svc_');
      addTearDown(() async {
        await db.close();
        if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
      });
      final store = OnlineSubtitleStore(db, rootDirResolver: () async => tempRoot);

      final endpoint = const OnlineSubtitleServerConfig(serverUrl: 'https://lib.example.com', accessToken: 'tok-abc');
      final searchRes = await service.search(
        endpoint,
        const OnlineSubtitleQuery(itemGlobalKey: 'local-library:1', title: 'Movie', kind: 'movie', language: 'zh'),
      );
      expect(seenRequests.first.path, '/api/v1/subtitles/search');
      expect(seenAuth.first, 'Bearer tok-abc');
      expect(searchRes.candidates, hasLength(1));
      expect(searchRes.enabledProviders, ['xunlei', 'subdl']);

      final saved = await service.downloadAndCache(
        endpoint,
        candidate: searchRes.candidates.first,
        itemGlobalKey: 'local-library:1',
        store: store,
      );
      expect(seenRequests.last.path, '/api/v1/subtitles/download');
      expect(File(saved.absPath).readAsStringSync(), '[Script Info]\nTitle: Cached');
      expect(saved.isSelected, isTrue);
    });

    test('maps HTTP 500 to MediaServerHttpException', () async {
      final mockClient = MockClient((_) async => http.Response('{"message":"upstream down"}', 500));
      final service = OnlineSubtitleService(client: mockClient);
      const endpoint = OnlineSubtitleServerConfig(serverUrl: 'https://lib.example.com');

      await expectLater(
        service.search(
          endpoint,
          const OnlineSubtitleQuery(itemGlobalKey: 'k1', title: 'Test', kind: 'movie', language: 'en'),
        ),
        throwsA(isA<MediaServerHttpException>().having((e) => e.statusCode, 'statusCode', 500)),
      );
    });
  });
}
