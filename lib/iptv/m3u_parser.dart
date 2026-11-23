import 'iptv_models.dart';

class M3uParseResult {
  final List<IptvChannel> channels;
  final String? headerEpgUrl;

  const M3uParseResult({required this.channels, this.headerEpgUrl});
}

class _PendingExtInf {
  String? tvgId;
  String? tvgName;
  String? logo;
  String? group;
  String? title;
  final Map<String, String> headers = {};
}

class _ChannelAccumulator {
  final String id;
  final String sourceId;
  final String name;
  final String group;
  String? tvgId;
  String? tvgName;
  String? logo;
  final List<IptvStreamVariant> variants = [];
  final Set<String> seenUrls = {};

  _ChannelAccumulator({
    required this.id,
    required this.sourceId,
    required this.name,
    required this.group,
    this.tvgId,
    this.tvgName,
    this.logo,
  });

  IptvChannel build() => IptvChannel(
    id: id,
    sourceId: sourceId,
    name: name,
    group: group,
    tvgId: tvgId,
    tvgName: tvgName,
    logo: logo,
    variants: List<IptvStreamVariant>.unmodifiable(variants),
  );
}

/// Parses both extended M3U/M3U8 playlists and `#genre#` TXT channel lists.
abstract final class M3uParser {
  static const String defaultGroupName = '未分组';
  static final RegExp _attrPattern = RegExp(r'''([A-Za-z0-9_-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s,]+))''');
  static final RegExp _streamSchemePattern = RegExp(r'^(https?|rtmp|rtsp)://', caseSensitive: false);
  static final RegExp _txtUrlSplitPattern = RegExp(r',\s*(?=(?:https?|rtmp|rtsp)://)', caseSensitive: false);

  static M3uParseResult parse(
    String content, {
    required String sourceId,
    String? defaultUserAgent,
    String? defaultReferer,
  }) {
    var normalized = content;
    if (normalized.startsWith('\uFEFF')) {
      normalized = normalized.substring(1);
    }
    final lines = normalized.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
    final isM3u = lines.any((line) {
      final trimmed = line.trimLeft();
      return trimmed.startsWith('#EXTM3U') || trimmed.startsWith('#EXTINF');
    });

    if (isM3u) {
      return _parseM3u(
        lines,
        sourceId: sourceId,
        defaultUserAgent: defaultUserAgent,
        defaultReferer: defaultReferer,
      );
    }
    return _parseTxt(
      lines,
      sourceId: sourceId,
      defaultUserAgent: defaultUserAgent,
      defaultReferer: defaultReferer,
    );
  }

