import 'dart:async';

import 'package:drift/drift.dart';

import '../database/app_database.dart';
import '../library/deterministic_keys.dart';
import '../library/library_repository.dart';
import '../library/library_watch_state_store.dart';
import '../models/sync_config_entry.dart';
import '../services/sync_config_store.dart';
import '../storage/storage_path.dart';
import '../utils/app_logger.dart';
import 'cloud_mount_mirror.dart';
import 'projection_sync.dart';

class CloudSyncResult {
  const CloudSyncResult({
    required this.fullReset,
    required this.latestSeq,
    required this.itemsProjected,
    required this.filesProjected,
    required this.emptyShellsPruned,
    this.hasChanges = false,
  });

  final bool fullReset;
  final int latestSeq;
  final int itemsProjected;
  final int filesProjected;
  final int emptyShellsPruned;
  final bool hasChanges;
}

/// Projects `media_library` S5 snapshots, incremental changes, and playback
/// states into the local Drift database (`LibraryItems`, `LibraryFiles`,
/// `LibraryUserStates`) so existing UI & [LocalLibraryClient] render a unified
/// direct-play library (C3).
class CloudProjectionEngine {
  CloudProjectionEngine({
    required this.db,
    required this.syncClient,
    required this.mountMirror,
    SyncConfigStore? syncConfigStore,
    this.onLibraryUpdated,
    this.onSyncStateChanged,
  }) : _syncConfigStore = syncConfigStore ?? SyncConfigStore(db);

  final AppDatabase db;
  final CloudProjectionSyncClient syncClient;
  final CloudMountMirror mountMirror;
  final SyncConfigStore _syncConfigStore;
  final void Function()? onLibraryUpdated;
  final void Function(bool syncing)? onSyncStateChanged;

  static const String _seqKeyPrefix = 'cloud-projection-seq:';

  int _lastSeq = 0;
  bool _seqLoaded = false;
  bool _syncing = false;
  bool _resyncQueued = false;
  bool _listeningEvents = false;
  bool _hasConnectedSseOnce = false;
  int _sseReconnectAttempts = 0;
  StreamSubscription<CloudSseEvent>? _sseSub;
  Timer? _debounceTimer;
  Timer? _reconnectTimer;
  Timer? _resyncTimer;
  final Map<String, Future<bool>> _inFlightDetailHydrations = {};
  final Map<String, DateTime> _lastDetailHydratedAt = {};

  int get lastSeq => _lastSeq;
  bool get isSyncing => _syncing;

  String get _seqStorageKey {
    final scope = mountMirror.accountScopeKey?.trim();
    return '$_seqKeyPrefix${(scope == null || scope.isEmpty) ? 'default' : scope}';
  }

  Future<void> _ensureSeqLoaded() async {
    if (_seqLoaded || _lastSeq > 0) {
      _seqLoaded = true;
      return;
    }
    _seqLoaded = true;
    final row = await (db.select(db.librarySettings)..where((t) => t.key.equals(_seqStorageKey))).getSingleOrNull();
    final persisted = row == null ? null : int.tryParse(row.value.trim());
    if (persisted == null || persisted <= 0) return;
    final hasLocalItems =
        await (db.selectOnly(db.libraryItems)
              ..addColumns([db.libraryItems.id])
              ..limit(1))
            .getSingleOrNull() !=
        null;
    if (hasLocalItems) {
      _lastSeq = persisted;
    }
  }

  Future<void> _persistSeq(int seq) async {
    if (seq <= 0) return;
    await db
        .into(db.librarySettings)
        .insertOnConflictUpdate(LibrarySettingsCompanion.insert(key: _seqStorageKey, value: '$seq'));
  }

  Future<CloudSyncResult> _withSyncLock(Future<CloudSyncResult> Function() action, {bool queueIfBusy = false}) async {
    if (_syncing) {
      if (queueIfBusy) _resyncQueued = true;
      return CloudSyncResult(
        fullReset: false,
        latestSeq: _lastSeq,
        itemsProjected: 0,
        filesProjected: 0,
        emptyShellsPruned: 0,
      );
    }
    _syncing = true;
    onSyncStateChanged?.call(true);
    try {
      return await action();
    } finally {
      _syncing = false;
      onSyncStateChanged?.call(false);
      if (_resyncQueued) {
        _resyncQueued = false;
        if (_listeningEvents) {
          _resyncTimer?.cancel();
          _resyncTimer = Timer(const Duration(milliseconds: 500), () {
            unawaited(_runSafeIncremental());
          });
        }
      }
    }
  }

  /// Runs a full cloud-to-local snapshot projection:
  /// 1. Mirrors cloud sources & E2EE credentials into [MountRegistry].
  /// 2. Pulls paginated movies/shows/seasons/episodes & item file locators.
  /// 3. Projects into `LibraryItems` & `LibraryFiles`, preserving local-folder
  ///    files and pruning stale cloud files + empty shells.
  Future<CloudSyncResult> syncFullSnapshot() => _withSyncLock(_runFullSnapshotLocked);

  Future<CloudSyncResult> _runFullSnapshotLocked() async {
    await mountMirror.mirrorAllSources();
    final knownMountIds = (await db.select(db.mounts).get()).map((m) => m.id).toSet();

    var snapshotSeq = _lastSeq;
    final serverIdToLocalId = <int, int>{};
    final serverIdToWorkKey = <int, String>{};
    final projectedCloudFileKeys = <String>{};
    var itemsCount = 0;
    var filesCount = 0;

    // Project in dependency order so parentId/showId resolve cleanly.
    for (final kind in const [LibraryKinds.movie, LibraryKinds.show, LibraryKinds.season, LibraryKinds.episode]) {
      var page = 1;
      while (true) {
        final snap = await syncClient.fetchSnapshot(kind: kind, page: page, pageSize: 200, includeFiles: true);
        if (snap.snapshotSeq > snapshotSeq) snapshotSeq = snap.snapshotSeq;

        // Backward-compatibility fallback for older servers that omit `files`
        // in /library/snapshot: prefetch before opening the DB transaction.
        final fallbackFilesByServerId = <int, dynamic>{};
        if (kind == LibraryKinds.movie || kind == LibraryKinds.episode) {
          for (final raw in snap.items) {
            final serverId = (raw['id'] as num?)?.toInt() ?? 0;
            if (serverId <= 0 || raw.containsKey('files')) continue;
            final detail = await syncClient.fetchItemDetail(serverId);
            fallbackFilesByServerId[serverId] = detail['files'];
          }
        }

        await db.transaction(() async {
          for (final raw in snap.items) {
            final serverId = (raw['id'] as num?)?.toInt() ?? 0;
            if (serverId <= 0) continue;

            final projected = await _upsertProjectedItem(raw, serverIdToLocalId, serverIdToWorkKey);
            if (projected == null) continue;
            serverIdToLocalId[serverId] = projected.localId;
            serverIdToWorkKey[serverId] = projected.workKey;
            itemsCount++;

            if (kind == LibraryKinds.movie || kind == LibraryKinds.episode) {
              final filesRaw = raw.containsKey('files') ? raw['files'] : fallbackFilesByServerId[serverId];
              if (filesRaw is List) {
                for (final f in filesRaw) {
                  if (f is! Map) continue;
                  final fMap = Map<String, dynamic>.from(f);
                  final fileRes = await _upsertProjectedFile(
                    localItemId: projected.localId,
                    raw: fMap,
                    knownMountIds: knownMountIds,
                  );
                  if (fileRes == null) continue;
                  projectedCloudFileKeys.add(fileRes.fileKey);
                  filesCount++;

                  final subsRaw = fMap['subtitles'];
                  if (subsRaw is List) {
                    for (final s in subsRaw) {
                      if (s is! Map) continue;
                      final subMap = Map<String, dynamic>.from(s);
                      final subRes = await _upsertProjectedFile(
                        localItemId: null,
                        ownerFileId: fileRes.fileId,
                        forceRole: LibraryFileRoles.subtitle,
                        raw: subMap,
                        knownMountIds: knownMountIds,
                      );
                      if (subRes != null) {
                        projectedCloudFileKeys.add(subRes.fileKey);
                        filesCount++;
                      }
                    }
                  }
                }
              }
            }
          }
        });

        if (!snap.hasMore) break;
        page++;
      }
    }

    // Project unmatched/pending cloud files before pruning stale cloud files so
    // their file keys are preserved and orphaned unmatched items are cleaned up.
    final unmatchedRes = await _projectUnmatchedFilesFromServer(
      knownMountIds: knownMountIds,
      projectedCloudFileKeys: projectedCloudFileKeys,
      pruneStaleUnmatched: false,
    );
    itemsCount += unmatchedRes.itemsProjected;
    filesCount += unmatchedRes.filesProjected;

    // Remove stale cloud files no longer present in the cloud snapshot.
    await _pruneStaleCloudFiles(projectedCloudFileKeys);
    final pruned = await pruneEmptyProjectedItems();

    await _syncUserStateFromServer();

    _lastDetailHydratedAt.clear();
    _lastSeq = snapshotSeq;
    await _persistSeq(_lastSeq);
    onLibraryUpdated?.call();

    return CloudSyncResult(
      fullReset: true,
      latestSeq: _lastSeq,
      itemsProjected: itemsCount,
      filesProjected: filesCount,
      emptyShellsPruned: pruned,
      hasChanges: true,
    );
  }

