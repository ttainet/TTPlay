import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:drift/drift.dart' show Variable;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../iptv/iptv_provider.dart';
import '../library/deterministic_keys.dart';
import '../library/local_library_client.dart';
import '../library/scrapers/server_metadata_provider.dart';
import '../library_cloud/cloud_api_client.dart';
import '../library_cloud/cloud_external_mirror_store.dart';
import '../library_cloud/cloud_mount_mirror.dart';
import '../library_cloud/cloud_projection_engine.dart';
import '../library_cloud/projection_sync.dart';
import '../library_cloud/scan_session_runner.dart';
import '../library_cloud/source_repository.dart';
import '../media/ids.dart';
import '../media/library_change_event.dart';
import '../providers/multi_server_provider.dart';
import '../services/cloud_synced_settings_bridge.dart';
import '../services/multi_server_manager.dart';
import '../services/sync_config_store.dart';
import '../session/app_session_controller.dart';
import '../session/app_session_models.dart';
import '../storage/storage_mount.dart';
import '../utils/app_logger.dart';
import '../utils/library_content_notifier.dart';
import '../utils/platform_detector.dart';
import 'ttplay_admin_service.dart';
import 'ttplay_api_client.dart';
import 'ttplay_external_server_client.dart';
import 'ttplay_server_client.dart';

/// Synchronizes [AppSessionController] mode transitions (`offline` vs
/// `selfHosted`) with [MultiServerManager] and [MultiServerProvider].
class TtplaySessionBinder extends ChangeNotifier {
  TtplaySessionBinder({
    required this.sessionController,
    required this.serverManager,
    required this.localLibraryClient,
    this.syncConfigStore,
    this.settingsSyncBridge,
    bool Function()? isTv,
    this.httpClientFactory,
    this.onLocalLibraryMutated,
  }) : _isTv = isTv ?? PlatformDetector.isTV;

  final AppSessionController sessionController;
  final MultiServerManager serverManager;
  final LocalLibraryClient localLibraryClient;
  final SyncConfigStore? syncConfigStore;
  final CloudSyncedSettingsBridge? settingsSyncBridge;
  final bool Function() _isTv;
  final http.Client Function()? httpClientFactory;
  final VoidCallback? onLocalLibraryMutated;

  MultiServerProvider? _multiServerProvider;
  IptvProvider? _iptvProvider;
  TtplayApiClient? _apiClient;
  TtplayAdminService? _adminService;
  CloudApiClient? _cloudApiClient;
  CloudSourceRepository? _cloudSourceRepository;
  CloudScanSessionRunner? _cloudScanRunner;
  CloudProjectionSyncClient? _cloudProjectionSync;
  CloudMountMirror? _cloudMountMirror;
  CloudProjectionEngine? _cloudProjectionEngine;
  TtplayServerClient? _primaryClient;
  List<TtplayExternalServerClient> _externalClients = const [];
  List<TtplayExternalServerSummary> _externalSummaries = const [];
  Set<String> _directCloudExternalServerIds = const {};
  final Set<String> _recentlyVerifiedExternalServerIds = <String>{};
  String? _boundSessionKey;
  Object? _lastExternalRefreshError;
  int _syncGeneration = 0;
  bool _disposed = false;
  Future<void>? _pendingProjectionRefresh;
  Timer? _batchSyncTimer;
  Timer? _postScanSyncTimer1;
  Timer? _postScanSyncTimer2;
  Timer? _cloudIncrementalTimer;
  bool _checkingCloudIncremental = false;
  final Map<String, DateTime> _lastCloudIncrementalBySource = {};
  DateTime? _lastManualCloudIncrementalAt;

  static const Duration _cloudIncrementalTick = Duration(minutes: 1);
  static const Duration _manualCloudIncrementalCooldown = Duration(seconds: 45);

  TtplayApiClient? get activeApiClient => _apiClient;
  TtplayAdminService? get adminService =>
      _apiClient == null ? null : (_adminService ??= TtplayAdminService(_apiClient!));
  CloudApiClient? get cloudApiClient => _cloudApiClient;
  CloudSourceRepository? get cloudSourceRepository => _cloudSourceRepository;
  CloudScanSessionRunner? get cloudScanRunner => _cloudScanRunner;
  CloudProjectionSyncClient? get cloudProjectionSync => _cloudProjectionSync;
  CloudMountMirror? get cloudMountMirror => _cloudMountMirror;
  CloudProjectionEngine? get cloudProjectionEngine => _cloudProjectionEngine;
  TtplayServerClient? get primaryClient => _primaryClient;
  List<TtplayExternalServerClient> get externalClients => List.unmodifiable(_externalClients);
  List<TtplayExternalServerSummary> get externalServerSummaries => List.unmodifiable(_externalSummaries);
  bool get isSelfHostedActive => _primaryClient != null || _cloudProjectionEngine != null;
  bool get isMediaLibraryV1Active => _cloudProjectionEngine != null && _primaryClient == null;
  bool get isCloudProjectionSyncing => _cloudProjectionEngine?.isSyncing == true;
  Object? get lastExternalRefreshError => _lastExternalRefreshError;

