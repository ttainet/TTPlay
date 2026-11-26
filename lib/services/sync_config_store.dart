import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';

import '../database/app_database.dart';
import '../library/local_library_client.dart';
import '../models/sync_config_entry.dart';
import '../utils/app_logger.dart';

/// Unified local + cloud-synced key-value configuration store backed by Drift's
/// `library_settings` table so offline/cloud workspace isolation works with zero
/// schema migrations.
class SyncConfigStore {
  SyncConfigStore(this.db, {this.cloudBridge});

  final AppDatabase db;
  LocalCloudUserDataBridge? cloudBridge;

  final StreamController<SyncConfigChange> _changes = StreamController<SyncConfigChange>.broadcast();
  bool _disposed = false;

  Stream<SyncConfigChange> get changes => _changes.stream;

  static String storageKey(SyncConfigScope scope, String namespace, String itemKey) =>
      'kv:${scope.wireName}:$namespace:$itemKey';

  static String namespacePrefix(SyncConfigScope scope, String namespace) => 'kv:${scope.wireName}:$namespace:';

  Future<Map<String, dynamic>?> readRaw(SyncConfigScope scope, String namespace, String itemKey) async {
    final row = await (db.select(
      db.librarySettings,
    )..where((t) => t.key.equals(storageKey(scope, namespace, itemKey)))).getSingleOrNull();
    if (row == null) return null;
    try {
      final decoded = jsonDecode(row.value);
      if (decoded is Map) {
        final envelope = Map<String, dynamic>.from(decoded);
        final inner = envelope['v'];
        if (inner is Map) {
          return Map<String, dynamic>.from(inner);
        }
      }
    } catch (_) {}
    return null;
  }

  Future<T?> read<T>(SyncConfigSpec<T> spec, String itemKey) async {
    final raw = await readRaw(spec.scope, spec.namespace, itemKey);
    if (raw == null) return null;
    try {
      final parsed = spec.decode(raw);
      return spec.validate(parsed) ? parsed : null;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, Map<String, dynamic>>> listRawByNamespace(SyncConfigScope scope, String namespace) async {
    final prefix = namespacePrefix(scope, namespace);
    final rows = await (db.select(db.librarySettings)..where((t) => t.key.like('$prefix%'))).get();
    final out = <String, Map<String, dynamic>>{};
    for (final row in rows) {
      if (!row.key.startsWith(prefix)) continue;
      final itemKey = row.key.substring(prefix.length);
      if (itemKey.isEmpty) continue;
      try {
        final decoded = jsonDecode(row.value);
        if (decoded is Map && decoded['v'] is Map) {
          out[itemKey] = Map<String, dynamic>.from(decoded['v'] as Map);
        }
      } catch (_) {}
    }
    return out;
  }

  Future<void> writeRaw({
    required SyncConfigScope scope,
    required String namespace,
    required String itemKey,
    required Map<String, dynamic> value,
    String? workKey,
    bool syncToCloud = true,
  }) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final cleanWorkKey = workKey?.trim();
    final payload = <String, dynamic>{
      'v': value,
      't': nowMs,
      if (cleanWorkKey != null && cleanWorkKey.isNotEmpty) 'wk': cleanWorkKey,
    };
    await db
        .into(db.librarySettings)
        .insertOnConflictUpdate(
          LibrarySettingsCompanion.insert(key: storageKey(scope, namespace, itemKey), value: jsonEncode(payload)),
        );
    _emit(
      SyncConfigChange(
        scope: scope,
        namespace: namespace,
        itemKey: itemKey,
        workKey: cleanWorkKey,
        value: Map<String, dynamic>.from(value),
        deleted: false,
        updatedAt: nowMs,
        fromRemote: false,
      ),
    );

    final bridge = cloudBridge;
    if (syncToCloud && bridge != null) {
      try {
        await bridge
            .putCloudKv(scope: scope.wireName, namespace: namespace, key: itemKey, value: value, workKey: cleanWorkKey)
            .timeout(const Duration(seconds: 6));
      } catch (e) {
        appLogger.d('Cloud KV sync skipped for ${scope.wireName}/$namespace/$itemKey: $e');
      }
    }
  }

  Future<void> write<T>(SyncConfigSpec<T> spec, String itemKey, T value, {String? workKey, bool syncToCloud = true}) {
    if (!spec.validate(value)) {
      throw ArgumentError('Invalid sync config value for ${spec.namespace}/$itemKey');
    }
    return writeRaw(
      scope: spec.scope,
      namespace: spec.namespace,
      itemKey: itemKey,
      value: spec.encode(value),
      workKey: workKey,
      syncToCloud: syncToCloud,
    );
  }

  Future<void> delete({
    required SyncConfigScope scope,
    required String namespace,
    required String itemKey,
    bool syncToCloud = true,
  }) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    await (db.delete(db.librarySettings)..where((t) => t.key.equals(storageKey(scope, namespace, itemKey)))).go();
    _emit(
      SyncConfigChange(
        scope: scope,
        namespace: namespace,
        itemKey: itemKey,
        deleted: true,
        updatedAt: nowMs,
        fromRemote: false,
      ),
    );

    final bridge = cloudBridge;
    if (syncToCloud && bridge != null) {
      try {
        await bridge
            .deleteCloudKv(scope: scope.wireName, namespace: namespace, key: itemKey)
            .timeout(const Duration(seconds: 6));
      } catch (e) {
        appLogger.d('Cloud KV delete skipped for ${scope.wireName}/$namespace/$itemKey: $e');
      }
    }
  }

