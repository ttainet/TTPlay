import '../database/app_database.dart';
import '../library/library_watch_state_store.dart';
import '../media/media_item.dart';
import '../media/playback_rate.dart';
import '../media/work_identity.dart';
import '../models/sync_config_entry.dart';
import 'scoped_player_prefs.dart';
import 'sync_config_store.dart';
import 'work_skip_settings_store.dart';

/// Reads and writes member-scoped per-work playback speed (`member / work.speed`)
/// and subtitle sync offset (`member / work.sub_offset`) for `local-library` works.
/// Audio sync offset remains strictly device-local via [ScopedPlayerPrefs].
class WorkPlaybackPrefsStore {
  WorkPlaybackPrefsStore(this.db, {SyncConfigStore? syncConfigStore})
    : _syncConfigStore = syncConfigStore ?? SyncConfigStore(db);

  final AppDatabase db;
  final SyncConfigStore _syncConfigStore;

  static final SyncConfigSpec<double> speedSpec = SyncConfigSpec<double>(
    scope: SyncConfigScope.member,
    namespace: SyncConfigNamespaces.workSpeed,
    encode: (value) => <String, dynamic>{'speed': value},
    decode: (json) => (json['speed'] as num?)?.toDouble() ?? 1.0,
    isValid: (value) => value.isFinite && value >= minimumPlaybackRate && value <= maximumPlaybackRate,
  );

  static final SyncConfigSpec<int> subtitleOffsetSpec = SyncConfigSpec<int>(
    scope: SyncConfigScope.member,
    namespace: SyncConfigNamespaces.workSubOffset,
    encode: (value) => <String, dynamic>{'offsetMs': value},
    decode: (json) => (json['offsetMs'] as num?)?.round() ?? 0,
    isValid: (value) =>
        value >= ScopedPlayerPrefs.minimumSyncOffsetMs && value <= ScopedPlayerPrefs.maximumSyncOffsetMs,
  );

  Future<WorkIdentity?> resolve(MediaItem item) async {
    if (item.serverId != WorkIdentity.localSource || !WorkSkipSettingsStore.supports(item)) {
      return null;
    }
    final id = int.tryParse(item.id);
    if (id == null) return null;
    return LibraryWatchStateStore(db).resolveWork(id);
  }

  Future<double?> readSpeedForItem(MediaItem item) async {
    final work = await resolve(item);
    if (work == null) return null;
    return _syncConfigStore.read(speedSpec, work.cloudWorkKey);
  }

  /// Persists [speed] per work for matched `local-library` items. Returns `false`
  /// when [item] is not a matched local-library work so callers can fall back to
  /// [ScopedPlayerPrefs]. Resetting back to `1.0x` deletes the entry and syncs deletion.
  Future<bool> saveSpeedForItem(MediaItem item, double speed, {bool syncToCloud = true}) async {
    if (!speed.isFinite) return false;
    final work = await resolve(item);
    if (work == null) return false;

    final clamped = speed.clamp(minimumPlaybackRate, maximumPlaybackRate).toDouble();
    if ((clamped - 1.0).abs() < 0.001) {
      await _syncConfigStore.delete(
        scope: speedSpec.scope,
        namespace: speedSpec.namespace,
        itemKey: work.cloudWorkKey,
        syncToCloud: syncToCloud,
      );
      return true;
    }

    await _syncConfigStore.write(
      speedSpec,
      work.cloudWorkKey,
      clamped,
      workKey: work.cloudWorkKey,
      syncToCloud: syncToCloud,
    );
    return true;
  }

  Future<int?> readSubtitleOffsetForItem(MediaItem item) async {
    final work = await resolve(item);
    if (work == null) return null;
    return _syncConfigStore.read(subtitleOffsetSpec, work.cloudWorkKey);
  }

  /// Persists [offsetMs] per work for matched `local-library` items. Returns
  /// `false` when [item] is not a matched local-library work so callers can fall
  /// back to [ScopedPlayerPrefs]. Resetting to `0` deletes the entry and syncs deletion.
  Future<bool> saveSubtitleOffsetForItem(MediaItem item, int offsetMs, {bool syncToCloud = true}) async {
    final work = await resolve(item);
    if (work == null) return false;

    final clamped = offsetMs.clamp(ScopedPlayerPrefs.minimumSyncOffsetMs, ScopedPlayerPrefs.maximumSyncOffsetMs);
    if (clamped == 0) {
      await _syncConfigStore.delete(
        scope: subtitleOffsetSpec.scope,
        namespace: subtitleOffsetSpec.namespace,
        itemKey: work.cloudWorkKey,
        syncToCloud: syncToCloud,
      );
      return true;
    }

    await _syncConfigStore.write(
      subtitleOffsetSpec,
      work.cloudWorkKey,
      clamped,
      workKey: work.cloudWorkKey,
      syncToCloud: syncToCloud,
    );
    return true;
  }
}
