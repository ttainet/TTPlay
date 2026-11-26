import '../database/app_database.dart';
import '../library/library_watch_state_store.dart';
import '../media/media_item.dart';
import '../media/work_identity.dart';
import '../models/sync_config_entry.dart';
import '../mpv/mpv.dart';
import 'subtitle_preference.dart';
import 'sync_config_store.dart';
import 'track_selection_service.dart';
import 'work_skip_settings_store.dart';

/// Semantic audio/subtitle track preference stored per work for `local-library`.
/// Values describe language/codec/title/forced intent rather than file-specific
/// stream IDs so preferences carry seamlessly across episodes, versions, and devices.
class WorkTrackPrefs {
  const WorkTrackPrefs({
    this.audioLang,
    this.audioTitle,
    this.audioCodec,
    this.audioChannels,
    this.subtitleLang,
    this.subtitleTitle,
    this.subtitleCodec,
    this.subtitleForced = false,
    this.subtitleIsExternal = false,
    this.subtitleOff = false,
  });

  final String? audioLang;
  final String? audioTitle;
  final String? audioCodec;
  final int? audioChannels;

  final String? subtitleLang;
  final String? subtitleTitle;
  final String? subtitleCodec;
  final bool subtitleForced;
  final bool subtitleIsExternal;
  final bool subtitleOff;

  bool get hasAudio =>
      (audioLang?.isNotEmpty ?? false) || (audioTitle?.isNotEmpty ?? false) || (audioCodec?.isNotEmpty ?? false);

  bool get hasSubtitle =>
      subtitleOff ||
      (subtitleLang?.isNotEmpty ?? false) ||
      (subtitleTitle?.isNotEmpty ?? false) ||
      (subtitleCodec?.isNotEmpty ?? false);

  bool get isEmpty => !hasAudio && !hasSubtitle;

  AudioTrack? toPreferredAudioTrack() {
    if (!hasAudio) return null;
    return AudioTrack(
      id: carriedAudioTrackId,
      language: audioLang,
      title: audioTitle,
      codec: audioCodec,
      channels: audioChannels,
    );
  }

  SubtitlePreference? toSubtitlePreference() {
    if (subtitleOff) return const SubtitlePreference.off();
    if (!hasSubtitle) return null;
    return SubtitlePreference.intent(
      SubtitleIntent(
        language: subtitleLang,
        forced: subtitleForced,
        title: subtitleTitle,
        codec: subtitleCodec,
        isExternal: subtitleIsExternal,
      ),
    );
  }

  WorkTrackPrefs copyWithAudio({String? audioLang, String? audioTitle, String? audioCodec, int? audioChannels}) =>
      WorkTrackPrefs(
        audioLang: audioLang,
        audioTitle: audioTitle,
        audioCodec: audioCodec,
        audioChannels: audioChannels,
        subtitleLang: subtitleLang,
        subtitleTitle: subtitleTitle,
        subtitleCodec: subtitleCodec,
        subtitleForced: subtitleForced,
        subtitleIsExternal: subtitleIsExternal,
        subtitleOff: subtitleOff,
      );

  WorkTrackPrefs copyWithSubtitle({
    String? subtitleLang,
    String? subtitleTitle,
    String? subtitleCodec,
    bool subtitleForced = false,
    bool subtitleIsExternal = false,
    bool subtitleOff = false,
  }) => WorkTrackPrefs(
    audioLang: audioLang,
    audioTitle: audioTitle,
    audioCodec: audioCodec,
    audioChannels: audioChannels,
    subtitleLang: subtitleLang,
    subtitleTitle: subtitleTitle,
    subtitleCodec: subtitleCodec,
    subtitleForced: subtitleForced,
    subtitleIsExternal: subtitleIsExternal,
    subtitleOff: subtitleOff,
  );

  factory WorkTrackPrefs.fromJson(Map<String, dynamic> json) => WorkTrackPrefs(
    audioLang: _nonEmpty(json['audioLang']),
    audioTitle: _nonEmpty(json['audioTitle']),
    audioCodec: _nonEmpty(json['audioCodec']),
    audioChannels: (json['audioChannels'] as num?)?.toInt(),
    subtitleLang: _nonEmpty(json['subtitleLang']),
    subtitleTitle: _nonEmpty(json['subtitleTitle']),
    subtitleCodec: _nonEmpty(json['subtitleCodec']),
    subtitleForced: json['subtitleForced'] == true,
    subtitleIsExternal: json['subtitleExternal'] == true,
    subtitleOff: json['subtitleOff'] == true,
  );