  static M3uParseResult _parseM3u(
    List<String> lines, {
    required String sourceId,
    String? defaultUserAgent,
    String? defaultReferer,
  }) {
    String? headerEpgUrl;
    _PendingExtInf? pending;
    String? extGrp;
    final pendingVlcHeaders = <String, String>{};
    final accumulators = <String, _ChannelAccumulator>{};

    void resetEntry() {
      pending = null;
      extGrp = null;
      pendingVlcHeaders.clear();
    }

    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;

      if (line.startsWith('#EXTM3U')) {
        final attrs = _parseAttributes(line.substring('#EXTM3U'.length));
        headerEpgUrl ??= _pickHttpUrl(attrs['x-tvg-url'] ?? attrs['url-tvg']);
        continue;
      }

      if (line.startsWith('#EXTINF:')) {
        final body = line.substring('#EXTINF:'.length);
        final commaIdx = _lastUnquotedCommaIndex(body);
        final metaPart = commaIdx >= 0 ? body.substring(0, commaIdx) : body;
        final titlePart = commaIdx >= 0 ? body.substring(commaIdx + 1).trim() : '';
        final attrs = _parseAttributes(metaPart);

        final nextPending = _PendingExtInf()
          ..tvgId = _nonEmpty(attrs['tvg-id'])
          ..tvgName = _nonEmpty(attrs['tvg-name'])
          ..logo = _nonEmpty(attrs['tvg-logo'])
          ..group = _nonEmpty(attrs['group-title'])
          ..title = _nonEmpty(titlePart) ?? _nonEmpty(attrs['tvg-name']) ?? _nonEmpty(attrs['tvg-id']);

        final attrUa = _nonEmpty(attrs['http-user-agent']);
        if (attrUa != null) nextPending.headers['User-Agent'] = attrUa;
        final attrRef = _nonEmpty(attrs['http-referrer']) ?? _nonEmpty(attrs['http-referer']);
        if (attrRef != null) nextPending.headers['Referer'] = attrRef;

        pending = nextPending;
        extGrp = null;
        pendingVlcHeaders.clear();
        continue;
      }

      if (line.startsWith('#EXTGRP:')) {
        final grp = _nonEmpty(line.substring('#EXTGRP:'.length));
        if (grp != null) extGrp = grp;
        continue;
      }

      if (line.startsWith('#EXTVLCOPT:')) {
        final opt = line.substring('#EXTVLCOPT:'.length).trim();
        final eqIdx = opt.indexOf('=');
        if (eqIdx > 0) {
          final key = opt.substring(0, eqIdx).trim().toLowerCase();
          final val = opt.substring(eqIdx + 1).trim();
          if (val.isNotEmpty) {
            if (key == 'http-user-agent') {
              pendingVlcHeaders['User-Agent'] = val;
            } else if (key == 'http-referrer' || key == 'http-referer') {
              pendingVlcHeaders['Referer'] = val;
            }
          }
        }
        continue;
      }

      if (line.startsWith('#')) continue;

      final parsedUrl = _splitPipeUrlAndHeaders(line);
      if (!_streamSchemePattern.hasMatch(parsedUrl.url)) {
        resetEntry();
        continue;
      }

      final meta = pending;
      final group = _nonEmpty(meta?.group) ?? extGrp ?? defaultGroupName;
      final name = _nonEmpty(meta?.title) ?? _fallbackChannelName(parsedUrl.url);
      final ua = _nonEmpty(defaultUserAgent);
      final ref = _nonEmpty(defaultReferer);
      final mergedHeaders = <String, String>{
        'User-Agent': ?ua,
        'Referer': ?ref,
        ...?meta?.headers,
        ...pendingVlcHeaders,
        ...parsedUrl.headers,
      };

      _appendChannelVariant(
        accumulators,
        sourceId: sourceId,
        name: name,
        group: group,
        tvgId: meta?.tvgId,
        tvgName: meta?.tvgName,
        logo: meta?.logo,
        url: parsedUrl.url,
        headers: mergedHeaders,
      );
      resetEntry();
    }

