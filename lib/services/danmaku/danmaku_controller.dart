import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../media/media_item.dart';
import '../../providers/multi_server_provider.dart';
import '../../utils/app_logger.dart';
import '../settings_service.dart';
import 'danmaku_models.dart';
import 'danmaku_service.dart';

/// Filters and deduplicates raw danmaku comments according to [settings].
///
/// Mirrors NipaPlay-Reload's type/keyword blocking and sliding-window duplicate
/// merging (`×N`) while returning a time-sorted immutable list.
@visibleForTesting
List<DanmakuCommentItem> processDanmakuComments(List<DanmakuCommentItem> raw, DanmakuRenderSettings settings) {
  if (raw.isEmpty) return const [];

  final loweredKeywords = settings.blockedKeywords
      .map((k) => k.trim().toLowerCase())
      .where((k) => k.isNotEmpty)
      .toList(growable: false);

  final filtered = <DanmakuCommentItem>[];
  for (final item in raw) {
    final text = item.text.trim();
    if (text.isEmpty) continue;

    if (settings.blockScroll && item.mode == DanmakuMode.scroll) continue;
    if (settings.blockTop && item.mode == DanmakuMode.top) continue;
    if (settings.blockBottom && item.mode == DanmakuMode.bottom) continue;
    if (settings.blockColor && item.isColored) continue;

    if (loweredKeywords.isNotEmpty) {
      final lowerText = text.toLowerCase();
      var blocked = false;
      for (final kw in loweredKeywords) {
        if (lowerText.contains(kw)) {
          blocked = true;
          break;
        }
      }
      if (blocked) continue;
    }

    filtered.add(item);
  }

  filtered.sort((a, b) => a.timeSeconds.compareTo(b.timeSeconds));
  if (!settings.mergeDuplicates || filtered.length <= 1) {
    return List<DanmakuCommentItem>.unmodifiable(filtered);
  }

  const mergeWindowSec = 10.0;
  final merged = <DanmakuCommentItem>[];
  // Key: "<mode.index>:<normalizedText>" -> index in `merged`
  final recentIndexByKey = <String, int>{};

  for (final item in filtered) {
    final normalized = item.text.trim().toLowerCase();
    final key = '${item.mode.index}:$normalized';
    final existingIdx = recentIndexByKey[key];
    if (existingIdx != null) {
      final prev = merged[existingIdx];
      if ((item.timeSeconds - prev.timeSeconds) <= mergeWindowSec) {
        merged[existingIdx] = prev.copyWith(mergeCount: prev.mergeCount + 1);
        continue;
      }
    }
    recentIndexByKey[key] = merged.length;
    merged.add(item);
  }

  return List<DanmakuCommentItem>.unmodifiable(merged);
}

class DanmakuController extends ChangeNotifier {
  DanmakuController({DanmakuService? service})
    : _service = service ?? DanmakuService(),
      _ownsService = service == null {
    _loadPrefsFromSettings();
  }

  final DanmakuService _service;
  final bool _ownsService;

  bool _enabled = false;
  bool _autoMatch = true;
  DanmakuRenderSettings _settings = const DanmakuRenderSettings();

  bool _isLoading = false;
  String? _error;
  String? _matchedAnimeTitle;
  String? _matchedEpisodeTitle;
  String? _episodeId;
  String? _sourceUrl;
  int _totalCount = 0;
  bool _sampled = false;
  bool _cached = false;

  List<DanmakuCommentItem> _rawComments = const [];
  List<DanmakuCommentItem> _processedComments = const [];
  int _commentsVersion = 0;

  String? _activeItemKey;
  MediaItem? _activeMetadata;
  String? _activeFilePath;
  MultiServerProvider? _activeMultiServer;
  bool _pendingAutoMatch = false;
  int _loadGeneration = 0;
  bool _disposed = false;

  bool get enabled => _enabled;
  bool get autoMatch => _autoMatch;
  DanmakuRenderSettings get settings => _settings;

  bool get isLoading => _isLoading;
  String? get error => _error;
  String? get matchedAnimeTitle => _matchedAnimeTitle;
  String? get matchedEpisodeTitle => _matchedEpisodeTitle;
  String? get episodeId => _episodeId;
  String? get sourceUrl => _sourceUrl;
  int get totalCount => _totalCount;
  bool get sampled => _sampled;
  bool get cached => _cached;

  List<DanmakuCommentItem> get rawComments => _rawComments;
  List<DanmakuCommentItem> get processedComments => _processedComments;
  int get commentsVersion => _commentsVersion;

  DanmakuServerConfig? resolveEndpoint() => DanmakuService.resolveEndpoint(_activeMultiServer);

