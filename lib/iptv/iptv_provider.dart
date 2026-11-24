import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/app_logger.dart';
import 'iptv_channel_cache.dart';
import 'iptv_models.dart';
import 'm3u_parser.dart';
import 'xmltv_parser.dart';

/// Manages both local-only and cloud-synced IPTV sources, cached channel lists, favorites, and EPG data.
class IptvProvider extends ChangeNotifier {
  static const String _localSourcesPrefKey = 'iptv_local_sources_v1';
  static const String _favoritesPrefKey = 'iptv_favorites_v1';
  static const String _offlineCacheScopeKey = 'offline';
  static const Duration _epgTtl = Duration(minutes: 30);

  IptvProvider({http.Client Function()? httpClientFactory, IptvChannelCache? channelCache})
    : _httpClientFactory = httpClientFactory ?? http.Client.new,
      _channelCache = channelCache ?? _defaultChannelCache();

  static IptvChannelCache _defaultChannelCache() {
    if (kIsWeb || Platform.environment.containsKey('FLUTTER_TEST')) {
      return const IptvChannelCache.noop();
    }
    return const IptvChannelCache();
  }

  final http.Client Function() _httpClientFactory;
  final IptvChannelCache _channelCache;

  List<IptvSource> _localSources = const [];
  List<IptvSource> _cloudSources = const [];
  bool _cloudMode = false;
  String _accountScopeKey = '';
  String _activeFavoritesKey = _favoritesPrefKey;
  int _favoritesEpoch = 0;
  final Set<String> _favoriteKeys = {};

  final Map<String, List<IptvChannel>> _channelsBySource = {};
  final Map<String, String?> _headerEpgBySource = {};
  final Map<String, IptvEpgIndex> _epgBySource = {};
  final Map<String, DateTime> _epgLoadedAt = {};
  final Map<String, DateTime> _cachedAtBySource = {};
  final Set<String> _isFromDiskCache = {};
  final Set<String> _networkRefreshedSources = {};
  final Set<String> _loadingSources = {};
  final Set<String> _loadingEpgSources = {};
  final Map<String, String?> _errorBySource = {};
  final Map<String, Future<void>> _inFlightLoads = {};
  final Map<String, int> _sourceGeneration = {};
  String? _selectedSourceId;
  bool _disposed = false;

  String get _cloudCacheScopeKey => 'cloud:${_accountScopeKey.isNotEmpty ? _accountScopeKey : 'default'}';
  String get _currentCacheScopeKey => _cloudMode ? _cloudCacheScopeKey : _offlineCacheScopeKey;

  bool get isCloudMode => _cloudMode;
  List<IptvSource> get localSources => List.unmodifiable(_localSources);
  List<IptvSource> get cloudSources => List.unmodifiable(_cloudSources);
  List<IptvSource> get sources => List.unmodifiable(_cloudMode ? _cloudSources : _localSources);
  bool get hasSources => sources.isNotEmpty;
  String? get selectedSourceId => _selectedSourceId;

  IptvSource? get activeSource {
    final all = sources;
    if (all.isEmpty) return null;
    if (_selectedSourceId != null) {
      for (final src in all) {
        if (src.id == _selectedSourceId) return src;
      }
    }
    return all.first;
  }

  void selectSource(String sourceId) {
    if (_selectedSourceId == sourceId) return;
    _selectedSourceId = sourceId;
    if (!_disposed) notifyListeners();
  }

  List<IptvChannel> channelsFor(String sourceId) => _channelsBySource[sourceId] ?? const [];
  IptvEpgIndex epgFor(String sourceId) => _epgBySource[sourceId] ?? IptvEpgIndex.empty;
  DateTime? cachedAtFor(String sourceId) => _cachedAtBySource[sourceId];
  bool isUsingDiskCache(String sourceId) => _isFromDiskCache.contains(sourceId);
  bool isLoading(String sourceId) => _loadingSources.contains(sourceId);
  String? errorFor(String sourceId) => _errorBySource[sourceId];

  bool isFavorite(IptvChannel channel) => _favoriteKeys.contains(channel.favoriteKey);

  Future<void> clearSourceDiskCache(String sourceId) =>
      _channelCache.delete(scopeKey: _currentCacheScopeKey, sourceId: sourceId);