    return M3uParseResult(
      channels: [for (final acc in accumulators.values) acc.build()],
      headerEpgUrl: headerEpgUrl,
    );
  }

  static M3uParseResult _parseTxt(
    List<String> lines, {
    required String sourceId,
    String? defaultUserAgent,
    String? defaultReferer,
  }) {
    var currentGroup = defaultGroupName;
    final accumulators = <String, _ChannelAccumulator>{};
    final ua = _nonEmpty(defaultUserAgent);
    final ref = _nonEmpty(defaultReferer);
    final defaultHeaders = <String, String>{
      'User-Agent': ?ua,
      'Referer': ?ref,
    };

    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith('//')) continue;

      if (line.endsWith(',#genre#')) {
        final grp = line.substring(0, line.length - ',#genre#'.length).trim();
        if (grp.isNotEmpty) currentGroup = grp;
        continue;
      }

      final match = _txtUrlSplitPattern.firstMatch(line);
      if (match == null) continue;
      final name = line.substring(0, match.start).trim();
      final rawRight = line.substring(match.end).trim();
      if (name.isEmpty || rawRight.isEmpty) continue;

      for (final rawUrlPart in rawRight.split('#')) {
        final candidate = rawUrlPart.trim();
        if (candidate.isEmpty) continue;
        final parsedUrl = _splitPipeUrlAndHeaders(candidate);
        if (!_streamSchemePattern.hasMatch(parsedUrl.url)) continue;
        final mergedHeaders = <String, String>{...defaultHeaders, ...parsedUrl.headers};
        _appendChannelVariant(
          accumulators,
          sourceId: sourceId,
          name: name,
          group: currentGroup,
          url: parsedUrl.url,
          headers: mergedHeaders,
        );
      }
    }

    return M3uParseResult(channels: [for (final acc in accumulators.values) acc.build()]);
  }

  static void _appendChannelVariant(
    Map<String, _ChannelAccumulator> accumulators, {
    required String sourceId,
    required String name,
    required String group,
    String? tvgId,
    String? tvgName,
    String? logo,
    required String url,
    required Map<String, String> headers,
  }) {
    final dedupKey = '${group.toLowerCase()}\u0000${name.toLowerCase()}';
    final acc = accumulators.putIfAbsent(
      dedupKey,
      () => _ChannelAccumulator(
        id: '$sourceId:${group.toLowerCase()}:${name.toLowerCase()}',
        sourceId: sourceId,
        name: name,
        group: group,
        tvgId: tvgId,
        tvgName: tvgName,
        logo: logo,
      ),
    );
    acc.tvgId ??= tvgId;
    acc.tvgName ??= tvgName;
    acc.logo ??= logo;

    if (acc.seenUrls.add(url)) {
      acc.variants.add(
        IptvStreamVariant(
          url: url,
          headers: Map<String, String>.unmodifiable(headers),
          label: '线路 ${acc.variants.length + 1}',
          sourceId: sourceId,
        ),
      );
    }
  }

  static Map<String, String> _parseAttributes(String raw) {
    final result = <String, String>{};
    for (final m in _attrPattern.allMatches(raw)) {
      final key = (m.group(1) ?? '').trim().toLowerCase();
      final val = m.group(2) ?? m.group(3) ?? m.group(4) ?? '';
      if (key.isNotEmpty) {
        result[key] = val.trim();
      }
    }
    return result;
  }

  static int _lastUnquotedCommaIndex(String input) {
    String? quote;
    var lastComma = -1;
    for (var i = 0; i < input.length; i++) {
      final ch = input[i];
      if (quote != null) {
        if (ch == quote) quote = null;
      } else if (ch == '"' || ch == "'") {
        quote = ch;
      } else if (ch == ',') {
        lastComma = i;
      }
    }
    return lastComma;
  }

  static ({String url, Map<String, String> headers}) _splitPipeUrlAndHeaders(String raw) {
    final pipeIdx = raw.indexOf('|');
    if (pipeIdx < 0) {
      return (url: raw.trim(), headers: const {});
    }
    final url = raw.substring(0, pipeIdx).trim();
    final tail = raw.substring(pipeIdx + 1).trim();
    if (tail.isEmpty) {
      return (url: url, headers: const {});
    }

    final headers = <String, String>{};
    for (final part in tail.split('&')) {
      final eqIdx = part.indexOf('=');
      if (eqIdx <= 0) continue;
      final rawKey = part.substring(0, eqIdx).trim();
      final rawVal = part.substring(eqIdx + 1).trim();
      if (rawKey.isEmpty || rawVal.isEmpty) continue;
      final val = _safeDecodeComponent(rawVal);
      final normalizedKey = switch (rawKey.toLowerCase()) {
        'user-agent' => 'User-Agent',
        'referer' || 'referrer' => 'Referer',
        'origin' => 'Origin',
        'cookie' => 'Cookie',
        _ => rawKey,
      };
      headers[normalizedKey] = val;
    }
    return (url: url, headers: headers);
  }

  static String _safeDecodeComponent(String value) {
    try {
      return Uri.decodeComponent(value);
    } catch (_) {
      return value;
    }
  }

  static String? _pickHttpUrl(String? raw) {
    if (raw == null) return null;
    for (final part in raw.split(',')) {
      final trimmed = part.trim();
      final lower = trimmed.toLowerCase();
      if (lower.startsWith('http://') || lower.startsWith('https://')) {
        return trimmed;
      }
    }
    return null;
  }

  static String _fallbackChannelName(String url) {
    final uri = Uri.tryParse(url);
    final last = uri?.pathSegments.where((s) => s.isNotEmpty).lastOrNull;
    return (last != null && last.isNotEmpty) ? last : url;
  }

  static String? _nonEmpty(String? s) {
    if (s == null) return null;
    final t = s.trim();
    return t.isEmpty ? null : t;
  }
}
