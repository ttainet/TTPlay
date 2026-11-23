import 'package:collection/collection.dart';

/// Configuration for a single IPTV M3U/TXT subscription source (local or cloud-synced).
class IptvSource {
  final String id;
  final String name;
  final String m3uUrl;
  final String? epgUrl;
  final String? userAgent;
  final String? referer;
  final bool isCloud;
  final String? cloudSourceId;

  const IptvSource({
    required this.id,
    required this.name,
    required this.m3uUrl,
    this.epgUrl,
    this.userAgent,
    this.referer,
    this.isCloud = false,
    this.cloudSourceId,
  });

  IptvSource copyWith({
    String? id,
    String? name,
    String? m3uUrl,
    String? epgUrl,
    bool clearEpgUrl = false,
    String? userAgent,
    bool clearUserAgent = false,
    String? referer,
    bool clearReferer = false,
    bool? isCloud,
    String? cloudSourceId,
  }) {
    return IptvSource(
      id: id ?? this.id,
      name: name ?? this.name,
      m3uUrl: m3uUrl ?? this.m3uUrl,
      epgUrl: clearEpgUrl ? null : (epgUrl ?? this.epgUrl),
      userAgent: clearUserAgent ? null : (userAgent ?? this.userAgent),
      referer: clearReferer ? null : (referer ?? this.referer),
      isCloud: isCloud ?? this.isCloud,
      cloudSourceId: cloudSourceId ?? this.cloudSourceId,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'm3u_url': m3uUrl,
    if (epgUrl != null && epgUrl!.isNotEmpty) 'epg_url': epgUrl,
    if (userAgent != null && userAgent!.isNotEmpty) 'user_agent': userAgent,
    if (referer != null && referer!.isNotEmpty) 'referer': referer,
    'is_cloud': isCloud,
    if (cloudSourceId != null && cloudSourceId!.isNotEmpty) 'cloud_source_id': cloudSourceId,
  };

  factory IptvSource.fromJson(Map<String, dynamic> json) {
    String? opt(String key) {
      final raw = (json[key] as String?)?.trim();
      return (raw == null || raw.isEmpty) ? null : raw;
    }

    return IptvSource(
      id: (json['id'] as String? ?? '').trim(),
      name: (json['name'] as String? ?? '').trim(),
      m3uUrl: (json['m3u_url'] as String? ?? json['url'] as String? ?? '').trim(),
      epgUrl: opt('epg_url'),
      userAgent: opt('user_agent'),
      referer: opt('referer'),
      isCloud: json['is_cloud'] == true,
      cloudSourceId: opt('cloud_source_id'),
    );
  }
}

/// One playable stream URL (and its per-stream HTTP headers) for an [IptvChannel].
class IptvStreamVariant {
  final String url;
  final Map<String, String> headers;
  final String? label;
  final String sourceId;

  const IptvStreamVariant({
    required this.url,
    this.headers = const {},
    this.label,
    required this.sourceId,
  });
}

/// An IPTV channel parsed from an M3U/TXT playlist, merging identical `(group, name)` entries into [variants].
class IptvChannel {
  final String id;
  final String sourceId;
  final String name;
  final String group;
  final String? tvgId;
  final String? tvgName;
  final String? logo;
  final List<IptvStreamVariant> variants;

  const IptvChannel({
    required this.id,
    required this.sourceId,
    required this.name,
    required this.group,
    this.tvgId,
    this.tvgName,
    this.logo,
    required this.variants,
  });

  String get favoriteKey => '${group.trim().toLowerCase()}\u0000${name.trim().toLowerCase()}';

  IptvChannel copyWith({
    String? tvgId,
    String? tvgName,
    String? logo,
    List<IptvStreamVariant>? variants,
  }) {
    return IptvChannel(
      id: id,
      sourceId: sourceId,
      name: name,
      group: group,
      tvgId: tvgId ?? this.tvgId,
      tvgName: tvgName ?? this.tvgName,
      logo: logo ?? this.logo,
      variants: variants ?? this.variants,
    );
  }
}

/// A single EPG programme entry parsed from XMLTV.
class IptvEpgProgram {
  final String channelId;
  final String title;
  final String? description;
  final DateTime start;
  final DateTime end;

  const IptvEpgProgram({
    required this.channelId,
    required this.title,
    this.description,
    required this.start,
    required this.end,
  });

  bool isAiringAt(DateTime now) => !now.isBefore(start) && now.isBefore(end);
}

/// Fast lookup index for XMLTV programmes by normalized `tvg-id`, `tvg-name`, or channel `name`.
class IptvEpgIndex {
  final Map<String, List<IptvEpgProgram>> _byNormalizedKey;

  const IptvEpgIndex(this._byNormalizedKey);

  static const empty = IptvEpgIndex({});

  bool get isEmpty => _byNormalizedKey.isEmpty;

  static String normalizeKey(String raw) => raw.trim().toLowerCase();

  List<IptvEpgProgram>? _lookupPrograms(IptvChannel channel) {
    final candidates = <String?>[channel.tvgId, channel.tvgName, channel.name];
    for (final raw in candidates) {
      if (raw == null) continue;
      final key = normalizeKey(raw);
      if (key.isEmpty) continue;
      final list = _byNormalizedKey[key];
      if (list != null && list.isNotEmpty) return list;
    }
    return null;
  }

  ({IptvEpgProgram? current, IptvEpgProgram? next}) currentAndNextFor(IptvChannel channel, {DateTime? now}) {
    final programs = _lookupPrograms(channel);
    if (programs == null || programs.isEmpty) {
      return (current: null, next: null);
    }
    final target = (now ?? DateTime.now()).toUtc();
    final currentIdx = programs.indexWhere((p) => p.isAiringAt(target));
    if (currentIdx >= 0) {
      final next = currentIdx + 1 < programs.length ? programs[currentIdx + 1] : null;
      return (current: programs[currentIdx], next: next);
    }
    final next = programs.firstWhereOrNull((p) => p.start.isAfter(target));
    return (current: null, next: next);
  }
}