  Future<bool> applyRemoteEntry(Map<String, dynamic> raw) async {
    final scope = SyncConfigScope.fromWireName(raw['scope'] as String?);
    final namespace = (raw['namespace'] as String? ?? '').trim();
    final itemKey = (raw['item_key'] as String? ?? '').trim();
    if (scope == null || namespace.isEmpty || itemKey.isEmpty) return false;

    if (raw['deleted'] == true) {
      return applyRemoteDelete(scope: scope, namespace: namespace, itemKey: itemKey);
    }

    final rawVal = raw['value'];
    if (rawVal is! Map) return false;
    final valueMap = Map<String, dynamic>.from(rawVal);
    final updatedAt = (raw['updated_at'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch;
    final workKey = (raw['work_key'] as String?)?.trim();

    final payload = <String, dynamic>{
      'v': valueMap,
      't': updatedAt,
      if (workKey != null && workKey.isNotEmpty) 'wk': workKey,
    };
    await db
        .into(db.librarySettings)
        .insertOnConflictUpdate(
          LibrarySettingsCompanion.insert(key: storageKey(scope, namespace, itemKey), value: jsonEncode(payload)),
        );
    _emit(
      SyncConfigChange(
        scope: scope,
        namespace: namespace,
        itemKey: itemKey,
        workKey: workKey,
        value: valueMap,
        deleted: false,
        updatedAt: updatedAt,
        fromRemote: true,
      ),
    );
    return true;
  }

  Future<bool> applyRemoteDelete({
    required SyncConfigScope scope,
    required String namespace,
    required String itemKey,
  }) async {
    final deletedCount = await (db.delete(
      db.librarySettings,
    )..where((t) => t.key.equals(storageKey(scope, namespace, itemKey)))).go();
    _emit(
      SyncConfigChange(
        scope: scope,
        namespace: namespace,
        itemKey: itemKey,
        deleted: true,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        fromRemote: true,
      ),
    );
    return deletedCount > 0;
  }

  /// Removes all KV entries from `library_settings` (used only by explicit tests/resets).
  Future<int> clearAllLocalKv() => db.customUpdate(
    "DELETE FROM library_settings WHERE key LIKE 'kv:%'",
    updates: {db.librarySettings},
    variables: const <Variable<Object>>[],
  );

  void _emit(SyncConfigChange change) {
    if (!_disposed && !_changes.isClosed) {
      _changes.add(change);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_changes.close());
  }
}