  /// Pulls incremental `/api/v1/library/changes?since_seq=...&include_files=1`,
  /// applying changed items & files in place when possible and falling back to
  /// [_runFullSnapshotLocked] on `reset_required`, deletions/missing files,
  /// source changes, or unresolvable parents.
  Future<CloudSyncResult> syncIncremental() async {
    await _ensureSeqLoaded();
    if (_lastSeq <= 0) {
      return syncFullSnapshot();
    }
    return _withSyncLock(() async {
      final changesPage = await syncClient.fetchChanges(sinceSeq: _lastSeq, limit: 200, includeFiles: true);
      if (changesPage.resetRequired) {
        return await _runFullSnapshotLocked();
      }
      if (changesPage.changes.isEmpty) {
        if (changesPage.latestSeq > _lastSeq) {
          _lastSeq = changesPage.latestSeq;
          await _persistSeq(_lastSeq);
        }
        return CloudSyncResult(
          fullReset: false,
          latestSeq: _lastSeq,
          itemsProjected: 0,
          filesProjected: 0,
          emptyShellsPruned: 0,
          hasChanges: false,
        );
      }

      const structuralEntities = {'source', 'folder', 'source_folder', 'pending_deletion'};
      var needsFullSnapshot = changesPage.hasMore;
      var hasUserDataChange = false;
      var hasFileChange = false;
      final changedItemsById = <int, Map<String, dynamic>>{};
      final kvOps =
          <
            ({bool isDelete, Map<String, dynamic>? entry, SyncConfigScope? scope, String? namespace, String? itemKey})
          >[];
      final listOps = <({bool isDelete, Map<String, dynamic>? list, String? cloudListId})>[];

      for (final c in changesPage.changes) {
        final entity = (c['entity'] as String? ?? '').toLowerCase();
        final op = (c['op'] as String? ?? '').toLowerCase();
        if (structuralEntities.contains(entity)) {
          needsFullSnapshot = true;
          break;
        }
        if (entity == 'item') {
          if (op != 'upsert') {
            needsFullSnapshot = true;
            break;
          }
          final data = c['data'];
          if (data is! Map) {
            needsFullSnapshot = true;
            break;
          }
          final map = Map<String, dynamic>.from(data);
          final sid = (map['id'] as num?)?.toInt() ?? 0;
          if (sid <= 0) {
            needsFullSnapshot = true;
            break;
          }
          changedItemsById[sid] = map;
          continue;
        }
        if (entity == 'file' || entity == 'media_file') {
          if (op == 'delete' || op == 'missing' || op == 'remove') {
            needsFullSnapshot = true;
            break;
          }
          hasFileChange = true;
          // `media_file` upserts before scraping (pending item_id) or `media_spec`
          // do not require re-downloading all snapshot pages.
          continue;
        }
        if (entity == 'kv') {
          final data = c['data'];
          if (op == 'delete') {
            final target = _extractKvDeleteTarget(data, c['entity_id'] as String?);
            if (target != null) {
              kvOps.add((
                isDelete: true,
                entry: null,
                scope: target.scope,
                namespace: target.namespace,
                itemKey: target.itemKey,
              ));
            } else {
              hasUserDataChange = true;
            }
          } else if (op == 'upsert' && data is Map) {
            kvOps.add((
              isDelete: false,
              entry: Map<String, dynamic>.from(data),
              scope: null,
              namespace: null,
              itemKey: null,
            ));
          } else {
            hasUserDataChange = true;
          }
          continue;
        }
        if (entity == 'list') {
          final data = c['data'];
          final eid = (c['entity_id'] as String? ?? '').trim();
          if (op == 'delete' && eid.isNotEmpty) {
            listOps.add((isDelete: true, list: null, cloudListId: eid));
          } else if (op == 'upsert' && data is Map) {
            listOps.add((isDelete: false, list: Map<String, dynamic>.from(data), cloudListId: null));
          } else {
            hasUserDataChange = true;
          }
          continue;
        }
        if (entity == 'progress' || entity == 'favorite') {
          hasUserDataChange = true;
        }
      }

      if (needsFullSnapshot) {
        return await _runFullSnapshotLocked();
      }

      if (changedItemsById.isEmpty) {
        var itemsProjected = 0;
        var filesProjected = 0;
        var pruned = 0;
        if (hasFileChange) {
          final knownMountIds = (await db.select(db.mounts).get()).map((m) => m.id).toSet();
          final unmatchedRes = await _projectUnmatchedFilesFromServer(
            knownMountIds: knownMountIds,
            pruneStaleUnmatched: true,
          );
          itemsProjected = unmatchedRes.itemsProjected;
          filesProjected = unmatchedRes.filesProjected;
          pruned = unmatchedRes.pruned;
        }
        if (hasUserDataChange) {
          await _syncUserStateFromServer();
        }
        final kvApplied = await _applyKvDeltas(kvOps);
        final listApplied = await _applyListDeltas(listOps);
        final hasChanges =
            hasUserDataChange || kvApplied || listApplied || itemsProjected > 0 || filesProjected > 0 || pruned > 0;
        if (hasChanges) {
          onLibraryUpdated?.call();
        }
        _lastSeq = changesPage.nextSinceSeq > _lastSeq ? changesPage.nextSinceSeq : changesPage.latestSeq;
        await _persistSeq(_lastSeq);
        return CloudSyncResult(
          fullReset: false,
          latestSeq: _lastSeq,
          itemsProjected: itemsProjected,
          filesProjected: filesProjected,
          emptyShellsPruned: pruned,
          hasChanges: hasChanges,
        );
      }

      int kindOrder(Map<String, dynamic> m) => switch ((m['kind'] as String? ?? '').toLowerCase()) {
        LibraryKinds.movie || LibraryKinds.show => 0,
        LibraryKinds.season => 1,
        LibraryKinds.episode => 2,
        _ => 3,
      };
      final sortedItems = changedItemsById.values.toList()..sort((a, b) => kindOrder(a).compareTo(kindOrder(b)));

      // Check mount ids before mutating anything; refresh mounts if a new cloud source appeared.
      var knownMountIds = (await db.select(db.mounts).get()).map((m) => m.id).toSet();
      final missingMount = sortedItems.any((item) {
        final files = item['files'];
        if (files is! List) return false;
        for (final f in files) {
          if (f is! Map) continue;
          final sid = (f['source_id'] as String? ?? '').trim();
          if (sid.isNotEmpty && !knownMountIds.contains(CloudMountMirror.mountIdForSource(sid))) {
            return true;
          }
        }
        return false;
      });
      if (missingMount) {
        await mountMirror.mirrorAllSources();
        knownMountIds = (await db.select(db.mounts).get()).map((m) => m.id).toSet();
      }

      final serverIdToLocalId = <int, int>{};
      final serverIdToWorkKey = <int, String>{};
      for (final raw in sortedItems) {
        final sid = (raw['id'] as num?)?.toInt() ?? 0;
        final kind = (raw['kind'] as String? ?? '').toLowerCase();
        if (sid > 0 && (kind == LibraryKinds.movie || kind == LibraryKinds.show)) {
          serverIdToWorkKey[sid] = (raw['work_key'] as String? ?? '').trim();
        }
      }

      // Verify/resolve parent show & season rows for any child-only delta changes before opening transaction.
      for (final raw in sortedItems) {
        final kind = (raw['kind'] as String? ?? '').toLowerCase();
        if (kind != LibraryKinds.season && kind != LibraryKinds.episode) continue;
        final serverParentId = (raw['parent_id'] as num?)?.toInt();
        final serverShowId = (raw['show_id'] as num?)?.toInt();
        final effectiveShowServerId = serverShowId ?? (kind == LibraryKinds.season ? serverParentId : null);

        if (effectiveShowServerId != null && !serverIdToLocalId.containsKey(effectiveShowServerId)) {
          final showWkRaw =
              _nonEmptyString(raw['show_work_key']) ??
              _nonEmptyString(changedItemsById[effectiveShowServerId]?['work_key']) ??
              '';
          LibraryItemRow? localShow;
          if (showWkRaw.isNotEmpty) {
            final canonicalWk = DeterministicKeys.canonicalizeWorkKey(showWkRaw);
            localShow = await (db.select(
              db.libraryItems,
            )..where((t) => t.workKey.equals(canonicalWk))).getSingleOrNull();
          }
          if (localShow == null) {
            final fallbackCloudWk = 'cloud:$effectiveShowServerId';
            localShow = await (db.select(
              db.libraryItems,
            )..where((t) => t.workKey.equals(fallbackCloudWk))).getSingleOrNull();
          }
          if (localShow != null) {
            serverIdToLocalId[effectiveShowServerId] = localShow.id;
            serverIdToWorkKey[effectiveShowServerId] = localShow.workKey ?? '';
          }
        }

        if (kind == LibraryKinds.episode &&
            serverParentId != null &&
            !changedItemsById.containsKey(serverParentId) &&
            !serverIdToLocalId.containsKey(serverParentId)) {
          final localShowId = effectiveShowServerId != null ? serverIdToLocalId[effectiveShowServerId] : null;
          final sNum = (raw['season_number'] as num?)?.toInt();
          if (localShowId != null && sNum != null) {
            final localSeason =
                await (db.select(db.libraryItems)..where(
                      (t) =>
                          t.showId.equals(localShowId) &
                          t.kind.equals(LibraryKinds.season) &
                          t.seasonNumber.equals(sNum),
                    ))
                    .getSingleOrNull();
            if (localSeason != null) {
              serverIdToLocalId[serverParentId] = localSeason.id;
            }
          }
        }

        final hasShow =
            effectiveShowServerId == null ||
            changedItemsById.containsKey(effectiveShowServerId) ||
            serverIdToLocalId.containsKey(effectiveShowServerId);
        final hasParent =
            serverParentId != null &&
            (changedItemsById.containsKey(serverParentId) || serverIdToLocalId.containsKey(serverParentId));
        if (!hasShow || !hasParent) {
          return await _runFullSnapshotLocked();
        }
      }

      var itemsCount = 0;
      var filesCount = 0;
      await db.transaction(() async {
        for (final raw in sortedItems) {
          final serverId = (raw['id'] as num?)?.toInt() ?? 0;
          if (serverId <= 0) continue;
          final projected = await _upsertProjectedItem(raw, serverIdToLocalId, serverIdToWorkKey);
          if (projected == null) continue;
          serverIdToLocalId[serverId] = projected.localId;
          serverIdToWorkKey[serverId] = projected.workKey;
          itemsCount++;

          final kind = (raw['kind'] as String? ?? '').toLowerCase();
          if (kind == LibraryKinds.movie || kind == LibraryKinds.episode) {
            final filesRaw = raw['files'];
            if (filesRaw is List) {
              final itemFileKeys = <String>{};
              for (final f in filesRaw) {
                if (f is! Map) continue;
                final fMap = Map<String, dynamic>.from(f);
                final fileRes = await _upsertProjectedFile(
                  localItemId: projected.localId,
                  raw: fMap,
                  knownMountIds: knownMountIds,
                );
                if (fileRes == null) continue;
                itemFileKeys.add(fileRes.fileKey);
                filesCount++;

                final subsRaw = fMap['subtitles'];
                if (subsRaw is List) {
                  for (final s in subsRaw) {
                    if (s is! Map) continue;
                    final subMap = Map<String, dynamic>.from(s);
                    final subRes = await _upsertProjectedFile(
                      localItemId: null,
                      ownerFileId: fileRes.fileId,
                      forceRole: LibraryFileRoles.subtitle,
                      raw: subMap,
                      knownMountIds: knownMountIds,
                    );
                    if (subRes != null) {
                      itemFileKeys.add(subRes.fileKey);
                      filesCount++;
                    }
                  }
                }
              }
              await _pruneStaleCloudFilesForItem(projected.localId, itemFileKeys);
            }
          }
        }
      });

      var prunedCount = 0;
      if (hasFileChange || await _hasProjectedUnmatchedItems()) {
        final unmatchedRes = await _projectUnmatchedFilesFromServer(
          knownMountIds: knownMountIds,
          pruneStaleUnmatched: true,
        );
        itemsCount += unmatchedRes.itemsProjected;
        filesCount += unmatchedRes.filesProjected;
        prunedCount = unmatchedRes.pruned;
      }

      if (hasUserDataChange) {
        await _syncUserStateFromServer();
      }
      await _applyKvDeltas(kvOps);
      await _applyListDeltas(listOps);
      _lastDetailHydratedAt.clear();
      _lastSeq = changesPage.nextSinceSeq > _lastSeq ? changesPage.nextSinceSeq : changesPage.latestSeq;
      await _persistSeq(_lastSeq);
      onLibraryUpdated?.call();

      return CloudSyncResult(
        fullReset: false,
        latestSeq: _lastSeq,
        itemsProjected: itemsCount,
        filesProjected: filesCount,
        emptyShellsPruned: prunedCount,
        hasChanges: true,
      );
    }, queueIfBusy: true);
  }