  static bool _isMediaLibraryV1(SelfHostedSession session) =>
      session.householdId != null && session.householdId!.isNotEmpty;

  void attachMultiServerProvider(MultiServerProvider provider) {
    _multiServerProvider = provider;
  }

  static String accountScopeKeyFor(SelfHostedSession session) =>
      crypto.sha256.convert(utf8.encode('${session.serverUrl}|${session.username}')).toString().substring(0, 16);

  void attachIptvProvider(IptvProvider provider) {
    _iptvProvider = provider;
    final session = sessionController.selfHostedSession;
    if (sessionController.isSelfHosted && session != null) {
      unawaited(provider.setSessionScope(isSelfHosted: true, accountScopeKey: accountScopeKeyFor(session)));
    } else {
      unawaited(provider.setSessionScope(isSelfHosted: false));
    }
    final mirror = _cloudMountMirror;
    if (mirror != null && mirror.hasHydratedExternals) {
      provider.setCloudSources(mirror.lastIptvSources);
    }
  }

  /// Synchronously binds the active self-hosted session before Frame 1 on cold start.
  ///
  /// For `media_library` v1 sessions, [localLibraryClient] remains registered as
  /// the unified library (combining local folders with cloud-projected items).
  void seedSelfHostedSynchronously(SelfHostedSession session, {CloudExternalMirrorSnapshot? cachedMirror}) {
    if (_disposed) return;
    _syncGeneration++;
    unawaited(_iptvProvider?.setSessionScope(isSelfHosted: true, accountScopeKey: accountScopeKeyFor(session)));
    if (_isMediaLibraryV1(session)) {
      final removedDirect = _directCloudExternalServerIds;
      _apiClient = null;
      _adminService = null;
      _primaryClient = null;
      _externalClients = const [];
      _externalSummaries = const [];
      _directCloudExternalServerIds = const {};
      _boundSessionKey = _sessionKeyFor(session);
      _lastExternalRefreshError = null;
      _bindCloudClients(session);
      configureLocalLibraryClientLabels(localLibraryClient);
      serverManager.clearSelfHostedServers();
      serverManager.registerLocalLibrary(localLibraryClient);
      _syncVisibleServerIds(includeLocal: true, removedDirectExternalIds: removedDirect);
      if (cachedMirror != null) {
        _cloudMountMirror?.seedCachedMirror(
          iptvSources: cachedMirror.iptvSources,
          externalConnections: cachedMirror.externalConnections,
        );
        _iptvProvider?.setCloudSources(cachedMirror.iptvSources);
        if (cachedMirror.externalConnections.isNotEmpty) {
          unawaited(_mountDirectCloudExternalServers());
        }
      }
      return;
    }

    final api = TtplayApiClient(
      baseUrl: session.serverUrl,
      accessToken: session.accessToken,
      httpClient: httpClientFactory?.call(),
    );
    final primary = TtplayServerClient(
      api: api,
      session: session,
      includePendingShelf: !_isTv(),
      onRawEvent: _handleRawSseEvent,
    );
    configureTtplayServerClientLabels(primary);

    final removedDirect = _directCloudExternalServerIds;
    _apiClient = api;
    _adminService = null;
    _bindCloudClients(session);
    _primaryClient = primary;
    _externalClients = const [];
    _externalSummaries = const [];
    _directCloudExternalServerIds = const {};
    _boundSessionKey = _sessionKeyFor(session);
    _lastExternalRefreshError = null;

    serverManager.unregisterLocalLibrary();
    serverManager.registerSelfHostedServers(primary, const []);
    _syncVisibleServerIds(includeLocal: false, removedDirectExternalIds: removedDirect);
  }

