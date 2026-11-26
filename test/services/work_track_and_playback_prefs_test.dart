import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ttplay/database/app_database.dart';
import 'package:ttplay/library/library_repository.dart';
import 'package:ttplay/library/local_library_client.dart';
import 'package:ttplay/media/media_item.dart';
import 'package:ttplay/media/media_kind.dart';
import 'package:ttplay/media/playback_rate.dart';
import 'package:ttplay/media/work_identity.dart';
import 'package:ttplay/mpv/mpv.dart';
import 'package:ttplay/services/scoped_player_prefs.dart';
import 'package:ttplay/services/subtitle_preference.dart';
import 'package:ttplay/services/sync_config_store.dart';
import 'package:ttplay/services/track_selection_service.dart';
import 'package:ttplay/services/work_playback_prefs_store.dart';
import 'package:ttplay/services/work_track_prefs_store.dart';

class _RecordingCloudKvBridge extends LocalCloudUserDataBridge {
  final puts = <({String scope, String namespace, String key, Map<String, dynamic> value, String? workKey})>[];
  final deletes = <({String scope, String namespace, String key})>[];

  @override
  Future<void> pushProgress({
    required String workKey,
    int seasonNumber = 0,
    int episodeNumber = 0,
    required int positionMs,
    int? durationMs,
    bool? watched,
  }) async {}

  @override
  Future<void> pushFavorite({required String workKey, required bool isFavorite}) async {}

  @override
  Future<void> pushHideContinue({required String workKey, int seasonNumber = 0, int episodeNumber = 0}) async {}

  @override
  Future<void> putCloudKv({
    required String scope,
    required String namespace,
    required String key,
    required Map<String, dynamic> value,
    String? workKey,
  }) async {
    puts.add((scope: scope, namespace: namespace, key: key, value: value, workKey: workKey));
  }

  @override
  Future<void> deleteCloudKv({required String scope, required String namespace, required String key}) async {
    deletes.add((scope: scope, namespace: namespace, key: key));
  }
}

