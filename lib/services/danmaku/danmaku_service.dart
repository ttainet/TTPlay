import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../exceptions/media_server_exceptions.dart';
import '../../library/local_library_client.dart';
import '../../library/scrapers/server_metadata_provider.dart';
import '../../media/ids.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../providers/multi_server_provider.dart';
import '../../utils/app_logger.dart';
import 'danmaku_models.dart';

class DanmakuService {
  DanmakuService({http.Client? client}) : _client = client ?? http.Client(), _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;

  void close() {
    if (_ownsClient) {
      _client.close();
    }
  }

  static DanmakuServerConfig? resolveEndpoint(MultiServerProvider? multiServer) {
    String serverUrl = ServerMetadataProvider.defaultOfficialMetadataUrl;
    String? accessToken;

    if (multiServer != null) {
      try {
        final localClient = multiServer.serverManager.getClient(ServerId(LocalLibraryClient.localServerId));
        if (localClient is LocalLibraryClient) {
          serverUrl = localClient.metadataServerUrl;
          accessToken = localClient.metadataAccessToken;
        }
      } catch (e) {
        appLogger.d('Failed to resolve LocalLibraryClient for danmaku endpoint', error: e);
      }
    }

    final normalized = ServerMetadataProvider.normalizeServerUrl(serverUrl);
    if (normalized.isEmpty) {
      return null;
    }
    final trimmedToken = accessToken?.trim();
    return DanmakuServerConfig(
      serverUrl: normalized,
      accessToken: (trimmedToken == null || trimmedToken.isEmpty) ? null : trimmedToken,
    );
  }

  Uri _buildUri(DanmakuServerConfig endpoint, String path, [Map<String, String>? query]) {
    final base = Uri.parse(endpoint.serverUrl);
    final mergedPath = p.posix.join(base.path.isEmpty ? '/' : base.path, path.replaceFirst(RegExp(r'^/'), ''));
    return base.replace(
      path: mergedPath.startsWith('/') ? mergedPath : '/$mergedPath',
      queryParameters: (query == null || query.isEmpty) ? null : query,
    );
  }

  Map<String, String> _headers(DanmakuServerConfig endpoint, {bool jsonBody = false}) {
    return {
      'Accept': 'application/json',
      if (jsonBody) 'Content-Type': 'application/json',
      if (endpoint.useAuthenticatedEndpoints) 'Authorization': 'Bearer ${endpoint.accessToken}',
    };
  }

  String _routePrefix(DanmakuServerConfig endpoint) =>
      endpoint.useAuthenticatedEndpoints ? '/api/v1/danmaku' : '/api/v1/public/danmaku';

  Future<({bool matched, List<DanmakuMatchItem> matches})> match(
    DanmakuServerConfig endpoint, {
    required MediaItem metadata,
    String? activeFilePath,
    String? platform,
    bool refresh = false,
  }) async {
    final isEpisode = metadata.kind == MediaKind.episode;
    final rawPath = (activeFilePath?.trim().isNotEmpty ?? false)
        ? activeFilePath!.trim()
        : (metadata.allPartFiles.firstOrNull ?? '');
    final fileName = rawPath.isEmpty ? null : p.basename(rawPath);

    final showTitle = (metadata.grandparentTitle ?? metadata.parentTitle ?? metadata.title)?.trim() ?? '';
    final uri = _buildUri(endpoint, '${_routePrefix(endpoint)}/match', refresh ? {'refresh': '1'} : null);
    final payload = <String, dynamic>{
      if (fileName != null && fileName.isNotEmpty) 'file_name': fileName,
      'title': metadata.title,
      if (metadata.originalTitle != null && metadata.originalTitle!.trim().isNotEmpty)
        'original_title': metadata.originalTitle!.trim(),
      if (isEpisode && showTitle.isNotEmpty) 'show_title': showTitle,
      'kind': isEpisode ? 'episode' : 'movie',
      if (metadata.year != null && metadata.year! > 0) 'year': metadata.year,
      if (isEpisode && metadata.parentIndex != null && metadata.parentIndex! > 0) 'season': metadata.parentIndex,
      if (isEpisode && metadata.index != null && metadata.index! > 0) 'episode': metadata.index,
      if (platform != null && platform.trim().isNotEmpty) 'platform': platform.trim(),
      if (refresh) 'refresh': true,
    };

    final resp = await _performRequest(
      uri,
      () => _client
          .post(uri, headers: _headers(endpoint, jsonBody: true), body: jsonEncode(payload))
          .timeout(const Duration(seconds: 35)),
      'Failed to match danmaku',
    );
    final decoded = _decodeJsonMap(resp.body, uri: uri);
    final rawMatches = decoded['matches'] as List<dynamic>? ?? const [];
    final matches = rawMatches.whereType<Map<String, dynamic>>().map(DanmakuMatchItem.fromJson).toList(growable: false);
    final matched = (decoded['matched'] as bool? ?? false) || matches.isNotEmpty;
    return (matched: matched, matches: matches);
  }