  /// Reconciles server registrations with the current [AppSessionController] state.
  Future<void> syncFromSession({bool refreshExternalServers = true, bool awaitCloudSync = true}) async {
    if (_disposed) return;
    final gen = ++_syncGeneration;

    if (sessionController.isSelfHosted && sessionController.selfHostedSession != null) {
      final session = sessionController.selfHostedSession!;
      unawaited(_iptvProvider?.setSessionScope(isSelfHosted: true, accountScopeKey: accountScopeKeyFor(session)));
      final sessionKey = _sessionKeyFor(session);
      if (_isMediaLibraryV1(session)) {
        final needsRebind = _cloudProjectionEngine == null || _boundSessionKey != sessionKey || _primaryClient != null;
        if (needsRebind) {
          final removedDirect = _directCloudExternalServerIds;
          _apiClient?.close();
          _apiClient = null;
          _adminService = null;
          _primaryClient = null;
          _externalClients = const [];
          _externalSummaries = const [];
          _directCloudExternalServerIds = const {};
          _boundSessionKey = sessionKey;
          _lastExternalRefreshError = null;
          _bindCloudClients(session);
          configureLocalLibraryClientLabels(localLibraryClient);
          serverManager.clearSelfHostedServers();
          await localLibraryClient.refreshMounts();
          if (_disposed || gen != _syncGeneration) return;
          serverManager.registerLocalLibrary(localLibraryClient);
          _syncVisibleServerIds(includeLocal: true, removedDirectExternalIds: removedDirect);
          if (!_disposed) notifyListeners();
        } else {
          await localLibraryClient.refreshMounts();
          if (_disposed || gen != _syncGeneration) return;
        }
        final mirror = _cloudMountMirror;
        if (mirror != null && !mirror.hasHydratedExternals) {
          final hydrated = await mirror.hydrateFromLocalMirror();
          if (_disposed || gen != _syncGeneration) return;
          if (hydrated != null) {
            await _mountDirectCloudExternalServers();
            if (_disposed || gen != _syncGeneration) return;
          }
        }
        if (refreshExternalServers) {
          if (awaitCloudSync) {
            try {
              await syncCloudProjection(full: false);
            } catch (e) {
              appLogger.w('Initial media_library cloud projection sync failed: $e');
              if (!_disposed) {
                unawaited(localLibraryClient.mountManager.probeAll());
              }
            }
          } else {
            unawaited(_triggerSafeIncrementalProjection());
          }
        }
        return;
      }

      if (_primaryClient == null || _boundSessionKey != sessionKey) {
        final api = TtplayApiClient(
          baseUrl: session.serverUrl,
          accessToken: session.accessToken,
          httpClient: httpClientFactory?.call(),
        );
        final primary = TtplayServerClient(
          api: api,
          session: session,
          includePendingShelf: !_isTv(),
          onRawEvent: _handleRawSseEvent,
        );
        configureTtplayServerClientLabels(primary);

        final removedDirect = _directCloudExternalServerIds;
        _apiClient = api;
        _adminService = null;
        _bindCloudClients(session);
        _primaryClient = primary;
        _externalClients = const [];
        _externalSummaries = const [];
        _directCloudExternalServerIds = const {};
        _boundSessionKey = sessionKey;
        _lastExternalRefreshError = null;

        serverManager.unregisterLocalLibrary();
        serverManager.registerSelfHostedServers(primary, const []);
        _syncVisibleServerIds(includeLocal: false, removedDirectExternalIds: removedDirect);
        if (!_disposed) notifyListeners();
      }
      if (refreshExternalServers) {
        if (awaitCloudSync) {
          await this.refreshExternalServers();
        } else {
          unawaited(
            this.refreshExternalServers().catchError((Object e) {
              appLogger.w('Background external server refresh failed: $e');
            }),
          );
        }
      }
      return;
    }

    if (sessionController.isOffline) {
      final removedDirect = _directCloudExternalServerIds;
      _clearSelfHostedState();
      configureLocalLibraryClientLabels(localLibraryClient);
      await localLibraryClient.refreshMounts();
      if (_disposed || gen != _syncGeneration) return;
      serverManager.registerLocalLibrary(localLibraryClient);
      _syncVisibleServerIds(includeLocal: true, removedDirectExternalIds: removedDirect);
      if (!_disposed) notifyListeners();
      return;
    }

    // Logged out to mode selection: drop self-hosted clients while leaving any
    // previously registered LocalLibraryClient intact for Setup/Auth flows.
    final removedDirect = _directCloudExternalServerIds;
    _clearSelfHostedState();
    _syncVisibleServerIds(includeLocal: true, removedDirectExternalIds: removedDirect);
    if (!_disposed) notifyListeners();
  }

  /// Refreshes the list of enabled external Emby/Jellyfin servers proxied
  /// through the active `ttplay-server`.
  Future<void> refreshExternalServers() async {
    if (_disposed) return;
    final api = _apiClient;
    final primary = _primaryClient;
    if (api == null || primary == null) return;
    final gen = _syncGeneration;

    try {
      final summaries = await api.fetchExternalServers();
      if (_disposed || gen != _syncGeneration || !identical(_apiClient, api) || !identical(_primaryClient, primary)) {
        return;
      }
      final enabled = summaries.where((s) => s.enabled && s.id.isNotEmpty).toList(growable: false);
      final clients = [for (final s in enabled) TtplayExternalServerClient(api: api, server: s)];
      _externalSummaries = summaries;
      _externalClients = clients;
      _lastExternalRefreshError = null;
      serverManager.registerSelfHostedServers(primary, clients);
      _syncVisibleServerIds(includeLocal: false);
      if (!_disposed) notifyListeners();
    } catch (e) {
      if (_disposed || gen != _syncGeneration || !identical(_apiClient, api)) return;
      _lastExternalRefreshError = e;
      appLogger.w('Failed to refresh ttplay-server external servers: $e');
      if (!_disposed) notifyListeners();
    }
  }