  /// Lazily pulls full cloud item details (`summary`, `tagline`, `studio`,
  /// `genres`, `credits`, seasons, episodes & files) from `/api/v1/items/...`
  /// when the user opens a cloud item's detail screen. Never invokes offline
  /// local scrapers.
  Future<bool> hydrateItemDetailFromCloud(int localItemId, String workKey) {
    final trimmedKey = workKey.trim();
    if (trimmedKey.isEmpty || trimmedKey.startsWith('cloud:unmatched:')) {
      return Future<bool>.value(false);
    }
    int? cloudServerItemId;
    if (trimmedKey.startsWith('cloud:')) {
      cloudServerItemId = int.tryParse(trimmedKey.substring('cloud:'.length));
      if (cloudServerItemId == null || cloudServerItemId <= 0) {
        return Future<bool>.value(false);
      }
    }
    final existing = _inFlightDetailHydrations[trimmedKey];
    if (existing != null) return existing;

    final lastAt = _lastDetailHydratedAt[trimmedKey];
    if (lastAt != null && DateTime.now().difference(lastAt) < const Duration(seconds: 5)) {
      return Future<bool>.value(false);
    }

    late final Future<bool> future;
    future = () async {
      try {
        final detail = cloudServerItemId != null
            ? await syncClient.fetchItemDetail(cloudServerItemId)
            : await syncClient.fetchItemDetailByWorkKey(trimmedKey);
        if (detail.isEmpty) return false;

        final knownMountIds = (await db.select(db.mounts).get()).map((m) => m.id).toSet();
        late final ({int localId, String workKey})? projectedRoot;

        await db.transaction(() async {
          final serverIdToLocalId = <int, int>{};
          final serverIdToWorkKey = <int, String>{};
          projectedRoot = await _upsertProjectedItem(detail, serverIdToLocalId, serverIdToWorkKey);
          final root = projectedRoot;
          if (root == null) return;

          final serverRootId = (detail['id'] as num?)?.toInt() ?? 0;
          if (serverRootId > 0) {
            serverIdToLocalId[serverRootId] = root.localId;
            serverIdToWorkKey[serverRootId] = root.workKey;
          }

          Future<void> upsertItemFiles(int targetLocalId, List? filesList) async {
            if (filesList == null) return;
            final keepKeys = <String>{};
            for (final f in filesList) {
              if (f is! Map) continue;
              final fMap = Map<String, dynamic>.from(f);
              final fileRes = await _upsertProjectedFile(
                localItemId: targetLocalId,
                raw: fMap,
                knownMountIds: knownMountIds,
              );
              if (fileRes == null) continue;
              keepKeys.add(fileRes.fileKey);
              final subs = fMap['subtitles'];
              if (subs is List) {
                for (final s in subs) {
                  if (s is! Map) continue;
                  final subRes = await _upsertProjectedFile(
                    localItemId: null,
                    ownerFileId: fileRes.fileId,
                    forceRole: LibraryFileRoles.subtitle,
                    raw: Map<String, dynamic>.from(s),
                    knownMountIds: knownMountIds,
                  );
                  if (subRes != null) keepKeys.add(subRes.fileKey);
                }
              }
            }
            await _pruneStaleCloudFilesForItem(targetLocalId, keepKeys);
          }

          await upsertItemFiles(root.localId, detail['files'] as List?);

          final childrenRaw = detail['children'];
          if (childrenRaw is List) {
            for (final c in childrenRaw) {
              if (c is! Map) continue;
              final cMap = Map<String, dynamic>.from(c);
              final cid = (cMap['id'] as num?)?.toInt() ?? 0;
              final cp = await _upsertProjectedItem(cMap, serverIdToLocalId, serverIdToWorkKey);
              if (cp != null && cid > 0) {
                serverIdToLocalId[cid] = cp.localId;
                serverIdToWorkKey[cid] = cp.workKey;
                final cKind = (cMap['kind'] as String? ?? '').toLowerCase();
                if (cKind == LibraryKinds.episode) {
                  await upsertItemFiles(cp.localId, cMap['files'] as List?);
                }
              }
            }
          }

          final episodesRaw = detail['episodes'];
          if (episodesRaw is List) {
            for (final ep in episodesRaw) {
              if (ep is! Map) continue;
              final epMap = Map<String, dynamic>.from(ep);
              final eid = (epMap['id'] as num?)?.toInt() ?? 0;
              final epProj = await _upsertProjectedItem(epMap, serverIdToLocalId, serverIdToWorkKey);
              if (epProj != null) {
                if (eid > 0) {
                  serverIdToLocalId[eid] = epProj.localId;
                  serverIdToWorkKey[eid] = epProj.workKey;
                }
                await upsertItemFiles(epProj.localId, epMap['files'] as List?);
              }
            }
          }
        });

        final root = projectedRoot;
        if (root == null) return false;
        final repo = LibraryRepository(db);

        final genresRaw = detail['genres'];
        if (genresRaw is List) {
          await repo.setGenres(root.localId, [for (final g in genresRaw) '$g']);
        }
        final creditsRaw = detail['credits'];
        if (creditsRaw is List) {
          final credits = <({String name, String job, String? character, String? tmdbId, String? photoSource})>[];
          for (final c in creditsRaw) {
            if (c is! Map) continue;
            final name = _nonEmptyString(c['name']);
            final job = _nonEmptyString(c['job']) ?? 'actor';
            if (name == null) continue;
            final photo = _nonEmptyString(c['photo_url']) ?? _nonEmptyString(c['photo_source']);
            credits.add((
              name: name,
              job: job,
              character: _nonEmptyString(c['character']),
              tmdbId: null,
              photoSource: photo,
            ));
          }
          await repo.setCredits(root.localId, credits);
        }

        _lastDetailHydratedAt[trimmedKey] = DateTime.now();
        return true;
      } catch (e) {
        appLogger.d('Cloud detail hydration skipped for "$trimmedKey": $e');
        return false;
      } finally {
        if (identical(_inFlightDetailHydrations[trimmedKey], future)) {
          unawaited(_inFlightDetailHydrations.remove(trimmedKey));
        }
      }
    }();

    _inFlightDetailHydrations[trimmedKey] = future;
    return future;
  }

