import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/app_logger.dart';
import 'iptv_models.dart';
import 'm3u_parser.dart';
import 'xmltv_parser.dart';

/// Manages both local-only and cloud-synced IPTV sources, cached channel lists, favorites, and EPG data.
class IptvProvider extends ChangeNotifier {
  static const String _localSourcesPrefKey = 'iptv_local_sources_v1';
  static const String _favoritesPrefKey = 'iptv_favorites_v1';
  static const Duration _epgTtl = Duration(minutes: 30);

  IptvProvider({http.Client Function()? httpClientFactory})
    : _httpClientFactory = httpClientFactory ?? http.Client.new;

  final http.Client Function() _httpClientFactory;

  List<IptvSource> _localSources = const [];
  List<IptvSource> _cloudSources = const [];
  final Set<String> _favoriteKeys = {};

  final Map<String, List<IptvChannel>> _channelsBySource = {};
  final Map<String, String?> _headerEpgBySource = {};
  final Map<String, IptvEpgIndex> _epgBySource = {};
  final Map<String, DateTime> _epgLoadedAt = {};
  final Set<String> _loadingSources = {};
  final Set<String> _loadingEpgSources = {};
  final Map<String, String?> _errorBySource = {};
  final Map<String, Future<void>> _inFlightLoads = {};
  String? _selectedSourceId;
  bool _disposed = false;

  List<IptvSource> get localSources => List.unmodifiable(_localSources);
  List<IptvSource> get cloudSources => List.unmodifiable(_cloudSources);
  List<IptvSource> get sources => List.unmodifiable([..._cloudSources, ..._localSources]);
  bool get hasSources => _cloudSources.isNotEmpty || _localSources.isNotEmpty;
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
  bool isLoading(String sourceId) => _loadingSources.contains(sourceId);
  String? errorFor(String sourceId) => _errorBySource[sourceId];

  bool isFavorite(IptvChannel channel) => _favoriteKeys.contains(channel.favoriteKey);

  Future<void> loadLocalSources() async {
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

    final favList = prefs.getStringList(_favoritesPrefKey) ?? const [];
    if (_disposed) return;
    _localSources = List.unmodifiable(loaded);
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
    final next = List<IptvSource>.of(_localSources);
    next[idx] = clean;
    _localSources = List.unmodifiable(next);
    _invalidateSourceCache(clean.id);
    await _persistLocalSources();
    if (!_disposed) notifyListeners();
  }

  Future<void> removeLocalSource(String id) async {
    _localSources = List.unmodifiable(_localSources.where((s) => s.id != id));
    if (_selectedSourceId == id) _selectedSourceId = null;
    _invalidateSourceCache(id);
    await _persistLocalSources();
    if (!_disposed) notifyListeners();
  }

  void setCloudSources(List<IptvSource> cloudSources) {
    final normalized = List<IptvSource>.unmodifiable(
      cloudSources.map((s) => s.copyWith(isCloud: true)),
    );
    final nextById = {for (final s in normalized) s.id: s};
    for (final prev in _cloudSources) {
      final updated = nextById[prev.id];
      if (updated == null ||
          updated.m3uUrl != prev.m3uUrl ||
          updated.epgUrl != prev.epgUrl ||
          updated.userAgent != prev.userAgent ||
          updated.referer != prev.referer) {
        _invalidateSourceCache(prev.id);
      }
    }
    _cloudSources = normalized;
    if (_selectedSourceId != null && !sources.any((s) => s.id == _selectedSourceId)) {
      _selectedSourceId = null;
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> toggleFavorite(IptvChannel channel) async {
    final key = channel.favoriteKey;
    if (!_favoriteKeys.add(key)) {
      _favoriteKeys.remove(key);
    }
    if (!_disposed) notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_favoritesPrefKey, _favoriteKeys.toList(growable: false));
  }

  void _invalidateSourceCache(String sourceId) {
    _channelsBySource.remove(sourceId);
    _headerEpgBySource.remove(sourceId);
    _epgBySource.remove(sourceId);
    _epgLoadedAt.remove(sourceId);
    _errorBySource.remove(sourceId);
  }

  Future<void> ensureLoaded(IptvSource source, {bool forceRefresh = false}) {
    if (!forceRefresh && _channelsBySource.containsKey(source.id)) {
      _maybeRefreshEpg(source, force: false);
      return Future<void>.value();
    }
    final inFlight = _inFlightLoads[source.id];
    if (inFlight != null && !forceRefresh) return inFlight;

    late final Future<void> task;
    task = () async {
      _loadingSources.add(source.id);
      _errorBySource[source.id] = null;
      if (!_disposed) notifyListeners();

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
        _channelsBySource[source.id] = parsed.channels;
        _headerEpgBySource[source.id] = parsed.headerEpgUrl;
        _errorBySource[source.id] = null;
        _maybeRefreshEpg(source, force: forceRefresh);
      } catch (e) {
        if (_disposed) return;
        _errorBySource[source.id] = e is FormatException ? e.message : '$e';
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