  void _handleRawSseEvent(String event, Map<String, dynamic> data) {
    if (event == 'ext_servers_changed' && !_disposed) {
      unawaited(refreshExternalServers());
    }
  }

  /// Triggers a cloud-to-local snapshot or incremental projection sync for the
  /// active `media_library` v1 session, mounts any decrypted cloud Emby /
  /// Jellyfin servers directly, and refreshes [localLibraryClient].
  Future<CloudSyncResult?> syncCloudProjection({bool full = false}) async {
    final engine = _cloudProjectionEngine;
    if (engine == null || _disposed) return null;
    final res = full ? await engine.syncFullSnapshot() : await engine.syncIncremental();
    if (!_disposed) {
      final pending = _pendingProjectionRefresh;
      if (pending != null) {
        await pending;
      } else {
        await _mountDirectCloudExternalServers();
        await localLibraryClient.refreshMounts();
        if (!_disposed) {
          unawaited(localLibraryClient.mountManager.probeAll());
        }
        if (res.fullReset ||
            res.hasChanges ||
            res.itemsProjected > 0 ||
            res.filesProjected > 0 ||
            res.emptyShellsPruned > 0) {
          _notifyLocalLibraryMutated();
        }
        notifyListeners();
      }
    }
    return res;
  }

  Future<void> _refreshProjectedLibrary() {
    final existing = _pendingProjectionRefresh;
    if (existing != null) return existing;
    late final Future<void> f;
    f = () async {
      try {
        if (_disposed) return;
        await _mountDirectCloudExternalServers();
        await localLibraryClient.refreshMounts();
        if (_disposed) return;
        unawaited(localLibraryClient.mountManager.probeAll());
        _notifyLocalLibraryMutated();
        notifyListeners();
      } finally {
        if (identical(_pendingProjectionRefresh, f)) {
          _pendingProjectionRefresh = null;
        }
      }
    }();
    _pendingProjectionRefresh = f;
    return f;
  }

  void _notifyLocalLibraryMutated() {
    onLocalLibraryMutated?.call();
    LibraryContentNotifier().notifyChanged(
      LibraryChangeEvent(serverId: ServerId(LocalLibraryClient.localServerId), itemsAdded: true, itemsUpdated: true),
    );
  }

  void _handleCloudRunnerChanged() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  void _cancelCloudSyncTimers() {
    _batchSyncTimer?.cancel();
    _batchSyncTimer = null;
    _postScanSyncTimer1?.cancel();
    _postScanSyncTimer1 = null;
    _postScanSyncTimer2?.cancel();
    _postScanSyncTimer2 = null;
    _cloudIncrementalTimer?.cancel();
    _cloudIncrementalTimer = null;
  }

  void _startCloudIncrementalScheduler() {
    _cloudIncrementalTimer?.cancel();
    if (_disposed || _cloudProjectionEngine == null) return;
    _cloudIncrementalTimer = Timer.periodic(_cloudIncrementalTick, (_) {
      unawaited(checkCloudIncrementalScans());
    });
  }

  void rescheduleCloudIncrementalTimer() {
    if (_disposed || !isMediaLibraryV1Active) return;
    final hh = sessionController.selfHostedSession?.householdId ?? '';
    if (hh.isEmpty) return;
    _startCloudIncrementalScheduler();
  }

