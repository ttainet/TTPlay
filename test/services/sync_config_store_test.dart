import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ttplay/database/app_database.dart';
import 'package:ttplay/library/local_library_client.dart';
import 'package:ttplay/models/sync_config_entry.dart';
import 'package:ttplay/services/sync_config_store.dart';

class _RecordingKvBridge extends LocalCloudUserDataBridge {
  final puts = <({String scope, String namespace, String key, Map<String, dynamic> value, String? workKey})>[];
  final deletes = <({String scope, String namespace, String key})>[];
  bool shouldThrow = false;

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
    if (shouldThrow) throw const SocketException('offline');
    puts.add((scope: scope, namespace: namespace, key: key, value: value, workKey: workKey));
  }

  @override
  Future<void> deleteCloudKv({required String scope, required String namespace, required String key}) async {
    if (shouldThrow) throw const SocketException('offline');
    deletes.add((scope: scope, namespace: namespace, key: key));
  }
}

void main() {
  late AppDatabase db;
  late _RecordingKvBridge bridge;
  late SyncConfigStore store;

  final speedSpec = SyncConfigSpec<double>(
    scope: SyncConfigScope.member,
    namespace: SyncConfigNamespaces.workSpeed,
    encode: (v) => {'speed': v},
    decode: (m) => (m['speed'] as num).toDouble(),
    isValid: (v) => v >= 0.25 && v <= 8.0,
  );

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    bridge = _RecordingKvBridge();
    store = SyncConfigStore(db, cloudBridge: bridge);
  });

  tearDown(() async {
    store.dispose();
    await db.close();
  });

  test('typed read/write/delete, listRawByNamespace, and change stream', () async {
    final events = <SyncConfigChange>[];
    final sub = store.changes.listen(events.add);
    addTearDown(sub.cancel);

    await store.write(speedSpec, 'tmdb:show:100', 1.5, workKey: 'tmdb:show:100');
    await Future<void>.delayed(Duration.zero);

    expect(await store.read(speedSpec, 'tmdb:show:100'), 1.5);
    expect(bridge.puts.length, 1);
    expect(bridge.puts.single.scope, 'member');
    expect(bridge.puts.single.namespace, 'work.speed');
    expect(bridge.puts.single.workKey, 'tmdb:show:100');
    expect(events.single.fromRemote, isFalse);
    expect(events.single.deleted, isFalse);

    final listed = await store.listRawByNamespace(SyncConfigScope.member, SyncConfigNamespaces.workSpeed);
    expect(listed['tmdb:show:100']?['speed'], 1.5);

    expect(() => store.write(speedSpec, 'tmdb:show:100', 99.0), throwsArgumentError);

    await store.delete(
      scope: SyncConfigScope.member,
      namespace: SyncConfigNamespaces.workSpeed,
      itemKey: 'tmdb:show:100',
    );
    await Future<void>.delayed(Duration.zero);
    expect(await store.read(speedSpec, 'tmdb:show:100'), isNull);
    expect(bridge.deletes.single.key, 'tmdb:show:100');
    expect(events.last.deleted, isTrue);
    expect(events.last.fromRemote, isFalse);
  });

  test('syncToCloud: false and cloud errors preserve local persistence', () async {
    await store.write(speedSpec, 'tmdb:movie:1', 1.25, syncToCloud: false);
    expect(bridge.puts, isEmpty);

    bridge.shouldThrow = true;
    await store.write(speedSpec, 'tmdb:movie:2', 2.0);
    expect(await store.read(speedSpec, 'tmdb:movie:2'), 2.0);

    await store.delete(
      scope: SyncConfigScope.member,
      namespace: SyncConfigNamespaces.workSpeed,
      itemKey: 'tmdb:movie:2',
    );
    expect(await store.read(speedSpec, 'tmdb:movie:2'), isNull);
  });

  test('applyRemoteEntry, applyRemoteDelete, and clearAllLocalKv do not push upstream', () async {
    final remoteEvents = <SyncConfigChange>[];
    final sub = store.changes.listen(remoteEvents.add);
    addTearDown(sub.cancel);

    final applied = await store.applyRemoteEntry({
      'scope': 'member',
      'namespace': 'work.speed',
      'item_key': 'tmdb:show:77',
      'work_key': 'tmdb:show:77',
      'value': {'speed': 1.75},
      'updated_at': 1700000000000,
    });
    await Future<void>.delayed(Duration.zero);
    expect(applied, isTrue);
    expect(await store.read(speedSpec, 'tmdb:show:77'), 1.75);
    expect(remoteEvents.single.fromRemote, isTrue);
    expect(bridge.puts, isEmpty);

    final deletedViaEntry = await store.applyRemoteEntry({
      'scope': 'member',
      'namespace': 'work.speed',
      'item_key': 'tmdb:show:77',
      'deleted': true,
    });
    expect(deletedViaEntry, isTrue);
    expect(await store.read(speedSpec, 'tmdb:show:77'), isNull);

    await store.applyRemoteEntry({
      'scope': 'household',
      'namespace': 'work.skip',
      'item_key': 'tmdb:movie:5',
      'value': {'introEnabled': true, 'introStartMs': 0, 'introEndMs': 50000},
    });
    expect(await store.clearAllLocalKv(), 1);
    expect(await store.listRawByNamespace(SyncConfigScope.household, SyncConfigNamespaces.workSkip), isEmpty);
    expect(bridge.puts, isEmpty);
    expect(bridge.deletes, isEmpty);
  });
}
