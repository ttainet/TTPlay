import 'dart:convert';
import 'dart:io';

import 'package:xml/xml.dart';

import 'iptv_models.dart';

/// Parses XMLTV (`xml` or `.xml.gz`) EPG data into an [IptvEpgIndex].
abstract final class XmltvParser {
  static final RegExp _xmltvTimePattern = RegExp(
    r'^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(?:\s*([+-])(\d{2})(\d{2})|\s*(Z))?',
    caseSensitive: false,
  );

  static IptvEpgIndex parseBytes(List<int> bytes, {DateTime? now}) {
    if (bytes.isEmpty) return IptvEpgIndex.empty;
    var rawBytes = bytes;
    if (rawBytes.length >= 2 && rawBytes[0] == 0x1f && rawBytes[1] == 0x8b) {
      try {
        rawBytes = gzip.decode(rawBytes);
      } catch (_) {
        return IptvEpgIndex.empty;
      }
    }
    final text = utf8.decode(rawBytes, allowMalformed: true);
    return parseString(text, now: now);
  }

  static IptvEpgIndex parseString(String xmlContent, {DateTime? now}) {
    final trimmed = xmlContent.trim();
    if (trimmed.isEmpty) return IptvEpgIndex.empty;
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(trimmed);
    } on XmlException {
      return IptvEpgIndex.empty;
    }

    final refNow = (now ?? DateTime.now()).toUtc();
    final windowStart = refNow.subtract(const Duration(hours: 2));
    final windowEnd = refNow.add(const Duration(hours: 24));

    final aliasesByChannelId = <String, Set<String>>{};
    for (final chElem in doc.rootElement.findElements('channel')) {
      final id = chElem.getAttribute('id')?.trim();
      if (id == null || id.isEmpty) continue;
      final normId = IptvEpgIndex.normalizeKey(id);
      final keys = aliasesByChannelId.putIfAbsent(normId, () => {normId});
      for (final nameElem in chElem.findElements('display-name')) {
        final nameKey = IptvEpgIndex.normalizeKey(nameElem.innerText);
        if (nameKey.isNotEmpty) keys.add(nameKey);
      }
    }

    final byKey = <String, List<IptvEpgProgram>>{};
    for (final progElem in doc.rootElement.findElements('programme')) {
      final rawChannel = progElem.getAttribute('channel')?.trim();
      if (rawChannel == null || rawChannel.isEmpty) continue;
      final start = _parseXmltvTime(progElem.getAttribute('start'));
      if (start == null) continue;
      final parsedStop = _parseXmltvTime(progElem.getAttribute('stop'));
      final end = (parsedStop != null && parsedStop.isAfter(start))
          ? parsedStop
          : start.add(const Duration(hours: 1));

      if (!end.isAfter(windowStart) || !start.isBefore(windowEnd)) {
        continue;
      }

      final titleElem = progElem.findElements('title').firstOrNull;
      final title = titleElem?.innerText.trim() ?? '';
      if (title.isEmpty) continue;
      final descText = progElem.findElements('desc').firstOrNull?.innerText.trim();
      final program = IptvEpgProgram(
        channelId: rawChannel,
        title: title,
        description: (descText == null || descText.isEmpty) ? null : descText,
        start: start,
        end: end,
      );

      final normId = IptvEpgIndex.normalizeKey(rawChannel);
      final keys = aliasesByChannelId[normId] ?? {normId};
      for (final key in keys) {
        byKey.putIfAbsent(key, () => []).add(program);
      }
    }

    for (final list in byKey.values) {
      list.sort((a, b) => a.start.compareTo(b.start));
    }
    return IptvEpgIndex(byKey);
  }

  static DateTime? _parseXmltvTime(String? raw) {
    if (raw == null) return null;
    final m = _xmltvTimePattern.firstMatch(raw.trim());
    if (m == null) return null;
    final year = int.parse(m.group(1)!);
    final month = int.parse(m.group(2)!);
    final day = int.parse(m.group(3)!);
    final hour = int.parse(m.group(4)!);
    final minute = int.parse(m.group(5)!);
    final second = int.parse(m.group(6)!);

    var utc = DateTime.utc(year, month, day, hour, minute, second);
    final sign = m.group(7);
    if (sign != null) {
      final offH = int.parse(m.group(8)!);
      final offM = int.parse(m.group(9)!);
      final offset = Duration(hours: offH, minutes: offM);
      utc = sign == '+' ? utc.subtract(offset) : utc.add(offset);
    }
    return utc;
  }
}
