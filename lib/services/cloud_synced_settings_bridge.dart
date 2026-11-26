import 'dart:async';

import '../models/sync_config_entry.dart';
import '../utils/app_logger.dart';
import 'settings_service.dart';
import 'sync_config_store.dart';

/// Synchronizes hardware-independent, user-facing global preferences with the
/// cloud `member / app.prefs` namespace via [SyncConfigStore].
class CloudSyncedSettingsBridge {
  CloudSyncedSettingsBridge(this._settings);

  final SettingsService _settings;
  SyncConfigStore? _store;
  StreamSubscription<SyncConfigChange>? _sub;

  /// Strict allowlist of non-hardware playback, subtitle styling, and browsing
  /// preferences. Hardware decoders, shaders, box-fit, zoom, audio sync,
  /// download paths, hotkeys, and quality caps stay strictly device-local.
  static final List<Pref<Object?>> syncedPrefs = List.unmodifiable([
    // Playback behavior
    SettingsService.autoPlayNextEpisode,
    SettingsService.playNextCountdown,
    SettingsService.rewindOnResume,
    SettingsService.autoSkipDelay,
    SettingsService.skipIntroMode,
    SettingsService.skipCreditsMode,
    SettingsService.rememberTrackSelections,
    SettingsService.showChapterMarkersOnTimeline,
    SettingsService.continueWatchingAction,
    SettingsService.episodeAction,
    // Subtitle styling
    SettingsService.subtitleFontSize,
    SettingsService.subtitleTextColor,
    SettingsService.subtitleBorderSize,
    SettingsService.subtitleBorderColor,
    SettingsService.subtitleBackgroundColor,
    SettingsService.subtitleBackgroundOpacity,
    SettingsService.subtitlePosition,
    SettingsService.subtitleBold,
    SettingsService.subtitleItalic,
    SettingsService.subAssOverride,
    SettingsService.subtitleUseMargins,
    SettingsService.subtitleAnchorToScreen,
    // Browsing & appearance
    SettingsService.hideSpoilers,
    SettingsService.showUnwatchedCount,
    SettingsService.showWatchedIndicators,
    SettingsService.showEpisodeNumberOnCards,
    SettingsService.specialsOrdering,
    SettingsService.themeMode,
  ]);

  static final Map<String, Pref<Object?>> _prefsByKey = {for (final pref in syncedPrefs) pref.key: pref};

  void attach(SyncConfigStore store) {
    if (identical(_store, store)) return;
    detach();
    _store = store;
    _settings.onPrefMutated = _handleLocalMutation;
    _sub = store.changes.listen(_handleStoreChange);
    unawaited(applyStoredPrefs());
  }

  void detach() {
    if (identical(_settings.onPrefMutated, _handleLocalMutation)) {
      _settings.onPrefMutated = null;
    }
    unawaited(_sub?.cancel());
    _sub = null;
    _store = null;
  }

  Future<void> applyStoredPrefs() async {
    final store = _store;
    if (store == null) return;
    final entries = await store.listRawByNamespace(SyncConfigScope.member, SyncConfigNamespaces.appPrefs);
    for (final entry in entries.entries) {
      await _applyRemoteValue(entry.key, entry.value['v'], deleted: false);
    }
  }

  void _handleLocalMutation(Pref<Object?> pref, Object? jsonValue, {required bool isReset}) {
    final store = _store;
    if (store == null || !_prefsByKey.containsKey(pref.key)) return;
    if (isReset) {
      unawaited(
        store.delete(scope: SyncConfigScope.member, namespace: SyncConfigNamespaces.appPrefs, itemKey: pref.key),
      );
      return;
    }
    unawaited(
      store.writeRaw(
        scope: SyncConfigScope.member,
        namespace: SyncConfigNamespaces.appPrefs,
        itemKey: pref.key,
        value: {'v': jsonValue},
      ),
    );
  }

  void _handleStoreChange(SyncConfigChange change) {
    if (!change.fromRemote ||
        change.scope != SyncConfigScope.member ||
        change.namespace != SyncConfigNamespaces.appPrefs) {
      return;
    }
    if (!_prefsByKey.containsKey(change.itemKey)) return;
    if (change.deleted) {
      unawaited(_applyRemoteValue(change.itemKey, null, deleted: true));
      return;
    }
    final rawVal = change.value?['v'];
    unawaited(_applyRemoteValue(change.itemKey, rawVal, deleted: false));
  }

  Future<void> _applyRemoteValue(String key, Object? rawVal, {required bool deleted}) async {
    final pref = _prefsByKey[key];
    if (pref == null) return;
    try {
      await _settings.runWithoutMutationHook(() async {
        if (deleted) {
          await _settings.reset(pref);
          return;
        }
        final decoded = pref.fromJson(rawVal);
        SettingsService.validateEditableValue(pref, decoded);
        await pref.applyJsonValue(_settings, rawVal);
      });
    } catch (e) {
      appLogger.d('CloudSyncedSettingsBridge ignored invalid remote pref "$key": $e');
    }
  }
}
