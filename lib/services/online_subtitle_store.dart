import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../database/app_database.dart';
import '../utils/app_logger.dart';

class CachedOnlineSubtitle {
  const CachedOnlineSubtitle({
    required this.id,
    required this.itemGlobalKey,
    this.mediaSourceId,
    required this.provider,
    required this.remoteId,
    required this.title,
    this.language,
    required this.format,
    required this.relativePath,
    required this.absPath,
    required this.sha256,
    required this.isSelected,
    required this.createdAt,
  });

  final int id;
  final String itemGlobalKey;
  final String? mediaSourceId;
  final String provider;
  final String remoteId;
  final String title;
  final String? language;
  final String format;
  final String relativePath;
  final String absPath;
  final String sha256;
  final bool isSelected;
  final int createdAt;

  String get cacheIdentity => '$provider:$remoteId';

  String playableUri({required bool forExoPlayer}) {
    if (forExoPlayer) {
      return Uri.file(absPath).toString();
    }
    return absPath;
  }
}

/// Manages locally persisted UTF-8 online subtitle files and their Drift metadata.
class OnlineSubtitleStore {
  OnlineSubtitleStore(this._db, {Future<Directory> Function()? rootDirResolver})
    : _rootDirResolver = rootDirResolver ?? getApplicationSupportDirectory;

  static const String _subDirName = 'online_subtitles';

  final AppDatabase _db;
  final Future<Directory> Function() _rootDirResolver;