  Future<bool> checkCloudIncrementalScans({bool force = false}) async {
    final repo = _cloudSourceRepository;
    final runner = _cloudScanRunner;
    if (_disposed || _checkingCloudIncremental || !isMediaLibraryV1Active || repo == null || runner == null) {
      return false;
    }
    _checkingCloudIncremental = true;
    var ranAny = false;
    try {
      final mounts = await localLibraryClient.mountManager.registry.list();
      final enabledQuarkMounts = [
        for (final m in mounts)
          if (CloudMountMirror.isCloudMountId(m.id) &&
              m.kind == StorageKind.quark &&
              m.configBool(MountKeys.autoIncrementalScan))
            m,
      ];
      if (enabledQuarkMounts.isEmpty) return false;

      final now = DateTime.now();
      final dueCandidates = <({StorageMount mount, String sourceId, Duration interval})>[];
      for (final mount in enabledQuarkMounts) {
        final sourceId = CloudMountMirror.sourceIdFromMountId(mount.id);
        final rawMinutes =
            mount.configInt(MountKeys.autoIncrementalIntervalMinutes) ??
            MountKeys.defaultAutoIncrementalIntervalMinutes;
        final interval = Duration(minutes: rawMinutes.clamp(1, 1440));
        final lastCheck = _lastCloudIncrementalBySource[sourceId];
        if (!force && lastCheck != null && now.difference(lastCheck) < interval) {
          continue;
        }
        dueCandidates.add((mount: mount, sourceId: sourceId, interval: interval));
      }
      if (dueCandidates.isEmpty) return false;

      final remoteSources = await repo.listSources();
      final sourceById = {for (final s in remoteSources) s.id: s};

      for (final candidate in dueCandidates) {
        if (_disposed) break;
        final src = sourceById[candidate.sourceId];
        if (src == null || src.status != 'active' || src.folders.isEmpty) continue;
        final hasBaseline =
            (src.scanState?.incrementalWatermark ?? 0) > 0 ||
            src.scanState?.lastScanResult == 'completed' ||
            src.folders.any((f) => f.baselineAt != null);
        if (!hasBaseline) continue;
        if (runner.isAnyScanning(src.id)) continue;

        final lastCheck = _lastCloudIncrementalBySource[src.id];
        if (!force && lastCheck == null) {
          final serverUpdatedAt = src.scanState?.updatedAt ?? 0;
          if (serverUpdatedAt > 0) {
            final serverDt = DateTime.fromMillisecondsSinceEpoch(serverUpdatedAt);
            _lastCloudIncrementalBySource[src.id] = serverDt;
            if (DateTime.now().difference(serverDt) < candidate.interval) {
              continue;
            }
          }
        }

        _lastCloudIncrementalBySource[src.id] = DateTime.now();

        var fallbackWatermarkMs = 0;
        final serverWatermark = src.scanState?.incrementalWatermark ?? 0;
        if (serverWatermark <= 0) {
          final row = await localLibraryClient.repository.database
              .customSelect(
                'SELECT MAX(modified_at) AS max_mtime FROM library_files WHERE mount_id = ? AND modified_at > 0',
                variables: [Variable.withString(candidate.mount.id)],
              )
              .getSingleOrNull();
          var rawMax = row?.read<int?>('max_mtime') ?? 0;
          if (rawMax > 0 && rawMax < 100000000000) {
            rawMax *= 1000;
          }
          fallbackWatermarkMs = rawMax;
        }

        final mtimeRows = await localLibraryClient.repository.database
            .customSelect(
              "SELECT remote_id, modified_at FROM library_files WHERE mount_id = ? AND remote_id IS NOT NULL AND remote_id != ''",
              variables: [Variable.withString(candidate.mount.id)],
            )
            .get();
        final knownMtimesByRemoteId = <String, int?>{
          for (final r in mtimeRows)
            if ((r.read<String?>('remote_id') ?? '').isNotEmpty)
              r.read<String>('remote_id'): r.read<int?>('modified_at'),
        };

        try {
          final driver = localLibraryClient.mountManager.driverFor(candidate.mount);
          await runner.runQuarkIncrementalScan(
            sourceId: src.id,
            driver: driver,
            fallbackWatermarkMs: fallbackWatermarkMs,
            knownServerWatermark: serverWatermark,
            knownFileMtimesByRemoteId: knownMtimesByRemoteId,
            targetLabel: candidate.mount.displayName,
          );
          ranAny = true;
        } catch (e) {
          appLogger.w('Cloud Quark incremental scan failed for ${src.id}: $e');
        }
      }
      return ranAny;
    } catch (e) {
      appLogger.w('Cloud incremental scan check failed: $e');
      return ranAny;
    } finally {
      _checkingCloudIncremental = false;
    }
  }

  Future<({bool triggered, bool onCooldown, Duration? remaining})> triggerManualCloudIncrementalScan({
    Duration cooldown = _manualCloudIncrementalCooldown,
  }) async {
    if (_disposed || !isMediaLibraryV1Active) {
      return (triggered: false, onCooldown: false, remaining: null);
    }
    final mounts = await localLibraryClient.mountManager.registry.list();
    final hasAutoQuark = mounts.any(
      (m) =>
          CloudMountMirror.isCloudMountId(m.id) &&
          m.kind == StorageKind.quark &&
          m.configBool(MountKeys.autoIncrementalScan),
    );
    if (!hasAutoQuark) {
      return (triggered: false, onCooldown: false, remaining: null);
    }
    final now = DateTime.now();
    final last = _lastManualCloudIncrementalAt;
    if (last != null) {
      final elapsed = now.difference(last);
      if (!elapsed.isNegative && elapsed < cooldown) {
        return (triggered: false, onCooldown: true, remaining: cooldown - elapsed);
      }
    }
    _lastManualCloudIncrementalAt = now;
    unawaited(checkCloudIncrementalScans(force: true));
    return (triggered: true, onCooldown: false, remaining: null);
  }

