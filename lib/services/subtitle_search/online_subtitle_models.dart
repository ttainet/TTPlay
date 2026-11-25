class OnlineSubtitleServerConfig {
  const OnlineSubtitleServerConfig({required this.serverUrl, this.accessToken});

  final String serverUrl;
  final String? accessToken;

  bool get useAuthenticatedEndpoints => (accessToken?.trim().isNotEmpty ?? false);
}

class OnlineSubtitleQuery {
  const OnlineSubtitleQuery({
    required this.itemGlobalKey,
    this.mediaSourceId,
    this.title,
    this.originalTitle,
    this.showTitle,
    this.fileName,
    required this.kind,
    this.year,
    this.season,
    this.episode,
    this.imdbId,
    this.tmdbId,
    required this.language,
    this.manualQuery,
    this.provider = 'all',
  });

  final String itemGlobalKey;
  final String? mediaSourceId;
  final String? title;
  final String? originalTitle;
  final String? showTitle;
  final String? fileName;
  final String kind; // 'movie' | 'episode'
  final int? year;
  final int? season;
  final int? episode;
  final String? imdbId;
  final String? tmdbId;
  final String language;
  final String? manualQuery;
  final String provider;

  Map<String, String> toQueryParams() {
    final map = <String, String>{};
    void put(String key, String? value) {
      final trimmed = value?.trim();
      if (trimmed != null && trimmed.isNotEmpty) {
        map[key] = trimmed;
      }
    }

    put('q', manualQuery);
    put('file_name', fileName);
    put('title', kind == 'episode' ? (showTitle ?? title) : title);
    put('original_title', originalTitle);
    put('language', language);
    put('kind', kind);
    put('imdb_id', imdbId);
    put('tmdb_id', tmdbId);
    if (year != null && year! > 0) map['year'] = '$year';
    if (season != null && season! > 0) map['season'] = '$season';
    if (episode != null && episode! > 0) map['episode'] = '$episode';
    if (provider.isNotEmpty && provider != 'all') map['provider'] = provider;
    return map;
  }
}

class OnlineSubtitleCandidate {
  const OnlineSubtitleCandidate({
    required this.id,
    required this.provider,
    required this.title,
    this.releaseName,
    required this.language,
    required this.format,
    this.hearingImpaired = false,
    this.forced = false,
    this.perfectMatch = false,
    this.score,
    this.downloads = 0,
    required this.downloadToken,
  });

  final String id;
  final String provider;
  final String title;
  final String? releaseName;
  final String language;
  final String format;
  final bool hearingImpaired;
  final bool forced;
  final bool perfectMatch;
  final double? score;
  final int downloads;
  final String downloadToken;

  String get cacheIdentity => '$provider:$id';

  factory OnlineSubtitleCandidate.fromJson(Map<String, dynamic> json) {
    return OnlineSubtitleCandidate(
      id: (json['id'] ?? '').toString(),
      provider: (json['provider'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      releaseName: json['release_name'] as String?,
      language: (json['language'] ?? '').toString(),
      format: (json['format'] ?? 'srt').toString(),
      hearingImpaired: json['hearing_impaired'] == true,
      forced: json['forced'] == true,
      perfectMatch: json['perfect_match'] == true,
      score: (json['score'] as num?)?.toDouble(),
      downloads: (json['downloads'] as num?)?.toInt() ?? 0,
      downloadToken: (json['download_token'] ?? '').toString(),
    );
  }
}

class OnlineSubtitleWarning {
  const OnlineSubtitleWarning({required this.provider, required this.message});

  final String provider;
  final String message;

  factory OnlineSubtitleWarning.fromJson(Map<String, dynamic> json) {
    return OnlineSubtitleWarning(
      provider: (json['provider'] ?? '').toString(),
      message: (json['message'] ?? '').toString(),
    );
  }
}

class OnlineSubtitleSearchResponse {
  const OnlineSubtitleSearchResponse({
    required this.candidates,
    required this.enabledProviders,
    this.warnings = const [],
    this.cached = false,
  });

  final List<OnlineSubtitleCandidate> candidates;
  final List<String> enabledProviders;
  final List<OnlineSubtitleWarning> warnings;
  final bool cached;

  factory OnlineSubtitleSearchResponse.fromJson(Map<String, dynamic> json) {
    final rawCandidates = json['candidates'] as List? ?? const [];
    final rawProviders = json['enabled_providers'] as List? ?? const [];
    final rawWarnings = json['warnings'] as List? ?? const [];
    return OnlineSubtitleSearchResponse(
      candidates: [
        for (final item in rawCandidates)
          if (item is Map) OnlineSubtitleCandidate.fromJson(item.cast<String, dynamic>()),
      ],
      enabledProviders: [
        for (final p in rawProviders)
          if (p != null && p.toString().trim().isNotEmpty) p.toString().trim(),
      ],
      warnings: [
        for (final w in rawWarnings)
          if (w is Map) OnlineSubtitleWarning.fromJson(w.cast<String, dynamic>()),
      ],
      cached: json['cached'] == true,
    );
  }
}