  void _loadPrefsFromSettings() {
    final s = SettingsService.instanceOrNull;
    if (s == null) return;
    _enabled = s.read(SettingsService.danmakuEnabled);
    _autoMatch = s.read(SettingsService.danmakuAutoMatch);
    _settings = DanmakuRenderSettings(
      fontSize: s.read(SettingsService.danmakuFontSize).clamp(12.0, 44.0),
      opacity: s.read(SettingsService.danmakuOpacity).clamp(0.1, 1.0),
      scrollDurationSeconds: s.read(SettingsService.danmakuScrollDuration).clamp(4.0, 18.0),
      displayArea: s.read(SettingsService.danmakuDisplayArea).clamp(0.25, 1.0),
      strokeWidth: s.read(SettingsService.danmakuStrokeWidth).clamp(0.0, 3.0),
      mergeDuplicates: s.read(SettingsService.danmakuMergeDuplicates),
      allowStacking: s.read(SettingsService.danmakuAllowStacking),
      blockScroll: s.read(SettingsService.danmakuBlockScroll),
      blockTop: s.read(SettingsService.danmakuBlockTop),
      blockBottom: s.read(SettingsService.danmakuBlockBottom),
      blockColor: s.read(SettingsService.danmakuBlockColor),
      blockedKeywords: s.read(SettingsService.danmakuBlockedKeywords),
    );
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  void syncForItem({required MediaItem metadata, String? activeFilePath, required MultiServerProvider? multiServer}) {
    _activeMetadata = metadata;
    _activeFilePath = activeFilePath;
    _activeMultiServer = multiServer;

    final itemKey = '${metadata.globalKey}|${activeFilePath ?? ''}';
    if (_activeItemKey == itemKey) return;
    _activeItemKey = itemKey;

    ++_loadGeneration;
    _isLoading = false;
    _error = null;
    _matchedAnimeTitle = null;
    _matchedEpisodeTitle = null;
    _episodeId = null;
    _sourceUrl = null;
    _totalCount = 0;
    _sampled = false;
    _cached = false;
    _rawComments = const [];
    _processedComments = const [];
    _commentsVersion++;
    _pendingAutoMatch = false;

    if (_enabled && _autoMatch) {
      unawaited(_runAutoMatch());
    } else if (_autoMatch) {
      _pendingAutoMatch = true;
    }
    _notify();
  }

  Future<void> toggleEnabled() => setEnabled(!_enabled);

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    _notify();

    final s = SettingsService.instanceOrNull;
    if (s != null) {
      await s.write(SettingsService.danmakuEnabled, value);
    }

    if (value && _pendingAutoMatch && _rawComments.isEmpty && !_isLoading) {
      _pendingAutoMatch = false;
      unawaited(_runAutoMatch());
    }
  }

  Future<void> setAutoMatch(bool value) async {
    if (_autoMatch == value) return;
    _autoMatch = value;
    _notify();

    final s = SettingsService.instanceOrNull;
    if (s != null) {
      await s.write(SettingsService.danmakuAutoMatch, value);
    }

    if (value && _enabled && _rawComments.isEmpty && !_isLoading && _activeMetadata != null) {
      unawaited(_runAutoMatch());
    }
  }

  void setTimeOffset(double seconds) {
    final clamped = seconds.clamp(-60.0, 60.0);
    if ((_settings.timeOffsetSeconds - clamped).abs() < 0.001) return;
    _settings = _settings.copyWith(timeOffsetSeconds: clamped);
    _notify();
  }

  Future<void> updateSettings(DanmakuRenderSettings next) async {
    final prev = _settings;
    _settings = next;
    if (next.filterOrMergeDiffersFrom(prev)) {
      _processedComments = processDanmakuComments(_rawComments, next);
      _commentsVersion++;
    }
    _notify();

    final s = SettingsService.instanceOrNull;
    if (s == null) return;

    await Future.wait([
      if (prev.fontSize != next.fontSize) s.write(SettingsService.danmakuFontSize, next.fontSize),
      if (prev.opacity != next.opacity) s.write(SettingsService.danmakuOpacity, next.opacity),
      if (prev.scrollDurationSeconds != next.scrollDurationSeconds)
        s.write(SettingsService.danmakuScrollDuration, next.scrollDurationSeconds),
      if (prev.displayArea != next.displayArea) s.write(SettingsService.danmakuDisplayArea, next.displayArea),
      if (prev.strokeWidth != next.strokeWidth) s.write(SettingsService.danmakuStrokeWidth, next.strokeWidth),
      if (prev.mergeDuplicates != next.mergeDuplicates)
        s.write(SettingsService.danmakuMergeDuplicates, next.mergeDuplicates),
      if (prev.allowStacking != next.allowStacking) s.write(SettingsService.danmakuAllowStacking, next.allowStacking),
      if (prev.blockScroll != next.blockScroll) s.write(SettingsService.danmakuBlockScroll, next.blockScroll),
      if (prev.blockTop != next.blockTop) s.write(SettingsService.danmakuBlockTop, next.blockTop),
      if (prev.blockBottom != next.blockBottom) s.write(SettingsService.danmakuBlockBottom, next.blockBottom),
      if (prev.blockColor != next.blockColor) s.write(SettingsService.danmakuBlockColor, next.blockColor),
      if (!listEquals(prev.blockedKeywords, next.blockedKeywords))
        s.write(SettingsService.danmakuBlockedKeywords, next.blockedKeywords),
    ]);
  }

