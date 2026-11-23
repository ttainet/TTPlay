import 'dart:async';

import 'package:flutter/material.dart';

import '../media/live_tv_support.dart';
import '../media/media_backend.dart';
import '../media/media_source_info.dart';
import '../models/livetv_capture_buffer.dart';
import '../models/livetv_channel.dart';
import '../screens/video_player/live_tv_session_args.dart';
import '../screens/video_player_screen.dart';
import '../utils/live_tv_player_navigation.dart';
import '../utils/video_player_navigation.dart';
import 'iptv_models.dart';

/// [LiveTvCustomHeaderSession] adapter for direct IPTV stream variants with custom HTTP headers.
class IptvPlaybackSession implements LiveTvCustomHeaderSession {
  final IptvChannel channel;
  final int variantIndex;

  IptvPlaybackSession({required this.channel, this.variantIndex = 0});

  IptvStreamVariant get activeVariant {
    if (channel.variants.isEmpty) {
      return IptvStreamVariant(url: '', sourceId: channel.sourceId);
    }
    final safeIdx = variantIndex.clamp(0, channel.variants.length - 1);
    return channel.variants[safeIdx];
  }

  @override
  Map<String, String> get streamHeaders => {
    'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
    ...activeVariant.headers,
  };

  @override
  LiveProgramInfo get program => LiveProgramInfo.none;

  @override
  LiveTvBackgroundPolicy get backgroundPolicy => LiveTvBackgroundPolicy.stopAndExit;

  @override
  CaptureBuffer? get captureBuffer => null;

  @override
  List<MediaSubtitleTrack> get subtitleTracks => const [];

  @override
  bool get canTimeShift => false;

  @override
  Future<String?> streamUrlAt({int? offsetSeconds, MediaSubtitleTrack? subtitleTrack}) async {
    if (offsetSeconds != null) return null;
    final url = activeVariant.url;
    return url.isEmpty ? null : url;
  }

  @override
  Future<LiveTimelineUpdate?> reportTimeline({
    required String state,
    required int positionMs,
    required int durationMs,
  }) async => null;

  @override
  Future<void> discard() async {}

  @override
  Future<LiveTvPlaybackSession?> recover({
    required bool directStream,
    required bool directStreamAudio,
  }) async => this;
}

LiveTvChannel _toLiveTvChannel(IptvChannel ch) => LiveTvChannel(
  key: ch.id,
  identifier: ch.id,
  callSign: ch.group,
  title: ch.name,
  thumb: ch.logo,
  serverId: ch.sourceId,
  serverName: ch.group,
);

/// Opens [VideoPlayerScreen] in live mode for an IPTV [channel], enabling D-pad/UI channel zapping over [channels].
Future<void> navigateToIptvChannel(
  BuildContext context, {
  required IptvChannel channel,
  required List<IptvChannel> channels,
  int variantIndex = 0,
}) async {
  final ordered = <IptvChannel>[
    if (channels.any((c) => c.id == channel.id)) ...channels else ...[channel, ...channels],
  ];
  final byId = <String, IptvChannel>{for (final ch in ordered) ch.id: ch};
  final liveChannels = [for (final ch in ordered) _toLiveTvChannel(ch)];
  final initialIndex = ordered.indexWhere((c) => c.id == channel.id);
  final initialLiveChannel = liveChannels[initialIndex >= 0 ? initialIndex : 0];
  final placeholder = liveTvChannelItem(
    initialLiveChannel,
    backend: MediaBackend.jellyfin,
    serverId: channel.sourceId,
  );

  final route = VideoPlayerRoute(
    builder: (_) => VideoPlayerScreen(
      metadata: placeholder,
      live: LiveTvSessionArgs(
        channel: initialLiveChannel,
        channels: liveChannels,
        currentChannelIndex: initialIndex >= 0 ? initialIndex : 0,
        startPosition: LiveTvStartPosition.live,
        startSession: (liveChannel) async {
          final target = byId[liveChannel.key];
          if (target == null) return null;
          final vIdx = target.id == channel.id ? variantIndex : 0;
          return IptvPlaybackSession(channel: target, variantIndex: vIdx);
        },
      ),
    ),
  );

  unawaited(route.push(Navigator.of(context)));
}