  Future<void> _triggerSafeIncrementalProjection() async {
    if (_disposed || _cloudProjectionEngine == null) return;
    try {
      await syncCloudProjection(full: false);
    } catch (e) {
      appLogger.d('Background cloud projection sync skipped: $e');
      if (!_disposed) {
        unawaited(localLibraryClient.mountManager.probeAll());
      }
    }
  }

  void markCloudSourceRecentlyVerified({String? sourceId, String? externalServerMachineId}) {
    if (sourceId != null && sourceId.isNotEmpty) {
      _cloudMountMirror?.markSourceRecentlyVerified(sourceId);
    }
    if (externalServerMachineId != null && externalServerMachineId.isNotEmpty) {
      _recentlyVerifiedExternalServerIds.add(externalServerMachineId);
    }
  }

  String? externalServerIdForCloudSource(String sourceId) {
    final mirror = _cloudMountMirror;
    if (mirror == null) return null;
    final targetId = 'cloud-$sourceId';
    for (final conn in mirror.lastExternalConnections) {
      if (conn.id == targetId) return conn.serverMachineId;
    }
    return null;
  }

  Future<void> probeCloudReachability() async {
    if (_disposed) return;
    await Future.wait([
      localLibraryClient.mountManager.probeAll(force: true),
      serverManager.probeSelfHostedExternals(),
    ]);
  }

  /// Registers decrypted cloud `emby` / `jellyfin` sources as direct
  /// MediaBrowser clients on [serverManager] (no server relay), defaulting
  /// unverified endpoints to offline until async probing confirms reachability.
  Future<void> _mountDirectCloudExternalServers() async {
    final mirror = _cloudMountMirror;
    if (mirror == null || _disposed || !isMediaLibraryV1Active) return;
    _iptvProvider?.setCloudSources(mirror.lastIptvSources);
    final previousDirectIds = _directCloudExternalServerIds;
    final conns = mirror.lastExternalConnections;
    final seedOnline = <String>{..._recentlyVerifiedExternalServerIds, ...mirror.consumeSeededExternalServerIds()};
    _recentlyVerifiedExternalServerIds.clear();

    await serverManager.syncDirectCloudExternalConnections(conns, seedOnlineServerIds: seedOnline);
    if (_disposed) return;
    _directCloudExternalServerIds = {for (final c in conns) c.serverMachineId};
    _syncVisibleServerIds(
      includeLocal: true,
      removedDirectExternalIds: previousDirectIds.difference(_directCloudExternalServerIds),
    );
  }

  /// Removes all mirrored `cloud:*` mounts and empty projected library items
  /// while keeping the device's own local-folder mounts intact.
  Future<void> clearCloudProjectionData() async {
    final registry = localLibraryClient.mountManager.registry;
    final mounts = await registry.list();
    for (final m in mounts) {
      if (CloudMountMirror.isCloudMountId(m.id)) {
        await localLibraryClient.mountManager.dropCachedDriver(m.id);
        await registry.remove(m.id);
      }
    }
    final engine = _cloudProjectionEngine;
    if (engine != null) {
      await engine.pruneEmptyProjectedItems();
      await engine.clearProjectedLists();
    }
    await syncConfigStore?.clearAllLocalKv();
  }