  Future<void> rematch({bool refresh = false}) => _runAutoMatch(refresh: refresh);

  Future<void> _runAutoMatch({bool refresh = false}) async {
    final metadata = _activeMetadata;
    final endpoint = resolveEndpoint();
    if (metadata == null || endpoint == null) return;

    final gen = ++_loadGeneration;
    _isLoading = true;
    _error = null;
    _notify();

    try {
      final matchRes = await _service.match(
        endpoint,
        metadata: metadata,
        activeFilePath: _activeFilePath,
        refresh: refresh,
      );
      if (_disposed || gen != _loadGeneration) return;

      if (!matchRes.matched || matchRes.matches.isEmpty) {
        _isLoading = false;
        _matchedAnimeTitle = null;
        _matchedEpisodeTitle = null;
        _rawComments = const [];
        _processedComments = const [];
        _commentsVersion++;
        _notify();
        return;
      }

      final first = matchRes.matches.first;
      await _loadCommentsForSelection(
        endpoint: endpoint,
        generation: gen,
        episodeId: first.episodeId,
        sourceUrl: first.sourceUrl,
        animeTitle: first.animeTitle,
        episodeTitle: first.episodeTitle,
        refresh: refresh,
      );
    } catch (e, st) {
      appLogger.w('Danmaku auto-match failed', error: e, stackTrace: st);
      if (_disposed || gen != _loadGeneration) return;
      _isLoading = false;
      _error = e.toString();
      _notify();
    }
  }

  Future<List<DanmakuAnimeItem>> searchAnime(String keyword) async {
    final endpoint = resolveEndpoint();
    if (endpoint == null) {
      throw StateError('Danmaku server endpoint is unavailable');
    }
    return _service.searchAnime(endpoint, keyword);
  }

  Future<DanmakuBangumiDetail> getBangumi(String animeId) async {
    final endpoint = resolveEndpoint();
    if (endpoint == null) {
      throw StateError('Danmaku server endpoint is unavailable');
    }
    return _service.getBangumi(endpoint, animeId);
  }

  Future<void> selectEpisode({
    required String episodeId,
    String? sourceUrl,
    String? animeTitle,
    String? episodeTitle,
    bool refresh = false,
  }) async {
    final endpoint = resolveEndpoint();
    if (endpoint == null) return;

    final gen = ++_loadGeneration;
    _isLoading = true;
    _error = null;
    _pendingAutoMatch = false;
    _notify();

    try {
      await _loadCommentsForSelection(
        endpoint: endpoint,
        generation: gen,
        episodeId: episodeId,
        sourceUrl: sourceUrl,
        animeTitle: animeTitle,
        episodeTitle: episodeTitle,
        refresh: refresh,
      );
    } catch (e, st) {
      appLogger.w('Danmaku episode load failed', error: e, stackTrace: st);
      if (_disposed || gen != _loadGeneration) return;
      _isLoading = false;
      _error = e.toString();
      _notify();
    }
  }

  Future<void> _loadCommentsForSelection({
    required DanmakuServerConfig endpoint,
    required int generation,
    required String episodeId,
    String? sourceUrl,
    String? animeTitle,
    String? episodeTitle,
    bool refresh = false,
  }) async {
    final resp = await _service.getComments(endpoint, episodeId: episodeId, sourceUrl: sourceUrl, refresh: refresh);
    if (_disposed || generation != _loadGeneration) return;

    _episodeId = resp.episodeId.isNotEmpty ? resp.episodeId : episodeId;
    _sourceUrl = resp.sourceUrl.isNotEmpty ? resp.sourceUrl : sourceUrl;
    if (animeTitle != null && animeTitle.isNotEmpty) {
      _matchedAnimeTitle = animeTitle;
    }
    if (episodeTitle != null && episodeTitle.isNotEmpty) {
      _matchedEpisodeTitle = episodeTitle;
    }
    _totalCount = resp.totalCount;
    _sampled = resp.sampled;
    _cached = resp.cached;
    _rawComments = resp.comments;
    _processedComments = processDanmakuComments(resp.comments, _settings);
    _commentsVersion++;
    _isLoading = false;
    _error = null;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_loadGeneration;
    if (_ownsService) {
      _service.close();
    }
    super.dispose();
  }
}