  Future<void> loadLocalSources() async {
    final epochAtStart = _favoritesEpoch;
    final favKeyAtStart = _activeFavoritesKey;
    final prefs = await SharedPreferences.getInstance();
    final rawSources = prefs.getString(_localSourcesPrefKey);
    final loaded = <IptvSource>[];
    if (rawSources != null && rawSources.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(rawSources);
        if (decoded is List) {
          for (final entry in decoded) {
            if (entry is Map) {
              final src = IptvSource.fromJson(Map<String, dynamic>.from(entry));
              if (src.id.isNotEmpty && src.m3uUrl.isNotEmpty) {
                loaded.add(src.copyWith(isCloud: false));
              }
            }
          }
        }
      } catch (e) {
        appLogger.w('IptvProvider: failed to decode stored local sources: $e');
      }
    }

    if (_disposed) return;
    _localSources = List.unmodifiable(loaded);
    if (epochAtStart == _favoritesEpoch) {
      final favList = prefs.getStringList(favKeyAtStart) ?? const [];
      _favoriteKeys
        ..clear()
        ..addAll(favList);
    }
    notifyListeners();
    if (!_cloudMode) {
      await _warmDiskCacheForSources(_localSources);
    }
  }

  /// Switches the active IPTV workspace between local-only and cloud-synced
  /// modes, isolating visible sources, runtime channels, and persisted favorites
  /// per mode and self-hosted account without deleting persisted disk caches.
  Future<void> setSessionScope({required bool isSelfHosted, String? accountScopeKey}) async {
    final trimmedScope = isSelfHosted ? (accountScopeKey?.trim() ?? '') : '';
    final nextFavKey = isSelfHosted
        ? 'iptv_favorites_cloud_v1_${trimmedScope.isNotEmpty ? trimmedScope : 'default'}'
        : _favoritesPrefKey;
    if (_cloudMode == isSelfHosted && _accountScopeKey == trimmedScope && _activeFavoritesKey == nextFavKey) {
      return;
    }

    final prevWasCloud = _cloudMode;
    final prevScopeKey = _currentCacheScopeKey;
    _cloudMode = isSelfHosted;
    _accountScopeKey = trimmedScope;
    _activeFavoritesKey = nextFavKey;
    final epoch = ++_favoritesEpoch;

    if (prevScopeKey != _currentCacheScopeKey) {
      if (prevWasCloud) {
        _clearInMemoryByPrefix('cloud:');
      } else {
        _clearInMemoryWhere((id) => !id.startsWith('cloud:'));
      }
    }
    if (_selectedSourceId != null && !sources.any((s) => s.id == _selectedSourceId)) {
      _selectedSourceId = null;
    }
    if (!_disposed) notifyListeners();

    unawaited(_warmDiskCacheForSources(sources));

    final prefs = await SharedPreferences.getInstance();
    if (_disposed || epoch != _favoritesEpoch) return;
    final favList = prefs.getStringList(nextFavKey) ?? const [];
    _favoriteKeys
      ..clear()
      ..addAll(favList);
    notifyListeners();
  }

  Future<void> _persistLocalSources() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode([for (final s in _localSources) s.toJson()]);
    await prefs.setString(_localSourcesPrefKey, encoded);
  }

  Future<void> addLocalSource(IptvSource source) async {
    final clean = source.copyWith(isCloud: false);
    _localSources = List.unmodifiable([..._localSources.where((s) => s.id != clean.id), clean]);
    await _persistLocalSources();
    if (!_disposed) notifyListeners();
  }

  Future<void> updateLocalSource(IptvSource source) async {
    final clean = source.copyWith(isCloud: false);
    final idx = _localSources.indexWhere((s) => s.id == clean.id);
    if (idx < 0) {
      await addLocalSource(clean);
      return;
    }
    final prev = _localSources[idx];
    final next = List<IptvSource>.of(_localSources);
    next[idx] = clean;
    _localSources = List.unmodifiable(next);
    final fingerprintChanged = IptvChannelCache.buildFingerprint(prev) != IptvChannelCache.buildFingerprint(clean);
    if (fingerprintChanged) {
      _invalidateSourceCache(clean.id, deleteDisk: true, scopeKey: _offlineCacheScopeKey);
    } else if (prev.epgUrl != clean.epgUrl) {
      _epgBySource.remove(clean.id);
      _epgLoadedAt.remove(clean.id);
      _networkRefreshedSources.remove(clean.id);
    }
    await _persistLocalSources();
    if (!_disposed) notifyListeners();
  }

  Future<void> removeLocalSource(String id) async {
    _localSources = List.unmodifiable(_localSources.where((s) => s.id != id));
    if (_selectedSourceId == id) _selectedSourceId = null;
    _invalidateSourceCache(id, deleteDisk: true, scopeKey: _offlineCacheScopeKey);
    await _persistLocalSources();
    if (!_disposed) notifyListeners();
  }

  void setCloudSources(List<IptvSource> cloudSources) {
    final normalized = List<IptvSource>.unmodifiable(
      cloudSources.map((s) => s.copyWith(isCloud: true)),
    );
    if (normalized.isEmpty) {
      // Logout / mode switch clears runtime cloud memory only so offline disk
      // cache for this self-hosted account survives until the next sign-in.
      for (final prev in _cloudSources) {
        _invalidateSourceCache(prev.id, deleteDisk: false);
      }
      _cloudSources = const [];
      if (_selectedSourceId != null && !sources.any((s) => s.id == _selectedSourceId)) {
        _selectedSourceId = null;
      }
      if (!_disposed) notifyListeners();
      return;
    }

    final nextById = {for (final s in normalized) s.id: s};
    for (final prev in _cloudSources) {
      final updated = nextById[prev.id];
      final fingerprintChanged =
          updated == null || IptvChannelCache.buildFingerprint(updated) != IptvChannelCache.buildFingerprint(prev);
      if (fingerprintChanged) {
        _invalidateSourceCache(prev.id, deleteDisk: true, scopeKey: _cloudCacheScopeKey);
      } else if (updated.epgUrl != prev.epgUrl) {
        _epgBySource.remove(prev.id);
        _epgLoadedAt.remove(prev.id);
        _networkRefreshedSources.remove(prev.id);
      }
    }
    _cloudSources = normalized;
    if (_selectedSourceId != null && !sources.any((s) => s.id == _selectedSourceId)) {
      _selectedSourceId = null;
    }
    if (!_disposed) notifyListeners();
    if (_cloudMode) {
      unawaited(_warmDiskCacheForSources(_cloudSources));
    }
  }

  Future<void> toggleFavorite(IptvChannel channel) async {
    final key = channel.favoriteKey;
    if (!_favoriteKeys.add(key)) {
      _favoriteKeys.remove(key);
    }
    final targetPrefKey = _activeFavoritesKey;
    final snapshot = _favoriteKeys.toList(growable: false);
    if (!_disposed) notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(targetPrefKey, snapshot);
  }

  void _clearInMemoryByPrefix(String prefix) {
    _clearInMemoryWhere((id) => id.startsWith(prefix));
  }

  void _clearInMemoryWhere(bool Function(String id) predicate) {
    final matchingIds = <String>{
      ..._channelsBySource.keys.where(predicate),
      ..._headerEpgBySource.keys.where(predicate),
      ..._epgBySource.keys.where(predicate),
      ..._cachedAtBySource.keys.where(predicate),
      ..._isFromDiskCache.where(predicate),
      ..._networkRefreshedSources.where(predicate),
      ..._errorBySource.keys.where(predicate),
    };
    for (final id in matchingIds) {
      _invalidateSourceCache(id, deleteDisk: false);
    }
  }

  void _invalidateSourceCache(String sourceId, {bool deleteDisk = false, String? scopeKey}) {
    _sourceGeneration[sourceId] = (_sourceGeneration[sourceId] ?? 0) + 1;
    _channelsBySource.remove(sourceId);
    _headerEpgBySource.remove(sourceId);
    _epgBySource.remove(sourceId);
    _epgLoadedAt.remove(sourceId);
    _cachedAtBySource.remove(sourceId);
    _isFromDiskCache.remove(sourceId);
    _networkRefreshedSources.remove(sourceId);
    _errorBySource.remove(sourceId);
    if (deleteDisk) {
      unawaited(_channelCache.delete(scopeKey: scopeKey ?? _currentCacheScopeKey, sourceId: sourceId));
    }
  }

  Future<void> _warmDiskCacheForSources(List<IptvSource> targetSources) async {
    if (_disposed || targetSources.isEmpty) return;
    final scopeEpoch = _favoritesEpoch;
    final scopeKey = _currentCacheScopeKey;
    var changed = false;

    for (final src in targetSources) {
      if (_disposed || scopeEpoch != _favoritesEpoch) return;
      if (_channelsBySource.containsKey(src.id)) continue;

      final expectedFp = IptvChannelCache.buildFingerprint(src);
      final cached = await _channelCache.read(
        scopeKey: scopeKey,
        sourceId: src.id,
        expectedFingerprint: expectedFp,
      );
      if (_disposed || scopeEpoch != _favoritesEpoch) return;
      if (cached == null || _channelsBySource.containsKey(src.id)) continue;

      final currentSrc = sources.firstWhereOrNull((s) => s.id == src.id);
      if (currentSrc == null || IptvChannelCache.buildFingerprint(currentSrc) != expectedFp) {
        continue;
      }

      _channelsBySource[src.id] = cached.channels;
      _headerEpgBySource[src.id] = cached.headerEpgUrl;
      _cachedAtBySource[src.id] = cached.cachedAt;
      _isFromDiskCache.add(src.id);
      changed = true;
    }

    if (changed && !_disposed && scopeEpoch == _favoritesEpoch) {
      notifyListeners();
    }
  }

  Future<void> ensureLoaded(IptvSource source, {bool forceRefresh = false}) {
    if (!forceRefresh &&
        _networkRefreshedSources.contains(source.id) &&
        _channelsBySource.containsKey(source.id)) {
      _maybeRefreshEpg(source, force: false);
      return Future<void>.value();
    }
    final inFlight = _inFlightLoads[source.id];
    if (inFlight != null && !forceRefresh) return inFlight;

    final epochAtStart = _favoritesEpoch;
    final genAtStart = _sourceGeneration[source.id] ?? 0;
    final scopeKeyAtStart = _currentCacheScopeKey;
    final expectedFp = IptvChannelCache.buildFingerprint(source);

    late final Future<void> task;
    task = () async {
      _loadingSources.add(source.id);
      _errorBySource[source.id] = null;
      if (!_disposed) notifyListeners();

      if (!_channelsBySource.containsKey(source.id)) {
        final cached = await _channelCache.read(
          scopeKey: scopeKeyAtStart,
          sourceId: source.id,
          expectedFingerprint: expectedFp,
        );
        if (_disposed) return;
        if (cached != null &&
            epochAtStart == _favoritesEpoch &&
            genAtStart == (_sourceGeneration[source.id] ?? 0) &&
            !_channelsBySource.containsKey(source.id)) {
          _channelsBySource[source.id] = cached.channels;
          _headerEpgBySource[source.id] = cached.headerEpgUrl;
          _cachedAtBySource[source.id] = cached.cachedAt;
          _isFromDiskCache.add(source.id);
          notifyListeners();
        }
      }

      final client = _httpClientFactory();
      try {
        final parsed = await fetchAndParsePlaylist(
          source.m3uUrl,
          sourceId: source.id,
          userAgent: source.userAgent,
          referer: source.referer,
          client: client,
        );
        if (_disposed) return;
        if (genAtStart != (_sourceGeneration[source.id] ?? 0)) return;

        final cachedAt = DateTime.now();
        final entry = IptvCachedPlaylist(
          sourceId: source.id,
          fingerprint: expectedFp,
          cachedAt: cachedAt,
          headerEpgUrl: parsed.headerEpgUrl,
          channels: List<IptvChannel>.unmodifiable(parsed.channels),
        );
        await _channelCache.write(scopeKey: scopeKeyAtStart, entry: entry);
        if (_disposed || epochAtStart != _favoritesEpoch || genAtStart != (_sourceGeneration[source.id] ?? 0)) {
          return;
        }
        _channelsBySource[source.id] = entry.channels;
        _headerEpgBySource[source.id] = parsed.headerEpgUrl;
        _cachedAtBySource[source.id] = cachedAt;
        _isFromDiskCache.remove(source.id);
        _networkRefreshedSources.add(source.id);
        _errorBySource[source.id] = null;
        _maybeRefreshEpg(source, force: forceRefresh);
      } catch (e) {
        if (_disposed) return;
        if (epochAtStart == _favoritesEpoch && genAtStart == (_sourceGeneration[source.id] ?? 0)) {
          _errorBySource[source.id] = e is FormatException ? e.message : '$e';
          if (_channelsBySource.containsKey(source.id)) {
            _maybeRefreshEpg(source, force: false);
          }
        }
      } finally {
        client.close();
        _loadingSources.remove(source.id);
        if (identical(_inFlightLoads[source.id], task)) {
          unawaited(_inFlightLoads.remove(source.id));
        }
        if (!_disposed) notifyListeners();
      }
    }();

    _inFlightLoads[source.id] = task;
    return task;
  }

  void _maybeRefreshEpg(IptvSource source, {required bool force}) {
    final effectiveEpgUrl = (source.epgUrl?.isNotEmpty == true)
        ? source.epgUrl
        : _headerEpgBySource[source.id];
    if (effectiveEpgUrl == null || effectiveEpgUrl.isEmpty) return;
    if (_loadingEpgSources.contains(source.id)) return;
    final lastAt = _epgLoadedAt[source.id];
    if (!force && lastAt != null && DateTime.now().difference(lastAt) < _epgTtl) {
      return;
    }

    _loadingEpgSources.add(source.id);
    unawaited(() async {
      final client = _httpClientFactory();
      try {
        final uri = Uri.tryParse(effectiveEpgUrl);
        if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
          return;
        }
        final headers = _buildRequestHeaders(userAgent: source.userAgent, referer: source.referer);
        final resp = await client.get(uri, headers: headers).timeout(const Duration(seconds: 25));
        if (resp.statusCode >= 200 && resp.statusCode < 300) {
          final index = XmltvParser.parseBytes(resp.bodyBytes);
          if (!_disposed && !index.isEmpty) {
            _epgBySource[source.id] = index;
            _epgLoadedAt[source.id] = DateTime.now();
            notifyListeners();
          }
        }
      } catch (e) {
        appLogger.d('IptvProvider: EPG fetch skipped for ${source.name}: $e');
      } finally {
        client.close();
        _loadingEpgSources.remove(source.id);
      }
    }());
  }

  static Map<String, String> _buildRequestHeaders({String? userAgent, String? referer}) {
    final headers = <String, String>{};
    if (userAgent != null && userAgent.trim().isNotEmpty) {
      headers['User-Agent'] = userAgent.trim();
    }
    if (referer != null && referer.trim().isNotEmpty) {
      headers['Referer'] = referer.trim();
    }
    return headers;
  }

  Future<M3uParseResult> parsePlaylist(
    String m3uUrl, {
    String sourceId = 'preview',
    String? userAgent,
    String? referer,
  }) async {
    final client = _httpClientFactory();
    try {
      return await fetchAndParsePlaylist(
        m3uUrl,
        sourceId: sourceId,
        userAgent: userAgent,
        referer: referer,
        client: client,
      );
    } finally {
      client.close();
    }
  }

  static Future<M3uParseResult> fetchAndParsePlaylist(
    String m3uUrl, {
    String sourceId = 'preview',
    String? userAgent,
    String? referer,
    http.Client? client,
  }) async {
    final trimmed = m3uUrl.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const FormatException('请输入有效的 http:// 或 https:// 订阅地址');
    }

    final ownsClient = client == null;
    final activeClient = client ?? http.Client();
    try {
      final headers = _buildRequestHeaders(userAgent: userAgent, referer: referer);
      final resp = await activeClient.get(uri, headers: headers).timeout(const Duration(seconds: 20));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw FormatException('订阅拉取失败（HTTP ${resp.statusCode}）');
      }
      final body = utf8.decode(resp.bodyBytes, allowMalformed: true);
      final result = M3uParser.parse(
        body,
        sourceId: sourceId,
        defaultUserAgent: userAgent,
        defaultReferer: referer,
      );
      if (result.channels.isEmpty) {
        throw const FormatException('未在订阅中解析到任何可播放频道');
      }
      return result;
    } on TimeoutException {
      throw const FormatException('订阅请求超时，请检查网络或地址');
    } finally {
      if (ownsClient) {
        activeClient.close();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