  Future<Directory> _baseDir() async {
    final root = await _rootDirResolver();
    final dir = Directory(p.join(root.path, _subDirName));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static String _sanitizeFormat(String raw) {
    final lower = raw.toLowerCase().replaceFirst(RegExp(r'^\.'), '').trim();
    switch (lower) {
      case 'ass':
      case 'ssa':
      case 'srt':
      case 'vtt':
        return lower;
      default:
        return 'srt';
    }
  }

  static String _sanitizeSha256(String raw) {
    final cleaned = raw.toLowerCase().trim();
    if (RegExp(r'^[0-9a-f]{64}$').hasMatch(cleaned)) {
      return cleaned;
    }
    return cleaned.replaceAll(RegExp(r'[^0-9a-zA-Z_-]'), '_');
  }

  Future<CachedOnlineSubtitle> _hydrateRow(DownloadedOnlineSubtitleRow row, Directory baseDir) async {
    final absPath = p.join(baseDir.path, row.relativePath);
    return CachedOnlineSubtitle(
      id: row.id,
      itemGlobalKey: row.itemGlobalKey,
      mediaSourceId: row.mediaSourceId,
      provider: row.provider,
      remoteId: row.remoteId,
      title: row.title,
      language: row.language,
      format: row.format,
      relativePath: row.relativePath,
      absPath: absPath,
      sha256: row.sha256,
      isSelected: row.isSelected,
      createdAt: row.createdAt,
    );
  }

  Expression<bool> _scopeFilter($DownloadedOnlineSubtitlesTable t, String itemGlobalKey, String? mediaSourceId) {
    final normalizedSource = mediaSourceId?.trim();
    if (normalizedSource == null || normalizedSource.isEmpty) {
      return t.itemGlobalKey.equals(itemGlobalKey);
    }
    return t.itemGlobalKey.equals(itemGlobalKey) &
        (t.mediaSourceId.equals(normalizedSource) | t.mediaSourceId.isNull());
  }

  Future<CachedOnlineSubtitle> saveAndSelect({
    required String itemGlobalKey,
    String? mediaSourceId,
    required String provider,
    required String remoteId,
    required String title,
    String? language,
    required String format,
    required String sha256,
    required String contentUtf8,
  }) async {
    final baseDir = await _baseDir();
    final safeFormat = _sanitizeFormat(format);
    final safeSha = _sanitizeSha256(sha256);
    final relPath = '$safeSha.$safeFormat';
    final absPath = p.join(baseDir.path, relPath);
    final targetFile = File(absPath);

    if (!await targetFile.exists()) {
      final tmpFile = File('$absPath.tmp.${DateTime.now().microsecondsSinceEpoch}');
      await tmpFile.writeAsBytes(utf8.encode(contentUtf8), flush: true);
      if (await targetFile.exists()) {
        await tmpFile.delete();
      } else {
        await tmpFile.rename(absPath);
      }
    }

    final normalizedSource = (mediaSourceId?.trim().isEmpty ?? true) ? null : mediaSourceId!.trim();
    final now = DateTime.now().millisecondsSinceEpoch;

    final row = await _db.transaction(() async {
      await (_db.update(_db.downloadedOnlineSubtitles)..where((t) => _scopeFilter(t, itemGlobalKey, normalizedSource)))
          .write(const DownloadedOnlineSubtitlesCompanion(isSelected: Value(false)));

      final existing =
          await (_db.select(_db.downloadedOnlineSubtitles)..where(
                (t) =>
                    t.itemGlobalKey.equals(itemGlobalKey) &
                    t.provider.equals(provider) &
                    t.remoteId.equals(remoteId) &
                    (normalizedSource == null ? t.mediaSourceId.isNull() : t.mediaSourceId.equals(normalizedSource)),
              ))
              .getSingleOrNull();

      if (existing != null) {
        await (_db.update(_db.downloadedOnlineSubtitles)..where((t) => t.id.equals(existing.id))).write(
          DownloadedOnlineSubtitlesCompanion(
            title: Value(title),
            language: Value(language),
            format: Value(safeFormat),
            relativePath: Value(relPath),
            sha256: Value(safeSha),
            isSelected: const Value(true),
          ),
        );
        return await (_db.select(_db.downloadedOnlineSubtitles)..where((t) => t.id.equals(existing.id))).getSingle();
      }

      final insertedId = await _db
          .into(_db.downloadedOnlineSubtitles)
          .insert(
            DownloadedOnlineSubtitlesCompanion.insert(
              itemGlobalKey: itemGlobalKey,
              mediaSourceId: Value(normalizedSource),
              provider: provider,
              remoteId: remoteId,
              title: title,
              language: Value(language),
              format: safeFormat,
              relativePath: relPath,
              sha256: safeSha,
              isSelected: const Value(true),
              createdAt: now,
            ),
          );
      return await (_db.select(_db.downloadedOnlineSubtitles)..where((t) => t.id.equals(insertedId))).getSingle();
    });

    return _hydrateRow(row, baseDir);
  }

  Future<List<CachedOnlineSubtitle>> listForItem(String itemGlobalKey, {String? mediaSourceId}) async {
    final baseDir = await _baseDir();
    final rows =
        await (_db.select(_db.downloadedOnlineSubtitles)
              ..where((t) => _scopeFilter(t, itemGlobalKey, mediaSourceId))
              ..orderBy([(t) => OrderingTerm.desc(t.isSelected), (t) => OrderingTerm.desc(t.createdAt)]))
            .get();

    final result = <CachedOnlineSubtitle>[];
    final staleIds = <int>[];
    for (final row in rows) {
      final absPath = p.join(baseDir.path, row.relativePath);
      if (await File(absPath).exists()) {
        result.add(await _hydrateRow(row, baseDir));
      } else {
        staleIds.add(row.id);
      }
    }
    if (staleIds.isNotEmpty) {
      try {
        await (_db.delete(_db.downloadedOnlineSubtitles)..where((t) => t.id.isIn(staleIds))).go();
      } catch (e) {
        appLogger.d('Failed pruning stale online subtitle rows', error: e);
      }
    }
    return result;
  }

  Future<Map<String, CachedOnlineSubtitle>> findCachedRemoteIds(String itemGlobalKey, {String? mediaSourceId}) async {
    final items = await listForItem(itemGlobalKey, mediaSourceId: mediaSourceId);
    return {for (final item in items) item.cacheIdentity: item};
  }

  Future<void> markSelected(int rowId, {required String itemGlobalKey, String? mediaSourceId}) async {
    await _db.transaction(() async {
      await (_db.update(_db.downloadedOnlineSubtitles)..where((t) => _scopeFilter(t, itemGlobalKey, mediaSourceId)))
          .write(const DownloadedOnlineSubtitlesCompanion(isSelected: Value(false)));
      await (_db.update(
        _db.downloadedOnlineSubtitles,
      )..where((t) => t.id.equals(rowId))).write(const DownloadedOnlineSubtitlesCompanion(isSelected: Value(true)));
    });
  }

  Future<void> clearSelection(String itemGlobalKey, {String? mediaSourceId}) async {
    await (_db.update(_db.downloadedOnlineSubtitles)..where((t) => _scopeFilter(t, itemGlobalKey, mediaSourceId)))
        .write(const DownloadedOnlineSubtitlesCompanion(isSelected: Value(false)));
  }

  Future<void> delete(int rowId) async {
    final row = await (_db.select(_db.downloadedOnlineSubtitles)..where((t) => t.id.equals(rowId))).getSingleOrNull();
    if (row == null) return;
    await (_db.delete(_db.downloadedOnlineSubtitles)..where((t) => t.id.equals(rowId))).go();

    // Only remove the underlying file if no other item references the same relativePath.
    final refs = await (_db.select(
      _db.downloadedOnlineSubtitles,
    )..where((t) => t.relativePath.equals(row.relativePath))).get();
    if (refs.isEmpty) {
      final baseDir = await _baseDir();
      final f = File(p.join(baseDir.path, row.relativePath));
      if (await f.exists()) {
        await f.delete();
      }
    }
  }
}