  void _bindCloudClients(SelfHostedSession session) {
    _cancelCloudSyncTimers();
    _cloudProjectionEngine?.stopListeningEvents();
    _cloudScanRunner?.removeListener(_handleCloudRunnerChanged);
    _cloudScanRunner?.dispose();
    _cloudApiClient?.close();
    final cloudApi = CloudApiClient(
      baseUrl: session.serverUrl,
      accessToken: session.accessToken,
      httpClient: httpClientFactory?.call(),
    );
    Uint8List? masterKeyProvider() {
      final raw = sessionController.selfHostedSession?.masterKeyB64 ?? session.masterKeyB64;
      if (raw == null || raw.isEmpty) return null;
      try {
        return Uint8List.fromList(base64Decode(raw));
      } catch (_) {
        return null;
      }
    }

    final repo = CloudSourceRepository(api: cloudApi, masterKeyProvider: masterKeyProvider, keyEpoch: session.keyEpoch);
    final syncClient = CloudProjectionSyncClient(cloudApi);
    final mirror = CloudMountMirror(
      sourceRepository: repo,
      mountRegistry: localLibraryClient.mountManager.registry,
      mountManager: localLibraryClient.mountManager,
      externalMirrorStore: CloudExternalMirrorStore(localLibraryClient.repository.database),
      accountScopeKey: accountScopeKeyFor(session),
    );
    final engine = CloudProjectionEngine(
      db: localLibraryClient.repository.database,
      syncClient: syncClient,
      mountMirror: mirror,
      syncConfigStore: syncConfigStore,
      onLibraryUpdated: () {
        if (!_disposed) {
          unawaited(_refreshProjectedLibrary());
        }
      },
      onSyncStateChanged: (_) {
        if (!_disposed) {
          notifyListeners();
        }
      },
    );
    final runner = CloudScanSessionRunner(
      api: cloudApi,
      onBatchCommitted: (_, added, changed) {
        if (_disposed || (added == 0 && changed == 0)) return;
        if (_batchSyncTimer?.isActive == true) return;
        _batchSyncTimer = Timer(const Duration(seconds: 4), () {
          _batchSyncTimer = null;
          unawaited(_triggerSafeIncrementalProjection());
        });
      },
      onScanFinished: (summary) {
        if (_disposed) return;
        _batchSyncTimer?.cancel();
        _batchSyncTimer = null;
        unawaited(_triggerSafeIncrementalProjection());
        if (summary.filesReported > 0) {
          _postScanSyncTimer1?.cancel();
          _postScanSyncTimer1 = Timer(const Duration(seconds: 3), () {
            _postScanSyncTimer1 = null;
            unawaited(_triggerSafeIncrementalProjection());
          });
          _postScanSyncTimer2?.cancel();
          _postScanSyncTimer2 = Timer(const Duration(seconds: 10), () {
            _postScanSyncTimer2 = null;
            unawaited(_triggerSafeIncrementalProjection());
          });
        }
      },
    )..addListener(_handleCloudRunnerChanged);

    _cloudApiClient = cloudApi;
    _cloudSourceRepository = repo;
    _cloudScanRunner = runner;
    _cloudProjectionSync = syncClient;
    _cloudMountMirror = mirror;
    _cloudProjectionEngine = engine;
    localLibraryClient.metadataServerUrl = session.serverUrl;
    localLibraryClient.metadataAccessToken = session.accessToken;
    final bridge = _CloudUserDataBridgeImpl(syncClient, engine);
    localLibraryClient.cloudUserDataBridge = bridge;
    final configStore = syncConfigStore;
    if (configStore != null) {
      configStore.cloudBridge = bridge;
      settingsSyncBridge?.attach(configStore);
    }
    if (session.householdId != null && session.householdId!.isNotEmpty) {
      engine.startListeningEvents();
      _startCloudIncrementalScheduler();
    }
  }

  void _clearSelfHostedState() {
    final primaryRegistered = _primaryClient != null && serverManager.isSelfHostedServer(_primaryClient!.serverId);
    final staleApi = _apiClient;
    final hadCloud = _cloudProjectionEngine != null;
    _cancelCloudSyncTimers();
    _cloudProjectionEngine?.stopListeningEvents();
    _cloudScanRunner?.removeListener(_handleCloudRunnerChanged);
    _cloudScanRunner?.dispose();
    settingsSyncBridge?.detach();
    syncConfigStore?.cloudBridge = null;
    localLibraryClient.cloudUserDataBridge = null;
    localLibraryClient.metadataServerUrl = ServerMetadataProvider.defaultOfficialMetadataUrl;
    localLibraryClient.metadataAccessToken = null;
    if (hadCloud && !sessionController.isOffline) {
      unawaited(
        clearCloudProjectionData().catchError((Object e) {
          appLogger.d('Ignoring cloud projection cleanup error: $e');
        }),
      );
    }
    _cloudApiClient?.close();
    _cloudApiClient = null;
    _cloudSourceRepository = null;
    _cloudScanRunner = null;
    _cloudProjectionSync = null;
    _cloudMountMirror = null;
    _cloudProjectionEngine = null;
    _apiClient = null;
    _adminService = null;
    _primaryClient = null;
    _externalClients = const [];
    _externalSummaries = const [];
    _directCloudExternalServerIds = const {};
    _recentlyVerifiedExternalServerIds.clear();
    _boundSessionKey = null;
    _lastExternalRefreshError = null;
    _iptvProvider?.setCloudSources(const []);
    unawaited(_iptvProvider?.setSessionScope(isSelfHosted: false));
    serverManager.clearSelfHostedServers();
    if (!primaryRegistered) {
      staleApi?.close();
    }
  }

