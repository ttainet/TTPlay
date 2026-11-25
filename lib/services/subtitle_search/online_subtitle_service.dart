import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../exceptions/media_server_exceptions.dart';
import '../../library/local_library_client.dart';
import '../../library/scrapers/server_metadata_provider.dart';
import '../../media/ids.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../media/media_server_client.dart';
import '../../providers/multi_server_provider.dart';
import '../../utils/app_logger.dart';
import '../../utils/external_ids.dart';
import '../online_subtitle_store.dart';
import 'online_subtitle_models.dart';

class OnlineSubtitleService {
  OnlineSubtitleService({http.Client? client}) : _client = client ?? http.Client(), _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;

  void close() {
    if (_ownsClient) {
      _client.close();
    }
  }

  /// Resolves the active `media_library` endpoint from the registered [LocalLibraryClient],
  /// falling back to the official metadata URL if configured at build time.
  static OnlineSubtitleServerConfig? resolveEndpoint(MultiServerProvider? multiServer) {
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
        appLogger.d('Failed to resolve LocalLibraryClient for subtitle endpoint', error: e);
      }
    }

    final normalized = ServerMetadataProvider.normalizeServerUrl(serverUrl);
    if (normalized.isEmpty) {
      return null;
    }
    final trimmedToken = accessToken?.trim();
    return OnlineSubtitleServerConfig(
      serverUrl: normalized,
      accessToken: (trimmedToken == null || trimmedToken.isEmpty) ? null : trimmedToken,
    );
  }

  /// Builds a rich search query from [metadata], external IDs (series-level for episodes),
  /// and the active media filename.
  static Future<OnlineSubtitleQuery> buildQuery({
    required MediaItem metadata,
    MediaServerClient? client,
    String? mediaSourceId,
    String? activeFilePath,
    required String language,
    String? manualQuery,
    String provider = 'all',
  }) async {
    final isEpisode = metadata.kind == MediaKind.episode;
    ExternalIds ids = const ExternalIds();
    if (client != null) {
      if (isEpisode && (metadata.grandparentId?.isNotEmpty ?? false)) {
        try {
          ids = await client.fetchExternalIds(metadata.grandparentId!);
        } catch (e) {
          appLogger.d('Series external ID lookup failed for subtitle search', error: e);
        }
      }
      if (!ids.hasCatalogIds) {
        try {
          ids = ids.fillFrom(await client.fetchExternalIds(metadata.id));
        } catch (e) {
          appLogger.d('Item external ID lookup failed for subtitle search', error: e);
        }
      }
    }

    final rawPath = (activeFilePath?.trim().isNotEmpty ?? false)
        ? activeFilePath!.trim()
        : (metadata.allPartFiles.firstOrNull ?? '');
    final fileName = rawPath.isEmpty ? null : p.basename(rawPath);

    return OnlineSubtitleQuery(
      itemGlobalKey: metadata.globalKey,
      mediaSourceId: mediaSourceId,
      title: metadata.title,
      originalTitle: metadata.originalTitle,
      showTitle: isEpisode ? (metadata.grandparentTitle ?? metadata.parentTitle) : null,
      fileName: fileName,
      kind: isEpisode ? 'episode' : 'movie',
      year: metadata.year,
      season: isEpisode ? metadata.parentIndex : null,
      episode: isEpisode ? metadata.index : null,
      imdbId: ids.imdb,
      tmdbId: ids.tmdb?.toString(),
      language: language,
      manualQuery: manualQuery,
      provider: provider,
    );
  }

  Uri _buildUri(OnlineSubtitleServerConfig endpoint, String path, [Map<String, String>? query]) {
    final base = Uri.parse(endpoint.serverUrl);
    final mergedPath = p.posix.join(base.path.isEmpty ? '/' : base.path, path.replaceFirst(RegExp(r'^/'), ''));
    return base.replace(
      path: mergedPath.startsWith('/') ? mergedPath : '/$mergedPath',
      queryParameters: (query == null || query.isEmpty) ? null : query,
    );
  }

  Map<String, String> _headers(OnlineSubtitleServerConfig endpoint, {bool jsonBody = false}) {
    return {
      'Accept': 'application/json',
      if (jsonBody) 'Content-Type': 'application/json',
      if (endpoint.useAuthenticatedEndpoints) 'Authorization': 'Bearer ${endpoint.accessToken}',
    };
  }

  Future<OnlineSubtitleSearchResponse> search(OnlineSubtitleServerConfig endpoint, OnlineSubtitleQuery query) async {
    final route = endpoint.useAuthenticatedEndpoints ? '/api/v1/subtitles/search' : '/api/v1/public/subtitles/search';
    final uri = _buildUri(endpoint, route, query.toQueryParams());
    final resp = await _performRequest(
      uri,
      () => _client.get(uri, headers: _headers(endpoint)).timeout(const Duration(seconds: 20)),
      'Failed to search online subtitles',
    );
    final decoded = _decodeJsonMap(resp.body, uri: uri);
    return OnlineSubtitleSearchResponse.fromJson(decoded);
  }

  Future<CachedOnlineSubtitle> downloadAndCache(
    OnlineSubtitleServerConfig endpoint, {
    required OnlineSubtitleCandidate candidate,
    required String itemGlobalKey,
    String? mediaSourceId,
    int? season,
    int? episode,
    required OnlineSubtitleStore store,
  }) async {
    final route = endpoint.useAuthenticatedEndpoints
        ? '/api/v1/subtitles/download'
        : '/api/v1/public/subtitles/download';
    final uri = _buildUri(endpoint, route);
    final payload = jsonEncode({
      'provider': candidate.provider,
      'token': candidate.downloadToken,
      'language': candidate.language,
      if (season != null && season > 0) 'season': season,
      if (episode != null && episode > 0) 'episode': episode,
    });
    final resp = await _performRequest(
      uri,
      () => _client
          .post(uri, headers: _headers(endpoint, jsonBody: true), body: payload)
          .timeout(const Duration(seconds: 25)),
      'Failed to download online subtitle',
    );

    final decoded = _decodeJsonMap(resp.body, uri: uri);
    final content = decoded['content'] as String?;
    final sha256 = decoded['sha256'] as String?;
    final format = (decoded['format'] as String?) ?? candidate.format;
    final language = (decoded['language'] as String?) ?? candidate.language;
    if (content == null || content.isEmpty || sha256 == null || sha256.isEmpty) {
      throw MediaServerHttpException(
        type: MediaServerHttpErrorType.unknown,
        statusCode: 502,
        message: 'Subtitle server returned empty content',
        requestUri: uri,
      );
    }

    final displayTitle = candidate.title.trim().isNotEmpty
        ? candidate.title.trim()
        : ((decoded['filename'] as String?) ?? 'Subtitle');

    return store.saveAndSelect(
      itemGlobalKey: itemGlobalKey,
      mediaSourceId: mediaSourceId,
      provider: candidate.provider,
      remoteId: candidate.id,
      title: displayTitle,
      language: language,
      format: format,
      sha256: sha256,
      contentUtf8: content,
    );
  }

  Future<http.Response> _performRequest(Uri uri, Future<http.Response> Function() send, String fallbackMessage) async {
    final http.Response resp;
    try {
      resp = await send();
    } catch (e) {
      throw MediaServerHttpException.from(e, uri: uri);
    }

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      String msg = 'HTTP ${resp.statusCode}';
      try {
        final body = jsonDecode(resp.body);
        if (body is Map && body['message'] is String && (body['message'] as String).isNotEmpty) {
          msg = body['message'] as String;
        }
      } catch (_) {}
      throw MediaServerHttpException(
        type: MediaServerHttpErrorType.unknown,
        statusCode: resp.statusCode,
        message: '$fallbackMessage: $msg',
        requestUri: uri,
      );
    }
    return resp;
  }

  Map<String, dynamic> _decodeJsonMap(String raw, {Uri? uri}) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw MediaServerHttpException(
        type: MediaServerHttpErrorType.unknown,
        message: 'Invalid subtitle response format',
        requestUri: uri,
      );
    }
    return decoded.cast<String, dynamic>();
  }
}
