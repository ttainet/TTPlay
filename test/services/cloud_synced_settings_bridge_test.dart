import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ttplay/database/app_database.dart';
import 'package:ttplay/library/local_library_client.dart';
import 'package:ttplay/models/sync_config_entry.dart';
import 'package:ttplay/services/cloud_synced_settings_bridge.dart';
import 'package:ttplay/services/settings_service.dart';
import 'package:ttplay/services/sync_config_store.dart';

import '../test_helpers/prefs.dart';

class _RecordingPrefKvBridge extends LocalCloudUserDataBridge {
  final puts = <({String scope, String namespace, String key, Map<String, dynamic> value})>[];
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
    puts.add((scope: scope, namespace: namespace, key: key, value: value));
  }

  @override
  Future<void> deleteCloudKv({required String scope, required String namespace, required String key}) async {
    deletes.add((scope: scope, namespace: namespace, key: key));
  }
}

void main() {
  late AppDatabase db;
  late _RecordingPrefKvBridge cloudBridge;
  late SyncConfigStore syncStore;
  late SettingsService settings;
  late CloudSyncedSettingsBridge settingsBridge;

  setUp(() async {
    resetSharedPreferencesForTest();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    cloudBridge = _RecordingPrefKvBridge();
    syncStore = SyncConfigStore(db, cloudBridge: cloudBridge);
    settings = await SettingsService.getInstance();
    settingsBridge = CloudSyncedSettingsBridge(settings);
  });

  tearDown(() async {
    settingsBridge.detach();
    syncStore.dispose();
    await db.close();
  });

  test('syncs allowlisted prefs, ignores hardware/local prefs, and avoids sync loops', () async {
    // Seed pre-existing stored pref before attaching bridge -> hydrated automatically on attach.
    await syncStore.writeRaw(
      scope: SyncConfigScope.member,
      namespace: SyncConfigNamespaces.appPrefs,
      itemKey: SettingsService.subtitleFontSize.key,
      value: {'v': 48},
      syncToCloud: false,
    );

    settingsBridge.attach(syncStore);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(settings.read(SettingsService.subtitleFontSize), 48);
    expect(cloudBridge.puts, isEmpty);

    // Local mutation of allowlisted prefs pushes to member / app.prefs.
    await settings.write(SettingsService.autoPlayNextEpisode, false);
    await settings.write(SettingsService.themeMode, ThemeMode.oled);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(
      cloudBridge.puts.map((p) => p.key),
      containsAll([SettingsService.autoPlayNextEpisode.key, SettingsService.themeMode.key]),
    );

    // Local reset pushes deleteCloudKv.
    await settings.reset(SettingsService.autoPlayNextEpisode);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(cloudBridge.deletes.single.key, SettingsService.autoPlayNextEpisode.key);

    // Excluded device-local prefs never sync.
    final putsBeforeExcluded = cloudBridge.puts.length;
    await settings.write(SettingsService.audioSyncOffset, 250);
    await settings.write(SettingsService.enableHardwareDecoding, false);
    await settings.write(SettingsService.enableDebugLogging, true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(cloudBridge.puts.length, putsBeforeExcluded);

    // Remote apply updates SettingsService without echoing back upstream (zero loop).
    final putsBeforeRemote = cloudBridge.puts.length;
    final deletesBeforeRemote = cloudBridge.deletes.length;
    await syncStore.applyRemoteEntry({
      'scope': 'member',
      'namespace': 'app.prefs',
      'item_key': SettingsService.subtitleFontSize.key,
      'value': {'v': 60},
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(settings.read(SettingsService.subtitleFontSize), 60);
    expect(cloudBridge.puts.length, putsBeforeRemote);

    // Remote delete resets pref to default without echoing back.
    await syncStore.applyRemoteDelete(
      scope: SyncConfigScope.member,
      namespace: SyncConfigNamespaces.appPrefs,
      itemKey: SettingsService.subtitleFontSize.key,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(settings.read(SettingsService.subtitleFontSize), SettingsService.subtitleFontSize.defaultValue);
    expect(cloudBridge.deletes.length, deletesBeforeRemote);

    // Invalid remote values (e.g. out-of-range font size) are ignored cleanly.
    await syncStore.applyRemoteEntry({
      'scope': 'member',
      'namespace': 'app.prefs',
      'item_key': SettingsService.subtitleFontSize.key,
      'value': {'v': 999999},
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(settings.read(SettingsService.subtitleFontSize), SettingsService.subtitleFontSize.defaultValue);
    expect(Platform.operatingSystem, isNotEmpty);
  });
}