  void _syncVisibleServerIds({required bool includeLocal, Set<String> removedDirectExternalIds = const {}}) {
    final provider = _multiServerProvider;
    if (provider == null) return;
    final current = serverManager.visibleServerIds;
    if (current == null) return;
    final next = <String>{
      for (final id in current)
        if (id != TtplayServerClient.primaryServerId &&
            !TtplayExternalServerClient.isExternalServerId(id) &&
            !removedDirectExternalIds.contains(id) &&
            (includeLocal || id != LocalLibraryClient.localServerId))
          id,
      if (includeLocal && serverManager.registeredServerIds.contains(LocalLibraryClient.localServerId))
        LocalLibraryClient.localServerId,
      ...serverManager.selfHostedServerIds,
    };
    provider.setVisibleServerIds(next);
  }

  String _sessionKeyFor(SelfHostedSession session) => '${session.serverUrl}|${session.accessToken}';

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _multiServerProvider = null;
    _iptvProvider = null;
    _cancelCloudSyncTimers();
    _cloudProjectionEngine?.stopListeningEvents();
    _cloudScanRunner?.removeListener(_handleCloudRunnerChanged);
    _cloudScanRunner?.dispose();
    settingsSyncBridge?.detach();
    syncConfigStore?.cloudBridge = null;
    localLibraryClient.cloudUserDataBridge = null;
    _cloudApiClient?.close();
    _cloudApiClient = null;
    _cloudSourceRepository = null;
    _cloudScanRunner = null;
    _cloudProjectionSync = null;
    _cloudMountMirror = null;
    _cloudProjectionEngine = null;
    _apiClient = null;
    _adminService = null;
    _primaryClient = null;
    _externalClients = const [];
    _externalSummaries = const [];
    _boundSessionKey = null;
    super.dispose();
  }
}

class _CloudUserDataBridgeImpl implements LocalCloudUserDataBridge {
  _CloudUserDataBridgeImpl(this._sync, this._engine);

  final CloudProjectionSyncClient _sync;
  final CloudProjectionEngine _engine;

  @override
  Future<bool> hydrateCloudItemDetail(int localItemId, String workKey) =>
      _engine.hydrateItemDetailFromCloud(localItemId, workKey);

  @override
  Future<void> pushProgress({
    required String workKey,
    int seasonNumber = 0,
    int episodeNumber = 0,
    required int positionMs,
    int? durationMs,
    bool? watched,
  }) => _sync.upsertProgress(
    workKey: workKey,
    seasonNumber: seasonNumber,
    episodeNumber: episodeNumber,
    positionMs: positionMs,
    durationMs: durationMs,
    watched: watched,
  );

  @override
  Future<void> pushFavorite({required String workKey, required bool isFavorite}) =>
      isFavorite ? _sync.addFavorite(workKey) : _sync.removeFavorite(workKey);

  @override
  Future<void> pushHideContinue({required String workKey, int seasonNumber = 0, int episodeNumber = 0}) {
    final isEpisode = seasonNumber > 0 || episodeNumber > 0;
    final progressKey = DeterministicKeys.generateProgressKey(
      workKey: workKey,
      kind: isEpisode ? 'show' : 'movie',
      seasonNum: isEpisode ? seasonNumber : -1,
      episodeNum: isEpisode ? episodeNumber : -1,
    );
    return _sync.hideContinueWatching(progressKey);
  }

  @override
  Future<void> putCloudKv({
    required String scope,
    required String namespace,
    required String key,
    required Map<String, dynamic> value,
    String? workKey,
  }) => _sync.putKv(scope: scope, namespace: namespace, key: key, value: value, workKey: workKey);

  @override
  Future<void> deleteCloudKv({required String scope, required String namespace, required String key}) =>
      _sync.deleteKv(scope: scope, namespace: namespace, key: key);

  @override
  Future<String?> createCloudList({
    required String kind,
    required String title,
    String? summary,
    String? tmdbId,
    bool shared = false,
  }) async {
    try {
      final created = await _sync.createList(
        kind: kind,
        title: title,
        summary: summary,
        tmdbId: tmdbId,
        shared: shared,
      );
      return created['id'] as String?;
    } on CloudApiException catch (e) {
      if (shared && e.isForbidden) {
        final created = await _sync.createList(
          kind: kind,
          title: title,
          summary: summary,
          tmdbId: tmdbId,
          shared: false,
        );
        return created['id'] as String?;
      }
      rethrow;
    }
  }

  @override
  Future<void> deleteCloudList(String cloudListId) => _sync.deleteList(cloudListId);

  @override
  Future<void> addCloudListEntry({
    required String cloudListId,
    required String workKey,
    int? seasonNumber,
    int? episodeNumber,
    int? sortOrder,
  }) => _sync.addListEntry(
    listId: cloudListId,
    workKey: workKey,
    seasonNumber: seasonNumber,
    episodeNumber: episodeNumber,
    sortOrder: sortOrder,
  );

  @override
  Future<void> removeCloudListEntry({required String cloudListId, required String entryKey}) =>
      _sync.removeListEntry(listId: cloudListId, entryKey: entryKey);
}