void main() {
  late AppDatabase db;
  late _RecordingCloudKvBridge bridge;
  late SyncConfigStore syncStore;
  late WorkTrackPrefsStore trackStore;
  late WorkPlaybackPrefsStore playbackStore;

  late int movieItemId;
  late int episodeItemId;
  late int unmatchedItemId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    bridge = _RecordingCloudKvBridge();
    syncStore = SyncConfigStore(db, cloudBridge: bridge);
    trackStore = WorkTrackPrefsStore(db, syncConfigStore: syncStore);
    playbackStore = WorkPlaybackPrefsStore(db, syncConfigStore: syncStore);

    final now = DateTime.now().millisecondsSinceEpoch;
    movieItemId = await db
        .into(db.libraryItems)
        .insert(
          LibraryItemsCompanion.insert(
            workKey: const Value('tmdb:movie:603'),
            kind: LibraryKinds.movie,
            libraryType: LibraryTypes.movie,
            title: 'The Matrix',
            sortTitle: 'the matrix',
            tmdbId: const Value('603'),
            scrapedAt: Value(now),
            addedAt: now,
            updatedAt: now,
          ),
        );
    final showId = await db
        .into(db.libraryItems)
        .insert(
          LibraryItemsCompanion.insert(
            workKey: const Value('tmdb:show:94605'),
            kind: LibraryKinds.show,
            libraryType: LibraryTypes.show,
            title: 'Arcane',
            sortTitle: 'arcane',
            tmdbId: const Value('94605'),
            scrapedAt: Value(now),
            addedAt: now,
            updatedAt: now,
          ),
        );
    episodeItemId = await db
        .into(db.libraryItems)
        .insert(
          LibraryItemsCompanion.insert(
            workKey: const Value('tmdb:show:94605:s1:e1'),
            kind: LibraryKinds.episode,
            libraryType: LibraryTypes.show,
            parentId: Value(showId),
            showId: Value(showId),
            seasonNumber: const Value(1),
            episodeNumber: const Value(1),
            title: 'Pilot',
            sortTitle: 'pilot',
            addedAt: now,
            updatedAt: now,
          ),
        );
    unmatchedItemId = await db
        .into(db.libraryItems)
        .insert(
          LibraryItemsCompanion.insert(
            kind: LibraryKinds.movie,
            libraryType: LibraryTypes.movie,
            title: 'Home Video',
            sortTitle: 'home video',
            addedAt: now,
            updatedAt: now,
          ),
        );
  });

  tearDown(() async {
    syncStore.dispose();
    await db.close();
  });

  MediaItem localMovie() => MediaItem.jellyfin(
    id: '$movieItemId',
    kind: MediaKind.movie,
    title: 'The Matrix',
    serverId: WorkIdentity.localSource,
  );

  MediaItem localEpisode() => MediaItem.jellyfin(
    id: '$episodeItemId',
    kind: MediaKind.episode,
    title: 'Pilot',
    serverId: WorkIdentity.localSource,
  );

  MediaItem unmatchedLocal() => MediaItem.jellyfin(
    id: '$unmatchedItemId',
    kind: MediaKind.movie,
    title: 'Home Video',
    serverId: WorkIdentity.localSource,
  );

  MediaItem embyItem() =>
      MediaItem.jellyfin(id: 'emby-1', kind: MediaKind.movie, title: 'External', serverId: 'emby-srv');

  test('WorkTrackPrefsStore merges audio/subtitle per work, resolves episode to show, and converts intents', () async {
    final ep = localEpisode();
    expect(
      await trackStore.saveAudioForItem(
        ep,
        const AudioTrack(id: '1', language: 'ja', title: 'Japanese 5.1', codec: 'aac', channels: 6),
      ),
      isTrue,
    );
    expect(bridge.puts.single.namespace, 'work.tracks');
    expect(bridge.puts.single.key, 'tmdb:show:94605');
    expect(bridge.puts.single.workKey, 'tmdb:show:94605');

    expect(
      await trackStore.saveSubtitleForItem(
        ep,
        const SubtitleTrack(id: '2', language: 'zh', title: 'CHS', codec: 'ass', isExternal: true),
      ),
      isTrue,
    );

    final loaded = await trackStore.readForItem(ep);
    expect(loaded, isNotNull);
    final prefAudio = loaded!.toPreferredAudioTrack()!;
    expect(prefAudio.id, carriedAudioTrackId);
    expect(prefAudio.language, 'ja');
    expect(prefAudio.channels, 6);

    final prefSub = loaded.toSubtitlePreference() as SubtitleIntentPreference;
    expect(prefSub.intent.language, 'zh');
    expect(prefSub.intent.title, 'CHS');
    expect(prefSub.intent.codec, 'ass');
    expect(prefSub.intent.isExternal, isTrue);

    // Selecting subtitle Off keeps audio intact and yields SubtitleOffPreference.
    await trackStore.saveSubtitleForItem(ep, SubtitleTrack.off);
    final loadedOff = await trackStore.readForItem(ep);
    expect(loadedOff!.audioLang, 'ja');
    expect(loadedOff.toSubtitlePreference(), const SubtitlePreference.off());

    // Emby and unmatched local items do not resolve/write.
    expect(await trackStore.saveAudioForItem(unmatchedLocal(), const AudioTrack(id: '1', language: 'en')), isFalse);
    expect(await trackStore.saveAudioForItem(embyItem(), const AudioTrack(id: '1', language: 'en')), isFalse);
  });

  test('WorkPlaybackPrefsStore persists speed & subtitle offset per work and deletes on reset to default', () async {
    final movie = localMovie();
    final ep = localEpisode();

    // Speed save, clamp, and reset to 1.0x
    expect(await playbackStore.saveSpeedForItem(ep, 1.5), isTrue);
    expect(await playbackStore.readSpeedForItem(ep), 1.5);
    expect(await playbackStore.readSpeedForItem(movie), isNull);
    expect(bridge.puts.last.namespace, 'work.speed');
    expect(bridge.puts.last.key, 'tmdb:show:94605');

    await playbackStore.saveSpeedForItem(movie, 99.0);
    expect(await playbackStore.readSpeedForItem(movie), maximumPlaybackRate);

    expect(await playbackStore.saveSpeedForItem(ep, 1.0), isTrue);
    expect(await playbackStore.readSpeedForItem(ep), isNull);
    expect(bridge.deletes.single, (scope: 'member', namespace: 'work.speed', key: 'tmdb:show:94605'));

    // Subtitle offset save, clamp, and reset to 0
    expect(await playbackStore.saveSubtitleOffsetForItem(movie, -1250), isTrue);
    expect(await playbackStore.readSubtitleOffsetForItem(movie), -1250);
    expect(bridge.puts.last.namespace, 'work.sub_offset');

    await playbackStore.saveSubtitleOffsetForItem(movie, 999999);
    expect(await playbackStore.readSubtitleOffsetForItem(movie), ScopedPlayerPrefs.maximumSyncOffsetMs);

    expect(await playbackStore.saveSubtitleOffsetForItem(movie, 0), isTrue);
    expect(await playbackStore.readSubtitleOffsetForItem(movie), isNull);
    expect(bridge.deletes.last, (scope: 'member', namespace: 'work.sub_offset', key: 'tmdb:movie:603'));

    // Unmatched or external items return false so callers fall back to ScopedPlayerPrefs
    expect(await playbackStore.saveSpeedForItem(unmatchedLocal(), 1.25), isFalse);
    expect(await playbackStore.saveSubtitleOffsetForItem(embyItem(), 500), isFalse);
  });
}
