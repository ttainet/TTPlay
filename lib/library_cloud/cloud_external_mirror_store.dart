import 'dart:convert';

import '../connection/connection.dart';
import '../database/app_database.dart';
import '../iptv/iptv_models.dart';
import '../media/media_browser_dialect.dart';
import '../services/credential_vault.dart';
import '../utils/app_logger.dart';

/// Encrypted local mirror snapshot of cloud-synced IPTV and Emby/Jellyfin sources.
class CloudExternalMirrorSnapshot {
  final List<IptvSource> iptvSources;
  final List<JellyfinConnection> externalConnections;

  const CloudExternalMirrorSnapshot({
    required this.iptvSources,
    required this.externalConnections,
  });

  static const empty = CloudExternalMirrorSnapshot(iptvSources: [], externalConnections: []);

  bool get isEmpty => iptvSources.isEmpty && externalConnections.isEmpty;
}

/// Persists decrypted cloud IPTV sources and external Emby/Jellyfin descriptors
/// inside `sync_metadata` (encrypted via [CredentialVault]), scoped per
/// self-hosted account so cold starts can hydrate before sync server contact
/// and keep functioning if the sync server is temporarily or permanently offline.
class CloudExternalMirrorStore {
  CloudExternalMirrorStore(this.db);

  final AppDatabase db;

  static const int schemaVersion = 1;

  static String keyForScope(String accountScopeKey) => 'cloud_external_mirror_v1_${accountScopeKey.trim()}';

  Future<void> save(String accountScopeKey, CloudExternalMirrorSnapshot snapshot) async {
    final normalizedScope = accountScopeKey.trim();
    if (normalizedScope.isEmpty) return;

    final payload = {
      'version': schemaVersion,
      'saved_at_ms': DateTime.now().millisecondsSinceEpoch,
      'iptv_sources': [for (final s in snapshot.iptvSources) s.copyWith(isCloud: true).toJson()],
      'external_connections': [
        for (final c in snapshot.externalConnections)
          {
            'id': c.id,
            'dialect': c.dialect.name,
            'created_at_ms': c.createdAt.millisecondsSinceEpoch,
            if (c.lastAuthenticatedAt != null)
              'last_authenticated_at_ms': c.lastAuthenticatedAt!.millisecondsSinceEpoch,
            'config': c.toConfigJson(),
          },
      ],
    };

    final protected = await CredentialVault.protect(jsonEncode(payload));
    await db
        .into(db.syncMetadata)
        .insertOnConflictUpdate(SyncMetadataCompanion.insert(key: keyForScope(normalizedScope), value: protected));
  }

  Future<CloudExternalMirrorSnapshot?> load(String accountScopeKey) async {
    final normalizedScope = accountScopeKey.trim();
    if (normalizedScope.isEmpty) return null;

    try {
      final row = await (db.select(db.syncMetadata)
            ..where((t) => t.key.equals(keyForScope(normalizedScope))))
          .getSingleOrNull();
      final raw = row?.value;
      if (raw == null || raw.isEmpty) return null;

      final clear = await CredentialVault.reveal(raw);
      if (clear == null || clear.isEmpty) return null;

      final decoded = jsonDecode(clear);
      if (decoded is! Map || decoded['version'] != schemaVersion) return null;

      final iptvSources = <IptvSource>[];
      final rawIptv = decoded['iptv_sources'];
      if (rawIptv is List) {
        for (final entry in rawIptv) {
          if (entry is! Map) continue;
          final parsed = IptvSource.fromJson(Map<String, dynamic>.from(entry)).copyWith(isCloud: true);
          if (parsed.id.isNotEmpty && parsed.m3uUrl.isNotEmpty) {
            iptvSources.add(parsed);
          }
        }
      }

      final externalConnections = <JellyfinConnection>[];
      final rawExternals = decoded['external_connections'];
      if (rawExternals is List) {
        for (final entry in rawExternals) {
          if (entry is! Map) continue;
          final id = (entry['id'] as String? ?? '').trim();
          final rawConfig = entry['config'];
          if (id.isEmpty || rawConfig is! Map) continue;
          final dialect = entry['dialect'] == MediaBrowserDialect.emby.name
              ? MediaBrowserDialect.emby
              : MediaBrowserDialect.jellyfin;
          final createdAtMs = entry['created_at_ms'];
          final createdAt = createdAtMs is int && createdAtMs > 0
              ? DateTime.fromMillisecondsSinceEpoch(createdAtMs)
              : DateTime.fromMillisecondsSinceEpoch(0);
          final lastAuthMs = entry['last_authenticated_at_ms'];
          final lastAuthenticatedAt = lastAuthMs is int && lastAuthMs > 0
              ? DateTime.fromMillisecondsSinceEpoch(lastAuthMs)
              : null;
          final conn = JellyfinConnection.fromConfigJson(
            id: id,
            json: Map<String, Object?>.from(rawConfig),
            createdAt: createdAt,
            lastAuthenticatedAt: lastAuthenticatedAt,
            dialect: dialect,
          );
          if (conn.baseUrl.isNotEmpty && conn.accessToken.isNotEmpty && conn.userId.isNotEmpty) {
            externalConnections.add(conn);
          }
        }
      }

      return CloudExternalMirrorSnapshot(
        iptvSources: List.unmodifiable(iptvSources),
        externalConnections: List.unmodifiable(externalConnections),
      );
    } catch (e) {
      appLogger.w('CloudExternalMirrorStore: failed to load mirror for $normalizedScope: $e');
      return null;
    }
  }

  Future<void> delete(String accountScopeKey) async {
    final normalizedScope = accountScopeKey.trim();
    if (normalizedScope.isEmpty) return;
    await (db.delete(db.syncMetadata)..where((t) => t.key.equals(keyForScope(normalizedScope)))).go();
  }
}
