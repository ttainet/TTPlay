import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/iptv/iptv_models.dart';
import 'package:plezy/iptv/iptv_provider.dart';
import 'package:plezy/iptv/m3u_parser.dart';
import 'package:plezy/iptv/xmltv_parser.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('M3uParser', () {
    test('parses M3U attributes with commas, headers, EXTGRP, EXTVLCOPT, and variant merging', () {
      const playlist = '''
#EXTM3U x-tvg-url="https://epg.example.com/guide.xml"
#EXTINF:-1 tvg-id="cctv1" tvg-name="CCTV-1 综合" tvg-logo="https://img.example.com/cctv1.png" group-title="央视, 主频道",CCTV-1 综合
#EXTVLCOPT:http-user-agent=VlcAgent/1.0
#EXTVLCOPT:http-referrer=https://ref.example.com/
https://stream.example.com/cctv1/a.m3u8
#EXTINF:-1 group-title="央视, 主频道",CCTV-1 综合
https://stream.example.com/cctv1/b.m3u8|User-Agent=PipeUA&Referer=https%3A%2F%2Fpipe.example.com%2F
#EXTINF:-1,Standalone Channel
#EXTGRP:卫视
https://stream.example.com/ws/index.m3u8
''';

      final result = M3uParser.parse(playlist, sourceId: 'src1', defaultUserAgent: 'DefaultUA');
      expect(result.headerEpgUrl, 'https://epg.example.com/guide.xml');
      expect(result.channels.length, 2);

      final cctv1 = result.channels[0];
      expect(cctv1.name, 'CCTV-1 综合');
      expect(cctv1.group, '央视, 主频道');
      expect(cctv1.tvgId, 'cctv1');
      expect(cctv1.tvgName, 'CCTV-1 综合');
      expect(cctv1.logo, 'https://img.example.com/cctv1.png');
      expect(cctv1.variants.length, 2);
      expect(cctv1.variants[0].url, 'https://stream.example.com/cctv1/a.m3u8');
      expect(cctv1.variants[0].headers['User-Agent'], 'VlcAgent/1.0');
      expect(cctv1.variants[0].headers['Referer'], 'https://ref.example.com/');
      expect(cctv1.variants[1].url, 'https://stream.example.com/cctv1/b.m3u8');
      expect(cctv1.variants[1].headers['User-Agent'], 'PipeUA');
      expect(cctv1.variants[1].headers['Referer'], 'https://pipe.example.com/');

      final ws = result.channels[1];
      expect(ws.name, 'Standalone Channel');
      expect(ws.group, '卫视');
      expect(ws.variants.single.headers['User-Agent'], 'DefaultUA');
    });

    test('parses #genre# TXT format with #-separated variants and deduplication', () {
      const txt = '''
央视频道,#genre#
CCTV1,https://a.example.com/1.m3u8#https://b.example.com/1.m3u8
CCTV1,https://a.example.com/1.m3u8
卫视频道,#genre#
湖南卫视,https://cdn.example.com/hunan.m3u8|User-Agent=MobileUA
''';

      final result = M3uParser.parse(txt, sourceId: 'txt1');
      expect(result.channels.length, 2);
      expect(result.channels[0].group, '央视频道');
      expect(result.channels[0].variants.map((v) => v.url).toList(), [
        'https://a.example.com/1.m3u8',
        'https://b.example.com/1.m3u8',
      ]);
      expect(result.channels[1].group, '卫视频道');
      expect(result.channels[1].variants.single.url, 'https://cdn.example.com/hunan.m3u8');
      expect(result.channels[1].variants.single.headers['User-Agent'], 'MobileUA');
    });
  });

  group('XmltvParser', () {
    test('parses plain and gzipped XMLTV with timezone offsets and display-name aliases', () {
      final xml = '''
<tv>
  <channel id="ch-1">
    <display-name>CCTV-1 综合</display-name>
  </channel>
  <programme start="20261123150000 +0800" stop="20261123160000 +0800" channel="ch-1">
    <title>新闻联播</title>
  </programme>
  <programme start="20261123160000 +0800" stop="20261123170000 +0800" channel="ch-1">
    <title>焦点访谈</title>
  </programme>
</tv>
''';
      final nowUtc = DateTime.utc(2026, 11, 23, 7, 30); // 15:30 +0800
      final gzBytes = gzip.encode(utf8.encode(xml));
      final index = XmltvParser.parseBytes(gzBytes, now: nowUtc);
      expect(index.isEmpty, isFalse);

      // Lookup by display-name alias even when tvg-id differs
      const channelByName = IptvChannel(
        id: '1',
        sourceId: 's1',
        name: 'CCTV-1 综合',
        group: '央视',
        variants: [IptvStreamVariant(url: 'https://x/1.m3u8', sourceId: 's1')],
      );
      final prog = index.currentAndNextFor(channelByName, now: nowUtc);
      expect(prog.current?.title, '新闻联播');
      expect(prog.next?.title, '焦点访谈');
    });
  });

  group('IptvProvider', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('persists local sources, merges cloud sources, toggles favorites, and loads playlist/EPG', () async {
      const sampleM3u = '''
#EXTM3U x-tvg-url="https://epg.example.com/e.xml"
#EXTINF:-1 tvg-id="c1" group-title="央视",CCTV-1
https://live.example.com/cctv1.m3u8
''';
      final provider = IptvProvider(
        httpClientFactory: () => MockClient((request) async {
          if (request.url.toString().endsWith('all.m3u')) {
            return http.Response.bytes(utf8.encode(sampleM3u), 200);
          }
          return http.Response('not found', 404);
        }),
      );
      addTearDown(provider.dispose);

      await provider.loadLocalSources();
      expect(provider.hasSources, isFalse);

      const local = IptvSource(
        id: 'local:1',
        name: 'Home IPTV',
        m3uUrl: 'http://192.168.1.2:1905/all.m3u',
      );
      await provider.addLocalSource(local);
      expect(provider.hasSources, isTrue);
      expect(provider.localSources.length, 1);

      const cloud = IptvSource(
        id: 'cloud:abc',
        name: 'Cloud IPTV',
        m3uUrl: 'http://cloud.example.com/all.m3u',
        isCloud: true,
        cloudSourceId: 'abc',
      );
      provider.setCloudSources([cloud]);
      expect(provider.sources.map((s) => s.id).toList(), ['cloud:abc', 'local:1']);
      expect(provider.activeSource?.id, 'cloud:abc');

      provider.selectSource(local.id);
      expect(provider.selectedSourceId, local.id);
      expect(provider.activeSource?.id, local.id);

      await provider.ensureLoaded(local);
      final channels = provider.channelsFor(local.id);
      expect(channels.length, 1);
      expect(channels.first.name, 'CCTV-1');

      await provider.toggleFavorite(channels.first);
      expect(provider.isFavorite(channels.first), isTrue);

      // Verify persistence survives reload
      final reloaded = IptvProvider();
      addTearDown(reloaded.dispose);
      await reloaded.loadLocalSources();
      expect(reloaded.localSources.single.m3uUrl, local.m3uUrl);
      expect(reloaded.isFavorite(channels.first), isTrue);

      await provider.removeLocalSource(local.id);
      expect(provider.selectedSourceId, isNull);
      expect(provider.activeSource?.id, 'cloud:abc');

      provider.setCloudSources(const []);
      expect(provider.activeSource, isNull);
      expect(provider.hasSources, isFalse);
    });
  });
}