  Map<String, dynamic> toJson() => {
    if (audioLang != null && audioLang!.isNotEmpty) 'audioLang': audioLang,
    if (audioTitle != null && audioTitle!.isNotEmpty) 'audioTitle': audioTitle,
    if (audioCodec != null && audioCodec!.isNotEmpty) 'audioCodec': audioCodec,
    if (audioChannels != null && audioChannels! > 0) 'audioChannels': audioChannels,
    if (subtitleLang != null && subtitleLang!.isNotEmpty) 'subtitleLang': subtitleLang,
    if (subtitleTitle != null && subtitleTitle!.isNotEmpty) 'subtitleTitle': subtitleTitle,
    if (subtitleCodec != null && subtitleCodec!.isNotEmpty) 'subtitleCodec': subtitleCodec,
    if (subtitleForced) 'subtitleForced': true,
    if (subtitleIsExternal) 'subtitleExternal': true,
    if (subtitleOff) 'subtitleOff': true,
  };

  static String? _nonEmpty(Object? raw) {
    if (raw is! String) return null;
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

/// Reads and writes member-scoped semantic track preferences (`member / work.tracks`)
/// for `local-library` matched works via [SyncConfigStore].
class WorkTrackPrefsStore {
  WorkTrackPrefsStore(this.db, {SyncConfigStore? syncConfigStore})
    : _syncConfigStore = syncConfigStore ?? SyncConfigStore(db);

  final AppDatabase db;
  final SyncConfigStore _syncConfigStore;

  static final SyncConfigSpec<WorkTrackPrefs> spec = SyncConfigSpec<WorkTrackPrefs>(
    scope: SyncConfigScope.member,
    namespace: SyncConfigNamespaces.workTracks,
    encode: (value) => value.toJson(),
    decode: WorkTrackPrefs.fromJson,
  );

  Future<WorkIdentity?> resolve(MediaItem item) async {
    if (item.serverId != WorkIdentity.localSource || !WorkSkipSettingsStore.supports(item)) {
      return null;
    }
    final id = int.tryParse(item.id);
    if (id == null) return null;
    return LibraryWatchStateStore(db).resolveWork(id);
  }

  Future<WorkTrackPrefs?> readForItem(MediaItem item) async {
    final work = await resolve(item);
    if (work == null) return null;
    final prefs = await _syncConfigStore.read(spec, work.cloudWorkKey);
    return (prefs == null || prefs.isEmpty) ? null : prefs;
  }

  Future<bool> saveAudioForItem(MediaItem item, AudioTrack track, {bool syncToCloud = true}) async {
    if (track.id == AudioTrack.auto.id || track.id == AudioTrack.off.id) return false;
    final hasSemantics =
        (track.language?.isNotEmpty ?? false) ||
        (track.title?.isNotEmpty ?? false) ||
        (track.codec?.isNotEmpty ?? false);
    if (!hasSemantics) return false;

    final work = await resolve(item);
    if (work == null) return false;

    final existing = (await _syncConfigStore.read(spec, work.cloudWorkKey)) ?? const WorkTrackPrefs();
    final updated = existing.copyWithAudio(
      audioLang: track.language,
      audioTitle: track.title,
      audioCodec: track.codec,
      audioChannels: track.channels,
    );
    await _syncConfigStore.write(
      spec,
      work.cloudWorkKey,
      updated,
      workKey: work.cloudWorkKey,
      syncToCloud: syncToCloud,
    );
    return true;
  }

  Future<bool> saveSubtitleForItem(MediaItem item, SubtitleTrack track, {bool syncToCloud = true}) async {
    if (track.id == SubtitleTrack.auto.id) return false;

    final work = await resolve(item);
    if (work == null) return false;

    final existing = (await _syncConfigStore.read(spec, work.cloudWorkKey)) ?? const WorkTrackPrefs();
    final WorkTrackPrefs updated;
    if (track.id == SubtitleTrack.off.id) {
      updated = existing.copyWithSubtitle(subtitleOff: true);
    } else {
      final intent = SubtitleIntent.fromTrack(track);
      if (intent == null) return false;
      updated = existing.copyWithSubtitle(
        subtitleLang: intent.language,
        subtitleTitle: intent.title,
        subtitleCodec: intent.codec,
        subtitleForced: intent.forced,
        subtitleIsExternal: intent.isExternal,
        subtitleOff: false,
      );
    }

    await _syncConfigStore.write(
      spec,
      work.cloudWorkKey,
      updated,
      workKey: work.cloudWorkKey,
      syncToCloud: syncToCloud,
    );
    return true;
  }
}
