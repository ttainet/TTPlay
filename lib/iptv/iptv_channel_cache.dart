import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../utils/app_logger.dart';
import 'iptv_models.dart';

/// Persisted snapshot of a parsed IPTV M3U/TXT playlist for one [IptvSource].
class IptvCachedPlaylist {
  static const int schemaVersion = 1;

  final String sourceId;
  final String fingerprint;
  final DateTime cachedAt;
  final String? headerEpgUrl;
  final List<IptvChannel> channels;

  const IptvCachedPlaylist({
    required this.sourceId,
    required this.fingerprint,
    required this.cachedAt,
    this.headerEpgUrl,
    required this.channels,
  });

  Map<String, dynamic> toJson() => {
    'version': schemaVersion,
    'source_id': sourceId,
    'fingerprint': fingerprint,
    'cached_at_ms': cachedAt.millisecondsSinceEpoch,
    if (headerEpgUrl != null && headerEpgUrl!.isNotEmpty) 'header_epg_url': headerEpgUrl,
    'channels': [for (final ch in channels) ch.toJson()],
  };

  static IptvCachedPlaylist? tryFromJson(
    Map<String, dynamic> json, {
    required String expectedSourceId,
    required String expectedFingerprint,
  }) {
    if (json['version'] != schemaVersion) return null;
    if ((json['source_id'] as String?)?.trim() != expectedSourceId) return null;
    if ((json['fingerprint'] as String?) != expectedFingerprint) return null;
    final cachedAtMs = json['cached_at_ms'];
    if (cachedAtMs is! int || cachedAtMs <= 0) return null;

    final rawChannels = json['channels'];
    if (rawChannels is! List || rawChannels.isEmpty) return null;

    final channels = <IptvChannel>[];
    for (final entry in rawChannels) {
      if (entry is! Map) continue;
      final parsed = IptvChannel.fromJson(
        Map<String, dynamic>.from(entry),
        fallbackSourceId: expectedSourceId,
      );
      if (parsed.id.isNotEmpty && parsed.name.isNotEmpty && parsed.variants.isNotEmpty) {
        channels.add(parsed);
      }
    }
    if (channels.isEmpty) return null;

    final rawHeaderEpg = (json['header_epg_url'] as String?)?.trim();
    return IptvCachedPlaylist(
      sourceId: expectedSourceId,
      fingerprint: expectedFingerprint,
      cachedAt: DateTime.fromMillisecondsSinceEpoch(cachedAtMs),
      headerEpgUrl: (rawHeaderEpg == null || rawHeaderEpg.isEmpty) ? null : rawHeaderEpg,
      channels: List<IptvChannel>.unmodifiable(channels),
    );
  }
}

/// Disk-backed cache for parsed IPTV channel lists, keyed by `(scopeKey, sourceId)`.
class IptvChannelCache {
  static final Expando<Future<Directory?>> _resolvedDirectories = Expando<Future<Directory?>>(
    'IptvChannelCache.directory',
  );

  final Future<Directory> Function()? _directoryProvider;
  final bool _disabled;

  const IptvChannelCache({Future<Directory> Function()? directoryProvider})
    : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory,
      _disabled = false;

  const IptvChannelCache.noop()
    : _directoryProvider = null,
      _disabled = true;

  static String buildFingerprint(IptvSource source) =>
      '${source.m3uUrl.trim()}\u0000${source.userAgent?.trim() ?? ''}\u0000${source.referer?.trim() ?? ''}';

  static String _fileName(String scopeKey, String sourceId) {
    final hash = sha256.convert(utf8.encode('$scopeKey\u0000$sourceId')).toString();
    return '$hash.json';
  }

  Future<Directory?> _resolveCacheDirectory() {
    if (_disabled || _directoryProvider == null) return Future<Directory?>.value(null);
    return _resolvedDirectories[this] ??= _initCacheDirectory(_directoryProvider);
  }

  Future<Directory?> _initCacheDirectory(Future<Directory> Function() provider) async {
    try {
      final root = await provider();
      return Directory(p.join(root.path, 'iptv_cache'));
    } catch (e) {
      appLogger.d('IptvChannelCache: cache directory unavailable, disabling disk cache: $e');
      return null;
    }
  }

  Future<IptvCachedPlaylist?> read({
    required String scopeKey,
    required String sourceId,
    required String expectedFingerprint,
  }) async {
    final dir = await _resolveCacheDirectory();
    if (dir == null) return null;
    final file = File(p.join(dir.path, _fileName(scopeKey, sourceId)));
    try {
      if (!await file.exists()) return null;
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return IptvCachedPlaylist.tryFromJson(
        Map<String, dynamic>.from(decoded),
        expectedSourceId: sourceId,
        expectedFingerprint: expectedFingerprint,
      );
    } catch (e) {
      appLogger.d('IptvChannelCache: failed to read cache for $sourceId: $e');
      return null;
    }
  }

  Future<void> write({required String scopeKey, required IptvCachedPlaylist entry}) async {
    final dir = await _resolveCacheDirectory();
    if (dir == null) return;
    final target = File(p.join(dir.path, _fileName(scopeKey, entry.sourceId)));
    final tmp = File('${target.path}.tmp');
    try {
      await dir.create(recursive: true);
      final encoded = jsonEncode(entry.toJson());
      await tmp.writeAsString(encoded, flush: true);
      try {
        await tmp.rename(target.path);
      } catch (_) {
        await target.writeAsString(encoded, flush: true);
        if (await tmp.exists()) {
          await tmp.delete();
        }
      }
    } catch (e) {
      appLogger.d('IptvChannelCache: failed to write cache for ${entry.sourceId}: $e');
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
  }

  Future<void> delete({required String scopeKey, required String sourceId}) async {
    final dir = await _resolveCacheDirectory();
    if (dir == null) return;
    final target = File(p.join(dir.path, _fileName(scopeKey, sourceId)));
    final tmp = File('${target.path}.tmp');
    try {
      if (await target.exists()) await target.delete();
      if (await tmp.exists()) await tmp.delete();
    } catch (_) {}
  }
}