  /// Removes any projected movie/episode/season/show that has zero remaining
  /// video files in `LibraryFiles` (prevents empty-shell cards after single-source
  /// file deletion).
  Future<int> pruneEmptyProjectedItems() async {
    return db.transaction(() async {
      final deletedLeafs = await db.customUpdate(
        "DELETE FROM library_items WHERE kind IN ('movie', 'episode') AND NOT EXISTS "
        "(SELECT 1 FROM library_files f WHERE f.item_id = library_items.id AND f.role = 'video')",
        updates: {db.libraryItems},
        updateKind: UpdateKind.delete,
      );
      final deletedSeasons = await db.customUpdate(
        "DELETE FROM library_items WHERE kind = 'season' AND NOT EXISTS "
        '(SELECT 1 FROM library_items c WHERE c.parent_id = library_items.id)',
        updates: {db.libraryItems},
        updateKind: UpdateKind.delete,
      );
      final deletedShows = await db.customUpdate(
        "DELETE FROM library_items WHERE kind = 'show' AND NOT EXISTS "
        '(SELECT 1 FROM library_items c WHERE c.parent_id = library_items.id)',
        updates: {db.libraryItems},
        updateKind: UpdateKind.delete,
      );
      return deletedLeafs + deletedSeasons + deletedShows;
    });
  }

  /// Subscribes to `/api/v1/events` SSE and triggers debounced incremental sync,
  /// automatically reconnecting with exponential backoff if the stream drops.
  void startListeningEvents() {
    stopListeningEvents();
    _listeningEvents = true;
    _sseReconnectAttempts = 0;
    _hasConnectedSseOnce = false;
    _connectSse();
  }

  void _connectSse() {
    if (!_listeningEvents) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    unawaited(_sseSub?.cancel());
    final isReconnect = _hasConnectedSseOnce;
    _hasConnectedSseOnce = true;

    _sseSub = syncClient.watchEvents().listen(
      (event) {
        _sseReconnectAttempts = 0;
        if (event.type == 'library.changed' ||
            event.type == 'source.changed' ||
            event.type == 'userdata.changed' ||
            event.type == 'credential.status') {
          _debounceTimer?.cancel();
          _debounceTimer = Timer(const Duration(milliseconds: 600), () {
            unawaited(_runSafeIncremental());
          });
        }
      },
      onError: (Object err) {
        appLogger.d('CloudProjectionEngine SSE disconnected: $err');
        _scheduleSseReconnect();
      },
      onDone: () {
        if (_listeningEvents) {
          appLogger.d('CloudProjectionEngine SSE stream closed, scheduling reconnect');
          _scheduleSseReconnect();
        }
      },
      cancelOnError: true,
    );

    if (isReconnect) {
      _debounceTimer?.cancel();
      _debounceTimer = Timer(const Duration(milliseconds: 600), () {
        unawaited(_runSafeIncremental());
      });
    }
  }

  void _scheduleSseReconnect() {
    if (!_listeningEvents) return;
    if (_reconnectTimer?.isActive == true) return;
    const delays = <int>[2, 4, 8, 15, 30];
    final idx = _sseReconnectAttempts < delays.length ? _sseReconnectAttempts : delays.length - 1;
    _sseReconnectAttempts++;
    _reconnectTimer = Timer(Duration(seconds: delays[idx]), () {
      _reconnectTimer = null;
      _connectSse();
    });
  }

