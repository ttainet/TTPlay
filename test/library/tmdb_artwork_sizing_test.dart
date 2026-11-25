import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ttplay/database/app_database.dart';
import 'package:ttplay/library/library_repository.dart';
import 'package:ttplay/library/local_library_client.dart';
import 'package:ttplay/library/scrapers/tmdb_image_url.dart';
import 'package:ttplay/storage/mount_manager.dart';
import 'package:ttplay/storage/mount_registry.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('TmdbImageUrl balanced sizing', () {
    test('selects cover buckets upward from target pixels without upscaling', () {
      expect(TmdbImageUrl.sizeForWidth(160), 'w185');
      expect(TmdbImageUrl.sizeForWidth(185), 'w185');
      expect(TmdbImageUrl.sizeForWidth(200), 'w342');
      expect(TmdbImageUrl.sizeForWidth(240), 'w342');
      expect(TmdbImageUrl.sizeForWidth(280), 'w500');
      expect(TmdbImageUrl.sizeForWidth(480), 'w500');
      expect(TmdbImageUrl.sizeForWidth(500), 'w500');
      expect(TmdbImageUrl.sizeForWidth(560), 'w780');
      expect(TmdbImageUrl.sizeForWidth(720), 'w780');
      expect(TmdbImageUrl.sizeForWidth(780), 'w780');
      expect(TmdbImageUrl.sizeForWidth(960), 'w1280');
      expect(TmdbImageUrl.sizeForWidth(1280), 'w1280');
      expect(TmdbImageUrl.sizeForWidth(1920), 'original');
      expect(TmdbImageUrl.sizeForWidth(null), 'w780');
    });

    test('uses higher buckets for backdrops (cover: false) and crisp PNG logos', () {
      expect(TmdbImageUrl.sizeForWidth(720, cover: false), 'w780');
      expect(TmdbImageUrl.sizeForWidth(1280, cover: false), 'w1280');
      expect(TmdbImageUrl.sizeForWidth(1920, cover: false), 'original');
      expect(TmdbImageUrl.sizeForWidth(3840, cover: false), 'original');
      expect(TmdbImageUrl.sizeForWidth(null, cover: false), 'w1280');

      expect(TmdbImageUrl.sizeForWidth(400, path: '/logo.png'), 'w500');
      expect(TmdbImageUrl.sizeForWidth(800, path: '/logo.png?x=1'), 'original');
      expect(TmdbImageUrl.sizeForWidth(null, path: '/logo.png'), 'w500');
    });

    test('replaceSize swaps /t/p/<size>/ in TMDB URLs and leaves non-TMDB URLs intact', () {
      expect(
        TmdbImageUrl.replaceSize('https://image.tmdb.org/t/p/w500/bg.jpg', 'original'),
        'https://image.tmdb.org/t/p/original/bg.jpg',
      );
      expect(
        TmdbImageUrl.replaceSize('https://mirror.example.com/tmdb/t/p/w342/poster.jpg', 'w780'),
        'https://mirror.example.com/tmdb/t/p/w780/poster.jpg',
      );
      expect(
        TmdbImageUrl.replaceSize('https://lain.bgm.tv/pic/cover/l/12.jpg', 'original'),
        'https://lain.bgm.tv/pic/cover/l/12.jpg',
      );
    });
  });

  group('LocalLibraryClient artwork size resolution', () {
    late AppDatabase db;
    late MountManager mounts;
    late LocalLibraryClient client;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      mounts = MountManager(MountRegistry(db));
      client = LocalLibraryClient(repository: LibraryRepository(db), mounts: mounts)
        ..metadataServerUrl = 'https://sync.example.com'
        ..metadataAccessToken = 'tok_123';
    });

    tearDown(() async {
      await mounts.dispose();
      await db.close();
    });

    test('injects dynamic TMDB size and token for synced /api/v1/metadata/artwork paths', () {
      final posterMid = Uri.parse(
        client.thumbnailUrl('/api/v1/metadata/artwork?src=%2Fposter.jpg', width: 480),
      );
      expect(posterMid.origin, 'https://sync.example.com');
      expect(posterMid.path, '/api/v1/metadata/artwork');
      expect(posterMid.queryParameters['src'], '/poster.jpg');
      expect(posterMid.queryParameters['size'], 'w500');
      expect(posterMid.queryParameters['token'], 'tok_123');

      final posterHigh = Uri.parse(
        client.thumbnailUrl('/api/v1/metadata/artwork?src=%2Fposter.jpg', width: 720),
      );
      expect(posterHigh.queryParameters['size'], 'w780');
      expect(posterHigh.queryParameters['token'], 'tok_123');

      final backdropOrig = Uri.parse(
        client.thumbnailUrl('/api/v1/metadata/artwork?src=%2Fbg.jpg', width: 1920, cover: false),
      );
      expect(backdropOrig.queryParameters['size'], 'original');
      expect(backdropOrig.queryParameters['token'], 'tok_123');

      final fallbackSize = Uri.parse(
        client.thumbnailUrl('/api/v1/metadata/artwork?src=%2Fposter.jpg'),
      );
      expect(fallbackSize.queryParameters['size'], 'w780');
      expect(fallbackSize.queryParameters['token'], 'tok_123');
    });

    test('detects PNG logo inside src query param without appending size to full external URLs', () {
      final logoSmall = Uri.parse(
        client.thumbnailUrl('/api/v1/metadata/artwork?src=%2Flogo.png', width: 400),
      );
      expect(logoSmall.queryParameters['size'], 'w500');

      final logoLarge = Uri.parse(
        client.thumbnailUrl('/api/v1/metadata/artwork?src=%2Flogo.png', width: 800, cover: false),
      );
      expect(logoLarge.queryParameters['size'], 'original');

      final bgm = Uri.parse(
        client.thumbnailUrl(
          '/api/v1/metadata/artwork?src=https%3A%2F%2Flain.bgm.tv%2Fpic%2Fa.jpg',
          width: 720,
        ),
      );
      expect(bgm.queryParameters['src'], 'https://lain.bgm.tv/pic/a.jpg');
      expect(bgm.queryParameters.containsKey('size'), isFalse);
      expect(bgm.queryParameters['token'], 'tok_123');
    });

    test('externalImageUrl upgrades pre-baked proxy URLs and direct TMDB URLs without leaking token', () {
      final offlineProxy = Uri.parse(
        client.externalImageUrl(
          'https://other-meta.example.com/api/v1/public/metadata/artwork?src=%2Fp.jpg&size=w500',
          width: 1920,
          cover: false,
        ),
      );
      expect(offlineProxy.origin, 'https://other-meta.example.com');
      expect(offlineProxy.queryParameters['size'], 'original');
      expect(offlineProxy.queryParameters.containsKey('token'), isFalse);

      final foreignAuthProxy = Uri.parse(
        client.externalImageUrl(
          'https://other-meta.example.com/api/v1/metadata/artwork?src=%2Fp.jpg',
          width: 720,
        ),
      );
      expect(foreignAuthProxy.queryParameters['size'], 'w780');
      expect(foreignAuthProxy.queryParameters.containsKey('token'), isFalse);

      expect(
        client.externalImageUrl(
          'https://image.tmdb.org/t/p/w500/bg.jpg',
          width: 1920,
          cover: false,
        ),
        'https://image.tmdb.org/t/p/original/bg.jpg',
      );
    });

    test('leaves sidecar paths untouched', () {
      expect(
        client.thumbnailUrl('/api/v1/sidecars/123', width: 720),
        'https://sync.example.com/api/v1/sidecars/123',
      );
    });
  });
}
