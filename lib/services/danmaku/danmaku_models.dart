import 'dart:ui' show Color;

class DanmakuServerConfig {
  final String serverUrl;
  final String? accessToken;

  const DanmakuServerConfig({required this.serverUrl, this.accessToken});

  bool get useAuthenticatedEndpoints => accessToken != null && accessToken!.trim().isNotEmpty;
}

enum DanmakuMode {
  scroll,
  top,
  bottom;

  static DanmakuMode fromInt(int mode) {
    return switch (mode) {
      4 => DanmakuMode.bottom,
      5 => DanmakuMode.top,
      _ => DanmakuMode.scroll,
    };
  }
}

class DanmakuCommentItem {
  final int cid;
  final double timeSeconds;
  final DanmakuMode mode;
  final Color color;
  final String text;
  final String userId;
  final int mergeCount;

  const DanmakuCommentItem({
    required this.cid,
    required this.timeSeconds,
    required this.mode,
    required this.color,
    required this.text,
    this.userId = '',
    this.mergeCount = 1,
  });

  bool get isColored => (color.toARGB32() & 0xFFFFFF) != 0xFFFFFF;

  String get displayText => mergeCount > 1 ? '$text ×$mergeCount' : text;

  DanmakuCommentItem copyWith({int? mergeCount}) {
    return DanmakuCommentItem(
      cid: cid,
      timeSeconds: timeSeconds,
      mode: mode,
      color: color,
      text: text,
      userId: userId,
      mergeCount: mergeCount ?? this.mergeCount,
    );
  }

  factory DanmakuCommentItem.fromJson(Map<String, dynamic> json) {
    final rgb = (json['color'] as num?)?.toInt() ?? 0xFFFFFF;
    return DanmakuCommentItem(
      cid: (json['cid'] as num?)?.toInt() ?? 0,
      timeSeconds: ((json['time'] as num?)?.toDouble() ?? 0.0).clamp(0.0, double.infinity),
      mode: DanmakuMode.fromInt((json['mode'] as num?)?.toInt() ?? 1),
      color: Color(0xFF000000 | (rgb & 0xFFFFFF)),
      text: (json['text'] as String?) ?? '',
      userId: (json['user_id'] as String?) ?? '',
    );
  }
}

class DanmakuMatchItem {
  final String episodeId;
  final String animeId;
  final String animeTitle;
  final String episodeTitle;
  final String type;
  final String typeDescription;
  final double shift;
  final String imageUrl;
  final String sourceUrl;

  const DanmakuMatchItem({
    required this.episodeId,
    required this.animeId,
    required this.animeTitle,
    required this.episodeTitle,
    this.type = '',
    this.typeDescription = '',
    this.shift = 0,
    this.imageUrl = '',
    this.sourceUrl = '',
  });

  factory DanmakuMatchItem.fromJson(Map<String, dynamic> json) {
    return DanmakuMatchItem(
      episodeId: json['episode_id']?.toString() ?? '',
      animeId: json['anime_id']?.toString() ?? '',
      animeTitle: (json['anime_title'] as String?) ?? '',
      episodeTitle: (json['episode_title'] as String?) ?? '',
      type: (json['type'] as String?) ?? '',
      typeDescription: (json['type_description'] as String?) ?? '',
      shift: (json['shift'] as num?)?.toDouble() ?? 0.0,
      imageUrl: (json['image_url'] as String?) ?? '',
      sourceUrl: (json['source_url'] as String?) ?? '',
    );
  }
}

class DanmakuAnimeItem {
  final String animeId;
  final String animeTitle;
  final String typeDescription;
  final int episodeCount;
  final String source;

  const DanmakuAnimeItem({
    required this.animeId,
    required this.animeTitle,
    this.typeDescription = '',
    this.episodeCount = 0,
    this.source = '',
  });

  factory DanmakuAnimeItem.fromJson(Map<String, dynamic> json) {
    return DanmakuAnimeItem(
      animeId: json['anime_id']?.toString() ?? '',
      animeTitle: (json['anime_title'] as String?) ?? '',
      typeDescription: (json['type_description'] as String?) ?? '',
      episodeCount: (json['episode_count'] as num?)?.toInt() ?? 0,
      source: (json['source'] as String?) ?? '',
    );
  }
}

class DanmakuBangumiEpisode {
  final String episodeId;
  final String episodeTitle;
  final String episodeNumber;
  final String sourceUrl;

  const DanmakuBangumiEpisode({
    required this.episodeId,
    required this.episodeTitle,
    this.episodeNumber = '',
    this.sourceUrl = '',
  });

  factory DanmakuBangumiEpisode.fromJson(Map<String, dynamic> json) {
    return DanmakuBangumiEpisode(
      episodeId: json['episode_id']?.toString() ?? '',
      episodeTitle: (json['episode_title'] as String?) ?? '',
      episodeNumber: json['episode_number']?.toString() ?? '',
      sourceUrl: (json['source_url'] as String?) ?? '',
    );
  }
}