  Future<void> _runSafeIncremental() async {
    if (!_listeningEvents) return;
    try {
      await syncIncremental();
    } catch (e) {
      appLogger.w('CloudProjectionEngine incremental sync failed: $e');
    }
  }

  void stopListeningEvents() {
    _listeningEvents = false;
    _resyncQueued = false;
    _hasConnectedSseOnce = false;
    _sseReconnectAttempts = 0;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _resyncTimer?.cancel();
    _resyncTimer = null;
    unawaited(_sseSub?.cancel());
    _sseSub = null;
  }

  static String? _nonEmptyString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  Future<({int localId, String workKey})?> _upsertProjectedItem(
    Map<String, dynamic> raw,
    Map<int, int> serverIdToLocalId,
    Map<int, String> serverIdToWorkKey,
  ) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final kind = (raw['kind'] as String? ?? LibraryKinds.movie).toLowerCase();
    final libraryType = (raw['library_type'] as String? ?? kind).toLowerCase();
    final title = (raw['title'] as String? ?? '').trim();
    final sortTitle = _nonEmptyString(raw['sort_title']) ?? title.toLowerCase();
    final seasonNumber = (raw['season_number'] as num?)?.toInt();
    final episodeNumber = (raw['episode_number'] as num?)?.toInt();

    final serverParentId = (raw['parent_id'] as num?)?.toInt();
    final serverShowId = (raw['show_id'] as num?)?.toInt();
    final effectiveServerShowId = serverShowId ?? (kind == LibraryKinds.season ? serverParentId : null);
    final localParentId = serverParentId != null ? serverIdToLocalId[serverParentId] : null;
    final localShowId = effectiveServerShowId != null ? serverIdToLocalId[effectiveServerShowId] : null;

    if (kind == LibraryKinds.season && localParentId == null) return null;
    if (kind == LibraryKinds.episode && (localParentId == null || localShowId == null)) return null;

    final rawWorkKey = (raw['work_key'] as String? ?? '').trim();
    final normalizedRawKey = rawWorkKey.isEmpty ? '' : DeterministicKeys.canonicalizeWorkKey(rawWorkKey);
    final parentShowKey =
        (effectiveServerShowId != null ? serverIdToWorkKey[effectiveServerShowId] : null) ??
        _nonEmptyString(raw['show_work_key']);
    final isChildItem = kind == LibraryKinds.season || kind == LibraryKinds.episode;
    final hasInvalidChildWorkKey =
        isChildItem &&
        (normalizedRawKey.isEmpty ||
            (parentShowKey != null && normalizedRawKey == DeterministicKeys.canonicalizeWorkKey(parentShowKey)) ||
            (kind == LibraryKinds.season && !RegExp(r':s\d+$').hasMatch(normalizedRawKey)) ||
            (kind == LibraryKinds.episode && !RegExp(r':e\d+$').hasMatch(normalizedRawKey)));
    String workKey;
    if (normalizedRawKey.isNotEmpty && !hasInvalidChildWorkKey) {
      workKey = normalizedRawKey;
    } else {
      if (parentShowKey != null && parentShowKey.isNotEmpty && !parentShowKey.startsWith('cloud:')) {
        if (kind == LibraryKinds.season && seasonNumber != null) {
          workKey = '$parentShowKey:s$seasonNumber';
        } else if (kind == LibraryKinds.episode && seasonNumber != null && episodeNumber != null) {
          workKey = '$parentShowKey:s$seasonNumber:e$episodeNumber';
        } else {
          workKey = 'cloud:${raw['id']}';
        }
      } else {
        workKey = 'cloud:${raw['id']}';
      }
    }

    var tmdbId = _nonEmptyString(raw['tmdb_id']);
    var imdbId = _nonEmptyString(raw['imdb_id']);
    var tvdbId = _nonEmptyString(raw['tvdb_id']);
    String? bangumiId;
    String? doubanId;
    if (kind == LibraryKinds.movie || kind == LibraryKinds.show) {
      final wkParts = workKey.split(':');
      if (wkParts.length >= 3) {
        final wkProvider = wkParts[0].trim().toLowerCase();
        final wkExtId = wkParts[2].trim();
        if (wkExtId.isNotEmpty) {
          switch (wkProvider) {
            case 'tmdb':
              tmdbId ??= wkExtId;
            case 'imdb':
              imdbId ??= wkExtId;
            case 'tvdb':
              tvdbId ??= wkExtId;
            case 'bangumi':
              bangumiId = wkExtId;
            case 'douban':
              doubanId = wkExtId;
          }
        }
      }
    }
    final metadataSource = tmdbId != null
        ? 'tmdb'
        : (imdbId != null
              ? 'imdb'
              : (tvdbId != null ? 'tvdb' : (bangumiId != null ? 'bangumi' : (doubanId != null ? 'douban' : null))));

    final poster = _nonEmptyString(raw['poster_url']) ?? _nonEmptyString(raw['poster_source']);
    final backdrop = _nonEmptyString(raw['backdrop_url']) ?? _nonEmptyString(raw['backdrop_source']);
    final logo = _nonEmptyString(raw['logo_url']) ?? _nonEmptyString(raw['logo_source']);
    final sourceAddedAt = (raw['source_added_at'] as num?)?.toInt();

    Value<String?> aliasesVal = const Value.absent();
    if (raw.containsKey('aliases')) {
      final rawAliases = raw['aliases'];
      if (rawAliases is List) {
        final list = [
          for (final a in rawAliases)
            if ('$a'.trim().isNotEmpty) '$a'.trim(),
        ];
        aliasesVal = Value(list.isEmpty ? null : list.join('\n'));
      } else if (rawAliases is String) {
        aliasesVal = Value(_nonEmptyString(rawAliases));
      }
    }

    final existing = await (db.select(db.libraryItems)..where((t) => t.workKey.equals(workKey))).getSingleOrNull();
    final companion = LibraryItemsCompanion(
      workKey: Value(workKey),
      kind: Value(kind),
      libraryType: Value(libraryType),
      parentId: Value(localParentId),
      showId: Value(localShowId),
      title: Value(title),
      sortTitle: Value(sortTitle),
      originalTitle: Value(_nonEmptyString(raw['original_title'])),
      aliases: aliasesVal,
      year: Value((raw['year'] as num?)?.toInt()),
      releaseDate: Value(_nonEmptyString(raw['release_date'])),
      summary: Value(_nonEmptyString(raw['summary'])),
      tagline: raw.containsKey('tagline') ? Value(_nonEmptyString(raw['tagline'])) : const Value.absent(),
      studio: raw.containsKey('studio') ? Value(_nonEmptyString(raw['studio'])) : const Value.absent(),
      contentRating: Value(_nonEmptyString(raw['content_rating'])),
      rating: Value((raw['rating'] as num?)?.toDouble()),
      runtimeMs: Value((raw['runtime_ms'] as num?)?.toInt()),
      totalEpisodes: raw.containsKey('total_episodes')
          ? Value(((raw['total_episodes'] as num?)?.toInt() ?? 0) > 0 ? (raw['total_episodes'] as num).toInt() : null)
          : const Value.absent(),
      seasonNumber: Value(seasonNumber),
      episodeNumber: Value(episodeNumber),
      posterSource: poster != null ? Value(poster) : const Value.absent(),
      backdropSource: backdrop != null ? Value(backdrop) : const Value.absent(),
      logoSource: logo != null ? Value(logo) : const Value.absent(),
      tmdbId: tmdbId != null ? Value(tmdbId) : const Value.absent(),
      imdbId: imdbId != null ? Value(imdbId) : const Value.absent(),
      tvdbId: tvdbId != null ? Value(tvdbId) : const Value.absent(),
      bangumiId: bangumiId != null ? Value(bangumiId) : const Value.absent(),
      doubanId: doubanId != null ? Value(doubanId) : const Value.absent(),
      metadataSource: metadataSource != null ? Value(metadataSource) : const Value.absent(),
      addedAt: Value((raw['added_at'] as num?)?.toInt() ?? nowMs),
      sourceAddedAt: sourceAddedAt != null ? Value(sourceAddedAt) : const Value.absent(),
      updatedAt: Value((raw['updated_at'] as num?)?.toInt() ?? nowMs),
      scrapedAt: Value((raw['updated_at'] as num?)?.toInt() ?? nowMs),
    );

