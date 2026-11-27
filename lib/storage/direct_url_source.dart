import 'http_range_reader.dart';
import 'storage_driver.dart';

/// Drive-agnostic transfer policy pushed from the Dart control plane into
/// [NativeStreamEngine] for a registered playback URL.
class DriveTransferProfile {
  const DriveTransferProfile({
    this.minConnections = 1,
    this.maxConnections = 5,
    this.windowBytes = 24 * 1024 * 1024,
    this.minSegmentBytes = 2 * 1024 * 1024,
    this.maxSegmentBytes = 16 * 1024 * 1024,
    this.probeBypassBytes = 512 * 1024,
    this.cacheRedirectUrl = true,
    this.redirectCacheTtlSecs = 90,
    this.staleStatuses = const [401, 403, 404, 410, 412],
    this.scaleUpEvalSecs = 3,
    this.scaleUpMinGainRatio = 1.15,
    this.rateLimitCooldownSecs = 60,
    this.workStealMinRemainingSecs = 4.0,
    this.stallTimeoutSecs = 20,
    this.demandDrivenScaleUp = true,
    this.bitrateSafetyFactor = 1.8,
    this.lowBufferSecs = 10.0,
    this.highBufferSecs = 20.0,
    this.allowRuntimeMaxUpgrade = false,
    this.userAgent,
  });

  final int minConnections;
  final int maxConnections;
  final int windowBytes;
  final int minSegmentBytes;
  final int maxSegmentBytes;
  final int probeBypassBytes;
  final bool cacheRedirectUrl;
  final int redirectCacheTtlSecs;
  final List<int> staleStatuses;
  final int scaleUpEvalSecs;
  final double scaleUpMinGainRatio;
  final int rateLimitCooldownSecs;
  final double workStealMinRemainingSecs;
  final int stallTimeoutSecs;
  final bool demandDrivenScaleUp;
  final double bitrateSafetyFactor;
  final double lowBufferSecs;
  final double highBufferSecs;
  final bool allowRuntimeMaxUpgrade;
  final String? userAgent;

  Map<String, Object?> toJson() => {
    'min_connections': minConnections,
    'max_connections': maxConnections,
    'window_bytes': windowBytes,
    'min_segment_bytes': minSegmentBytes,
    'max_segment_bytes': maxSegmentBytes,
    'probe_bypass_bytes': probeBypassBytes,
    'cache_redirect_url': cacheRedirectUrl,
    'redirect_cache_ttl_secs': redirectCacheTtlSecs,
    'stale_statuses': staleStatuses,
    'scale_up_eval_secs': scaleUpEvalSecs,
    'scale_up_min_gain_ratio': scaleUpMinGainRatio,
    'rate_limit_cooldown_secs': rateLimitCooldownSecs,
    'work_steal_min_remaining_secs': workStealMinRemainingSecs,
    'stall_timeout_secs': stallTimeoutSecs,
    'demand_driven_scale_up': demandDrivenScaleUp,
    'bitrate_safety_factor': bitrateSafetyFactor,
    'low_buffer_secs': lowBufferSecs,
    'high_buffer_secs': highBufferSecs,
    'allow_runtime_max_upgrade': allowRuntimeMaxUpgrade,
    if (userAgent != null) 'user_agent': userAgent,
  };
}

/// Resolved direct HTTP origin link + metadata for a single playback item.
class DirectPlaybackSource {
  const DirectPlaybackSource({
    required this.link,
    required this.totalSize,
    this.contentType,
    this.profile = const DriveTransferProfile(),
    this.resolveDeferredMaxConnections,
  });

  final StorageLink link;
  final int totalSize;
  final String? contentType;
  final DriveTransferProfile profile;
  final Future<int?> Function()? resolveDeferredMaxConnections;
}

/// Control-plane contract implemented by HTTP/cloud storage drivers (Quark,
/// WebDAV, future drives) so the native Rust engine can stream directly from
/// origin URLs while keeping auth, link resolution, and refresh in Dart.
abstract interface class DirectUrlReadSource {
  bool get nativeStreamEnabled;

  Future<DirectPlaybackSource> resolveDirectPlayback(StorageEntry entry, {bool forceRefresh = false});
}