class DanmakuBangumiDetail {
  final String animeId;
  final String animeTitle;
  final List<DanmakuBangumiEpisode> episodes;

  const DanmakuBangumiDetail({required this.animeId, required this.animeTitle, required this.episodes});

  factory DanmakuBangumiDetail.fromJson(Map<String, dynamic> json) {
    final rawEps = json['episodes'] as List<dynamic>? ?? const [];
    return DanmakuBangumiDetail(
      animeId: json['anime_id']?.toString() ?? '',
      animeTitle: (json['anime_title'] as String?) ?? '',
      episodes: rawEps.whereType<Map<String, dynamic>>().map(DanmakuBangumiEpisode.fromJson).toList(growable: false),
    );
  }
}

class DanmakuCommentsResponse {
  final String episodeId;
  final String sourceUrl;
  final int count;
  final int totalCount;
  final bool sampled;
  final double videoDuration;
  final bool cached;
  final List<DanmakuCommentItem> comments;

  const DanmakuCommentsResponse({
    required this.episodeId,
    required this.sourceUrl,
    required this.count,
    required this.totalCount,
    required this.sampled,
    required this.videoDuration,
    required this.cached,
    required this.comments,
  });

  factory DanmakuCommentsResponse.fromJson(Map<String, dynamic> json) {
    final rawComments = json['comments'] as List<dynamic>? ?? const [];
    final items = rawComments
        .whereType<Map<String, dynamic>>()
        .map(DanmakuCommentItem.fromJson)
        .where((c) => c.text.trim().isNotEmpty)
        .toList(growable: false);
    final count = (json['count'] as num?)?.toInt() ?? items.length;
    final total = (json['total_count'] as num?)?.toInt() ?? count;
    return DanmakuCommentsResponse(
      episodeId: json['episode_id']?.toString() ?? '',
      sourceUrl: (json['source_url'] as String?) ?? '',
      count: count,
      totalCount: total > 0 ? total : items.length,
      sampled: json['sampled'] as bool? ?? false,
      videoDuration: (json['video_duration'] as num?)?.toDouble() ?? 0.0,
      cached: json['cached'] as bool? ?? false,
      comments: items,
    );
  }
}

class DanmakuRenderSettings {
  final double fontSize;
  final double opacity;
  final double scrollDurationSeconds;
  final double displayArea;
  final double strokeWidth;
  final bool mergeDuplicates;
  final bool allowStacking;
  final bool blockScroll;
  final bool blockTop;
  final bool blockBottom;
  final bool blockColor;
  final List<String> blockedKeywords;
  final double timeOffsetSeconds;

  const DanmakuRenderSettings({
    this.fontSize = 22.0,
    this.opacity = 0.85,
    this.scrollDurationSeconds = 10.0,
    this.displayArea = 0.5,
    this.strokeWidth = 1.5,
    this.mergeDuplicates = true,
    this.allowStacking = false,
    this.blockScroll = false,
    this.blockTop = false,
    this.blockBottom = false,
    this.blockColor = false,
    this.blockedKeywords = const [],
    this.timeOffsetSeconds = 0.0,
  });

  DanmakuRenderSettings copyWith({
    double? fontSize,
    double? opacity,
    double? scrollDurationSeconds,
    double? displayArea,
    double? strokeWidth,
    bool? mergeDuplicates,
    bool? allowStacking,
    bool? blockScroll,
    bool? blockTop,
    bool? blockBottom,
    bool? blockColor,
    List<String>? blockedKeywords,
    double? timeOffsetSeconds,
  }) {
    return DanmakuRenderSettings(
      fontSize: fontSize ?? this.fontSize,
      opacity: opacity ?? this.opacity,
      scrollDurationSeconds: scrollDurationSeconds ?? this.scrollDurationSeconds,
      displayArea: displayArea ?? this.displayArea,
      strokeWidth: strokeWidth ?? this.strokeWidth,
      mergeDuplicates: mergeDuplicates ?? this.mergeDuplicates,
      allowStacking: allowStacking ?? this.allowStacking,
      blockScroll: blockScroll ?? this.blockScroll,
      blockTop: blockTop ?? this.blockTop,
      blockBottom: blockBottom ?? this.blockBottom,
      blockColor: blockColor ?? this.blockColor,
      blockedKeywords: blockedKeywords ?? this.blockedKeywords,
      timeOffsetSeconds: timeOffsetSeconds ?? this.timeOffsetSeconds,
    );
  }

  bool filterOrMergeDiffersFrom(DanmakuRenderSettings other) {
    if (mergeDuplicates != other.mergeDuplicates ||
        blockScroll != other.blockScroll ||
        blockTop != other.blockTop ||
        blockBottom != other.blockBottom ||
        blockColor != other.blockColor ||
        blockedKeywords.length != other.blockedKeywords.length) {
      return true;
    }
    for (var i = 0; i < blockedKeywords.length; i++) {
      if (blockedKeywords[i] != other.blockedKeywords[i]) return true;
    }
    return false;
  }
}