    if (existing != null) {
      await (db.update(db.libraryItems)..where((t) => t.id.equals(existing.id))).write(companion);
      return (localId: existing.id, workKey: workKey);
    }
    final insertedId = await db.into(db.libraryItems).insert(companion);
    return (localId: insertedId, workKey: workKey);
  }

  Future<({int fileId, String fileKey})?> _upsertProjectedFile({
    required int? localItemId,
    required Map<String, dynamic> raw,
    int? ownerFileId,
    String? forceRole,
    Set<String>? knownMountIds,
    String matchState = LibraryMatchStates.matched,
  }) async {
    final sourceId = (raw['source_id'] as String? ?? '').trim();
    final path = (raw['path'] as String? ?? '').trim();
    if (sourceId.isEmpty || path.isEmpty) return null;

    final mountId = CloudMountMirror.mountIdForSource(sourceId);
    if (knownMountIds != null) {
      if (!knownMountIds.contains(mountId)) return null;
    } else {
      final mountExists = await (db.select(db.mounts)..where((m) => m.id.equals(mountId))).getSingleOrNull();
      if (mountExists == null) return null;
    }

    final fileKey = DeterministicKeys.generateFileId(sourceId: mountId, mountRelativePath: path);
    final existing = await (db.select(
      db.libraryFiles,
    )..where((f) => f.fileKey.equals(fileKey) | (f.mountId.equals(mountId) & f.path.equals(path)))).getSingleOrNull();

    final rawMtime = (raw['mtime_s'] as num?)?.toInt();
    final modifiedAtMs = rawMtime == null
        ? null
        : (rawMtime > 0 && rawMtime < 100000000000 ? rawMtime * 1000 : rawMtime);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final companion = LibraryFilesCompanion(
      fileKey: Value(fileKey),
      mountId: Value(mountId),
      path: Value(path),
      remoteId: Value(_nonEmptyString(raw['remote_id'])),
      size: Value((raw['size'] as num?)?.toInt()),
      modifiedAt: Value(modifiedAtMs),
      role: Value((forceRole ?? (raw['role'] as String?) ?? LibraryFileRoles.video).toLowerCase()),
      itemId: Value(localItemId),
      ownerFileId: Value(ownerFileId),
      matchState: Value(matchState),
      versionLabel: Value(_nonEmptyString(raw['version_label'])),
      language: Value(_nonEmptyString(raw['language'])),
      addedAt: Value((raw['added_at'] as num?)?.toInt() ?? nowMs),
    );

    if (existing != null) {
      await (db.update(db.libraryFiles)..where((f) => f.id.equals(existing.id))).write(companion);
      return (fileId: existing.id, fileKey: fileKey);
    }
    final insertedId = await db.into(db.libraryFiles).insert(companion);
    return (fileId: insertedId, fileKey: fileKey);
  }

  static String _titleFromUnmatchedPath(String path) {
    final base = StoragePath.name(path);
    if (base.isEmpty) return path;
    final dot = base.lastIndexOf('.');
    if (dot > 0 && dot < base.length - 1) {
      return base.substring(0, dot);
    }
    return base;
  }

  Future<bool> _hasProjectedUnmatchedItems() async {
    final row = await db
        .customSelect("SELECT 1 FROM library_items WHERE work_key LIKE 'cloud:unmatched:%' LIMIT 1")
        .getSingleOrNull();
    return row != null;
  }

  Future<({int itemsProjected, int filesProjected, int pruned})> _projectUnmatchedFilesFromServer({
    required Set<String> knownMountIds,
    Set<String>? projectedCloudFileKeys,
    bool pruneStaleUnmatched = false,
  }) async {
    final collected = <Map<String, dynamic>>[];
    try {
      const pageSize = 200;
      const maxPages = 50;
      var page = 1;
      var fetched = 0;
      while (page <= maxPages) {
        final res = await syncClient.listUnmatched(page: page, pageSize: pageSize, state: 'all');
        collected.addAll(res.items);
        fetched += res.items.length;
        if (res.items.isEmpty || fetched >= res.total || res.items.length < pageSize) {
          break;
        }
        page++;
      }
    } catch (e) {
      appLogger.d('CloudProjectionEngine: unmatched projection skipped: $e');
      return (itemsProjected: 0, filesProjected: 0, pruned: 0);
    }

    var itemsCount = 0;
    var filesCount = 0;
    var prunedCount = 0;
    final activeUnmatchedFileKeys = <String>{};

    await db.transaction(() async {
      final matchedCloudKeys =
          projectedCloudFileKeys ??
          await () async {
            final rows =
                await (db.select(db.libraryFiles)..where(
                      (f) =>
                          f.mountId.like('${CloudMountMirror.cloudMountPrefix}%') &
                          f.matchState.equals(LibraryMatchStates.matched),
                    ))
                    .get();
            return <String>{
              for (final r in rows)
                if (r.fileKey != null && r.fileKey!.isNotEmpty) r.fileKey!,
            };
          }();

      final nowMs = DateTime.now().millisecondsSinceEpoch;
      for (final raw in collected) {
        final rawMatchState = (raw['match_state'] as String? ?? 'unmatched').trim().toLowerCase();
        if (rawMatchState != LibraryMatchStates.unmatched && rawMatchState != LibraryMatchStates.pending) {
          continue;
        }
        final sourceId = (raw['source_id'] as String? ?? '').trim();
        final path = (raw['path'] as String? ?? '').trim();
        if (sourceId.isEmpty || path.isEmpty) continue;

        final mountId = CloudMountMirror.mountIdForSource(sourceId);
        if (!knownMountIds.contains(mountId)) continue;

        final fileKey = DeterministicKeys.generateFileId(sourceId: mountId, mountRelativePath: path);
        if (matchedCloudKeys.contains(fileKey)) continue;

        final serverFileId = (raw['id'] as num?)?.toInt() ?? 0;
        final workKey = serverFileId > 0 ? 'cloud:unmatched:$serverFileId' : 'cloud:unmatched:$fileKey';
        final title = _titleFromUnmatchedPath(path);
        final parsed = raw['parsed'];
        final year = parsed is Map ? (parsed['year'] as num?)?.toInt() : null;
        final addedAtMs = (raw['added_at'] as num?)?.toInt() ?? nowMs;
        final updatedAtMs = (raw['updated_at'] as num?)?.toInt() ?? nowMs;
        final fileMatchState = rawMatchState == LibraryMatchStates.pending
            ? LibraryMatchStates.pending
            : LibraryMatchStates.unmatched;

        final existingItem = await (db.select(
          db.libraryItems,
        )..where((t) => t.workKey.equals(workKey))).getSingleOrNull();
        final itemCompanion = LibraryItemsCompanion(
          workKey: Value(workKey),
          kind: const Value(LibraryKinds.movie),
          libraryType: const Value(LibraryTypes.pending),
          parentId: const Value(null),
          showId: const Value(null),
          title: Value(title),
          sortTitle: Value(title.toLowerCase()),
          year: Value(year),
          addedAt: Value(addedAtMs),
          updatedAt: Value(updatedAtMs),
          scrapedAt: fileMatchState == LibraryMatchStates.pending ? const Value(null) : Value(updatedAtMs),
        );

        final int localItemId;
        if (existingItem != null) {
          await (db.update(db.libraryItems)..where((t) => t.id.equals(existingItem.id))).write(itemCompanion);
          localItemId = existingItem.id;
        } else {
          localItemId = await db.into(db.libraryItems).insert(itemCompanion);
        }
        itemsCount++;

        final fileRes = await _upsertProjectedFile(
          localItemId: localItemId,
          raw: raw,
          knownMountIds: knownMountIds,
          matchState: fileMatchState,
        );
        if (fileRes != null) {
          activeUnmatchedFileKeys.add(fileRes.fileKey);
          projectedCloudFileKeys?.add(fileRes.fileKey);
          filesCount++;
        }
      }

      if (pruneStaleUnmatched) {
        final existingUnmatchedFiles =
            await (db.select(db.libraryFiles)..where(
                  (f) =>
                      f.mountId.like('${CloudMountMirror.cloudMountPrefix}%') &
                      f.matchState.isIn([LibraryMatchStates.unmatched, LibraryMatchStates.pending]),
                ))
                .get();
        for (final f in existingUnmatchedFiles) {
          final key = f.fileKey;
          if (key == null || !activeUnmatchedFileKeys.contains(key)) {
            await (db.delete(db.libraryFiles)..where((t) => t.id.equals(f.id))).go();
            prunedCount++;
          }
        }
        final deletedOrphanItems = await db.customUpdate(
          "DELETE FROM library_items WHERE work_key LIKE 'cloud:unmatched:%' AND NOT EXISTS "
          "(SELECT 1 FROM library_files f WHERE f.item_id = library_items.id AND f.role = 'video')",
          updates: {db.libraryItems},
          updateKind: UpdateKind.delete,
        );
        prunedCount += deletedOrphanItems;
      }
    });

    return (itemsProjected: itemsCount, filesProjected: filesCount, pruned: prunedCount);
  }

  Future<void> _pruneStaleCloudFilesForItem(int localItemId, Set<String> keepFileKeys) async {
    final itemFiles = await (db.select(
      db.libraryFiles,
    )..where((f) => f.mountId.like('${CloudMountMirror.cloudMountPrefix}%') & f.itemId.equals(localItemId))).get();
    final itemVideoIds = <int>[];
    for (final f in itemFiles) {
      itemVideoIds.add(f.id);
      final key = f.fileKey;
      if (key == null || !keepFileKeys.contains(key)) {
        await (db.delete(db.libraryFiles)..where((t) => t.id.equals(f.id))).go();
      }
    }
    if (itemVideoIds.isNotEmpty) {
      final subFiles =
          await (db.select(db.libraryFiles)..where(
                (f) => f.mountId.like('${CloudMountMirror.cloudMountPrefix}%') & f.ownerFileId.isIn(itemVideoIds),
              ))
              .get();
      for (final s in subFiles) {
        final key = s.fileKey;
        if (key == null || !keepFileKeys.contains(key)) {
          await (db.delete(db.libraryFiles)..where((t) => t.id.equals(s.id))).go();
        }
      }
    }
  }

  Future<void> _pruneStaleCloudFiles(Set<String> keepFileKeys) async {
    await db.transaction(() async {
      final cloudFiles = await (db.select(
        db.libraryFiles,
      )..where((f) => f.mountId.like('${CloudMountMirror.cloudMountPrefix}%'))).get();
      for (final f in cloudFiles) {
        final key = f.fileKey;
        if (key == null || !keepFileKeys.contains(key)) {
          await (db.delete(db.libraryFiles)..where((t) => t.id.equals(f.id))).go();
        }
      }
    });
  }

  static ({SyncConfigScope scope, String namespace, String itemKey})? _extractKvDeleteTarget(
    Object? data,
    String? entityId,
  ) {
    if (data is Map) {
      final scope = SyncConfigScope.fromWireName(data['scope'] as String?);
      final ns = (data['namespace'] as String? ?? '').trim();
      final key = (data['item_key'] as String? ?? '').trim();
      if (scope != null && ns.isNotEmpty && key.isNotEmpty) {
        return (scope: scope, namespace: ns, itemKey: key);
      }
    }
    if (entityId != null && entityId.isNotEmpty) {
      final parts = entityId.split('|');
      if (parts.length == 3) {
        try {
          final scope = SyncConfigScope.fromWireName(Uri.decodeComponent(parts[0]));
          final ns = Uri.decodeComponent(parts[1]).trim();
          final key = Uri.decodeComponent(parts[2]).trim();
          if (scope != null && ns.isNotEmpty && key.isNotEmpty) {
            return (scope: scope, namespace: ns, itemKey: key);
          }
        } catch (_) {}
      }
    }
    return null;
  }

  Future<bool> _applyKvDeltas(
    List<({bool isDelete, Map<String, dynamic>? entry, SyncConfigScope? scope, String? namespace, String? itemKey})>
    ops,
  ) async {
    if (ops.isEmpty) return false;
    var applied = false;
    for (final op in ops) {
      if (op.isDelete) {
        if (await _syncConfigStore.applyRemoteDelete(
          scope: op.scope!,
          namespace: op.namespace!,
          itemKey: op.itemKey!,
        )) {
          applied = true;
        }
      } else if (op.entry != null) {
        if (await _syncConfigStore.applyRemoteEntry(op.entry!)) {
          applied = true;
        }
      }
    }
    return applied;
  }

  Future<bool> _applyListDeltas(List<({bool isDelete, Map<String, dynamic>? list, String? cloudListId})> ops) async {
    if (ops.isEmpty) return false;
    var applied = false;
    await db.transaction(() async {
      for (final op in ops) {
        if (op.isDelete) {
          if (await _deleteProjectedList(op.cloudListId!)) {
            applied = true;
          }
        } else if (op.list != null) {
          if (await _upsertProjectedList(op.list!) != null) {
            applied = true;
          }
        }
      }
    });
    return applied;
  }

  /// Removes all cloud-mapped collections and playlists while preserving
  /// local-only unmapped lists.
  Future<void> clearProjectedLists() async {
    const prefix = 'cloud-list-local:';
    await db.transaction(() async {
      final mappingRows = await (db.select(db.librarySettings)..where((t) => t.key.like('$prefix%'))).get();
      for (final row in mappingRows) {
        if (!row.key.startsWith(prefix)) continue;
        final cloudId = row.key.substring(prefix.length);
        await _deleteProjectedList(cloudId);
      }
    });
  }

  Future<String?> _upsertProjectedList(Map<String, dynamic> raw) async {
    final cloudId = (raw['id'] as String? ?? '').trim();
    final kind = (raw['kind'] as String? ?? '').trim().toLowerCase();
    final title = (raw['title'] as String? ?? '').trim();
    if (cloudId.isEmpty || title.isEmpty) return null;
    if (kind != LibraryListKinds.collection && kind != LibraryListKinds.playlist) return null;

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final createdAt = (raw['created_at'] as num?)?.toInt() ?? nowMs;
    final updatedAt = (raw['updated_at'] as num?)?.toInt() ?? nowMs;
    final summary = _nonEmptyString(raw['summary']);
    final poster = _nonEmptyString(raw['poster_source']);
    final tmdbId = _nonEmptyString(raw['tmdb_id']);

    final localMapKey = 'cloud-list-local:$cloudId';
    final mapRow = await (db.select(db.librarySettings)..where((t) => t.key.equals(localMapKey))).getSingleOrNull();
    var localListId = mapRow == null ? null : int.tryParse(mapRow.value);
    if (localListId != null) {
      final existing = await (db.select(db.libraryLists)..where((t) => t.id.equals(localListId!))).getSingleOrNull();
      if (existing == null) {
        localListId = null;
      }
    }

    if (localListId != null) {
      await (db.update(db.libraryLists)..where((t) => t.id.equals(localListId!))).write(
        LibraryListsCompanion(
          kind: Value(kind),
          title: Value(title),
          summary: Value(summary),
          posterSource: Value(poster),
          tmdbId: Value(tmdbId),
          updatedAt: Value(updatedAt),
        ),
      );
    } else {
      localListId = await db
          .into(db.libraryLists)
          .insert(
            LibraryListsCompanion.insert(
              kind: kind,
              title: title,
              summary: Value(summary),
              posterSource: Value(poster),
              tmdbId: Value(tmdbId),
              createdAt: createdAt,
              updatedAt: updatedAt,
            ),
          );
      await db
          .into(db.librarySettings)
          .insertOnConflictUpdate(LibrarySettingsCompanion.insert(key: localMapKey, value: '$localListId'));
      await db
          .into(db.librarySettings)
          .insertOnConflictUpdate(LibrarySettingsCompanion.insert(key: 'cloud-list-id:$localListId', value: cloudId));
    }

    final entriesRaw = raw['entries'];
    if (entriesRaw is List) {
      await (db.delete(db.libraryListItems)..where((t) => t.listId.equals(localListId!))).go();
      for (var i = 0; i < entriesRaw.length; i++) {
        final e = entriesRaw[i];
        if (e is! Map) continue;
        final wk = (e['work_key'] as String? ?? '').trim();
        if (wk.isEmpty) continue;
        final sNum = (e['season_number'] as num?)?.toInt() ?? -1;
        final eNum = (e['episode_number'] as num?)?.toInt() ?? -1;
        final sortOrder = (e['sort_order'] as num?)?.toInt() ?? i;
        final localItem = await _resolveLocalItemForListEntry(wk, sNum, eNum);
        if (localItem == null) continue;
        await db
            .into(db.libraryListItems)
            .insert(
              LibraryListItemsCompanion.insert(listId: localListId, itemId: localItem.id, sortOrder: Value(sortOrder)),
              mode: InsertMode.insertOrIgnore,
            );
      }
    }
    return cloudId;
  }

  Future<LibraryItemRow?> _resolveLocalItemForListEntry(String rawWorkKey, int seasonNum, int episodeNum) async {
    final wk = DeterministicKeys.canonicalizeWorkKey(rawWorkKey);
    if (wk.isEmpty) return null;
    if (episodeNum >= 0) {
      final s = seasonNum < 0 ? 0 : seasonNum;
      final epKey = '$wk:s$s:e$episodeNum';
      final ep = await (db.select(db.libraryItems)..where((t) => t.workKey.equals(epKey))).getSingleOrNull();
      if (ep != null) return ep;
      final show = await (db.select(db.libraryItems)..where((t) => t.workKey.equals(wk))).getSingleOrNull();
      if (show != null) {
        return (db.select(db.libraryItems)..where(
              (t) =>
                  t.showId.equals(show.id) &
                  t.kind.equals(LibraryKinds.episode) &
                  t.seasonNumber.equals(s) &
                  t.episodeNumber.equals(episodeNum),
            ))
            .getSingleOrNull();
      }
      return null;
    }
    return (db.select(db.libraryItems)..where((t) => t.workKey.equals(wk))).getSingleOrNull();
  }

  Future<bool> _deleteProjectedList(String cloudListId) async {
    final localMapKey = 'cloud-list-local:$cloudListId';
    final row = await (db.select(db.librarySettings)..where((t) => t.key.equals(localMapKey))).getSingleOrNull();
    var removed = false;
    if (row != null) {
      final localId = int.tryParse(row.value);
      if (localId != null) {
        final cnt = await (db.delete(db.libraryLists)..where((t) => t.id.equals(localId))).go();
        removed = cnt > 0;
        await (db.delete(db.librarySettings)..where((t) => t.key.equals('cloud-list-id:$localId'))).go();
      }
      await (db.delete(db.librarySettings)..where((t) => t.key.equals(localMapKey))).go();
    }
    return removed;
  }

  Future<void> _syncListsFromServer(List<Map<String, dynamic>> remoteLists) async {
    final activeCloudIds = <String>{};
    await db.transaction(() async {
      for (final raw in remoteLists) {
        final id = await _upsertProjectedList(raw);
        if (id != null) activeCloudIds.add(id);
      }
      const prefix = 'cloud-list-local:';
      final mappingRows = await (db.select(db.librarySettings)..where((t) => t.key.like('$prefix%'))).get();
      for (final row in mappingRows) {
        if (!row.key.startsWith(prefix)) continue;
        final cloudId = row.key.substring(prefix.length);
        if (!activeCloudIds.contains(cloudId)) {
          await _deleteProjectedList(cloudId);
        }
      }
    });
  }

  Future<void> _syncUserStateFromServer() async {
    try {
      final (progressList, favList) = await (syncClient.listProgress(limit: 500), syncClient.listFavorites()).wait;
      List<Map<String, dynamic>> kvList = const [];
      try {
        kvList = await syncClient.listKv(includeDeleted: true);
      } catch (e) {
        appLogger.d('CloudProjectionEngine: kv list unavailable, skipping: $e');
      }
      List<Map<String, dynamic>>? remoteLists;
      try {
        remoteLists = await syncClient.listLists(includeEntries: true);
      } catch (e) {
        appLogger.d('CloudProjectionEngine: lists unavailable, skipping: $e');
      }
      final favKeys = <String>{
        for (final f in favList)
          if ((f['work_key'] as String?)?.isNotEmpty == true)
            DeterministicKeys.canonicalizeWorkKey(f['work_key'] as String),
      };

      final watchStates = LibraryWatchStateStore(db);
      await db.transaction(() async {
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        for (final p in progressList) {
          final rawWk = (p['work_key'] as String? ?? '').trim();
          final rawProgKey = (p['progress_key'] as String? ?? '').trim();
          final wk = rawWk.isNotEmpty ? DeterministicKeys.canonicalizeWorkKey(rawWk) : '';
          final seasonNum = (p['season_number'] as num?)?.toInt() ?? 0;
          final episodeNum = (p['episode_number'] as num?)?.toInt() ?? 0;
          final isEpisodeProgress = episodeNum > 0 || (rawProgKey.contains(':s') && rawProgKey.contains(':e'));

          LibraryItemRow? item;
          if (isEpisodeProgress) {
            final epKey = rawProgKey.isNotEmpty
                ? DeterministicKeys.canonicalizeWorkKey(rawProgKey)
                : (wk.isNotEmpty ? '$wk:s$seasonNum:e$episodeNum' : '');
            if (epKey.isNotEmpty) {
              item = await (db.select(db.libraryItems)..where((t) => t.workKey.equals(epKey))).getSingleOrNull();
            }
            if (item == null && wk.isNotEmpty) {
              final show = await (db.select(db.libraryItems)..where((t) => t.workKey.equals(wk))).getSingleOrNull();
              if (show != null) {
                item =
                    await (db.select(db.libraryItems)..where(
                          (t) =>
                              t.showId.equals(show.id) &
                              t.kind.equals(LibraryKinds.episode) &
                              t.seasonNumber.equals(seasonNum) &
                              t.episodeNumber.equals(episodeNum),
                        ))
                        .getSingleOrNull();
              }
            }
          } else if (wk.isNotEmpty) {
            item = await (db.select(db.libraryItems)..where((t) => t.workKey.equals(wk))).getSingleOrNull();
          }
          if (item == null) continue;

          await watchStates.applyRemoteProgress(
            item: item,
            positionMs: (p['position_ms'] as num?)?.toInt() ?? 0,
            durationMs: (p['duration_ms'] as num?)?.toInt(),
            watched: p['watched'] == true,
            playCount: (p['play_count'] as num?)?.toInt() ?? 0,
            lastPlayedAt: (p['last_played_at'] as num?)?.toInt(),
            favorite: !isEpisodeProgress && wk.isNotEmpty && favKeys.contains(wk),
            hiddenFromContinue: p['hidden_from_continue'] == true,
            updatedAt: (p['updated_at'] as num?)?.toInt() ?? nowMs,
          );
        }

        for (final favWk in favKeys) {
          final item = await (db.select(db.libraryItems)..where((t) => t.workKey.equals(favWk))).getSingleOrNull();
          if (item == null) continue;
          await watchStates.applyRemoteFavorite(item: item, favorite: true, updatedAt: nowMs);
        }
      });

      for (final entry in kvList) {
        await _syncConfigStore.applyRemoteEntry(entry);
      }
      if (remoteLists != null) {
        await _syncListsFromServer(remoteLists);
      }
    } catch (e) {
      appLogger.d('CloudProjectionEngine: skipped user state sync: $e');
    }
  }
}