  Future<List<DanmakuAnimeItem>> searchAnime(
    DanmakuServerConfig endpoint,
    String keyword, {
    bool refresh = false,
  }) async {
    final uri = _buildUri(endpoint, '${_routePrefix(endpoint)}/search', {
      'keyword': keyword.trim(),
      if (refresh) 'refresh': '1',
    });
    final resp = await _performRequest(
      uri,
      () => _client.get(uri, headers: _headers(endpoint)).timeout(const Duration(seconds: 35)),
      'Failed to search danmaku',
    );
    final decoded = _decodeJsonMap(resp.body, uri: uri);
    final rawAnimes = decoded['animes'] as List<dynamic>? ?? const [];
    return rawAnimes.whereType<Map<String, dynamic>>().map(DanmakuAnimeItem.fromJson).toList(growable: false);
  }

  Future<DanmakuBangumiDetail> getBangumi(DanmakuServerConfig endpoint, String animeId, {bool refresh = false}) async {
    final uri = _buildUri(
      endpoint,
      '${_routePrefix(endpoint)}/bangumi/${Uri.encodeComponent(animeId.trim())}',
      refresh ? {'refresh': '1'} : null,
    );
    final resp = await _performRequest(
      uri,
      () => _client.get(uri, headers: _headers(endpoint)).timeout(const Duration(seconds: 35)),
      'Failed to load danmaku episodes',
    );
    final decoded = _decodeJsonMap(resp.body, uri: uri);
    final bangumiMap = decoded['bangumi'];
    if (bangumiMap is! Map<String, dynamic>) {
      throw MediaServerHttpException(
        type: MediaServerHttpErrorType.unknown,
        message: 'Invalid bangumi response',
        requestUri: uri,
      );
    }
    return DanmakuBangumiDetail.fromJson(bangumiMap);
  }

  Future<DanmakuCommentsResponse> getComments(
    DanmakuServerConfig endpoint, {
    String? episodeId,
    String? sourceUrl,
    int limit = 10000,
    bool refresh = false,
  }) async {
    final query = <String, String>{
      if (episodeId != null && episodeId.trim().isNotEmpty) 'episode_id': episodeId.trim(),
      if (sourceUrl != null && sourceUrl.trim().isNotEmpty) 'url': sourceUrl.trim(),
      if (limit > 0) 'limit': limit.toString(),
      if (refresh) 'refresh': '1',
    };
    final uri = _buildUri(endpoint, '${_routePrefix(endpoint)}/comments', query);
    final resp = await _performRequest(
      uri,
      () => _client.get(uri, headers: _headers(endpoint)).timeout(const Duration(seconds: 35)),
      'Failed to load danmaku comments',
    );
    final decoded = _decodeJsonMap(resp.body, uri: uri);
    return DanmakuCommentsResponse.fromJson(decoded);
  }

  Future<http.Response> _performRequest(Uri uri, Future<http.Response> Function() send, String failureContext) async {
    final http.Response resp;
    try {
      resp = await send();
    } on MediaServerException {
      rethrow;
    } catch (e) {
      throw MediaServerHttpException.from(e, uri: uri);
    }
    if (resp.statusCode == 401 || resp.statusCode == 403) {
      throw MediaServerAuthException(
        _extractMessage(resp.body) ?? '$failureContext (HTTP ${resp.statusCode})',
        statusCode: resp.statusCode,
      );
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw MediaServerHttpException(
        type: MediaServerHttpErrorType.unknown,
        statusCode: resp.statusCode,
        message: _extractMessage(resp.body) ?? '$failureContext (HTTP ${resp.statusCode})',
        requestUri: uri,
      );
    }
    return resp;
  }

  Map<String, dynamic> _decodeJsonMap(String body, {required Uri uri}) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (e) {
      throw MediaServerHttpException(
        type: MediaServerHttpErrorType.unknown,
        message: 'Invalid danmaku JSON response: $e',
        requestUri: uri,
      );
    }
    throw MediaServerHttpException(
      type: MediaServerHttpErrorType.unknown,
      message: 'Invalid danmaku JSON response shape',
      requestUri: uri,
    );
  }

  String? _extractMessage(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final msg = decoded['message'];
        if (msg is String && msg.trim().isNotEmpty) {
          return msg.trim();
        }
      }
    } catch (_) {}
    return null;
  }
}
