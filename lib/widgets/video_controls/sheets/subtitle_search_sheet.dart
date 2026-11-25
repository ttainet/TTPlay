import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../../database/app_database.dart';
import '../../../focus/focusable_button.dart';
import '../../../focus/focusable_text_field.dart';
import '../../../focus/input_mode_tracker.dart';
import '../../../i18n/strings.g.dart';
import '../../../media/ids.dart';
import '../../../media/media_item.dart';
import '../../../media/media_kind.dart';
import '../../../media/media_server_client.dart';
import '../../../mixins/controller_disposer_mixin.dart';
import '../../../providers/multi_server_provider.dart';
import '../../../services/online_subtitle_store.dart';
import '../../../services/settings_service.dart';
import '../../../services/subtitle_search/online_subtitle_models.dart';
import '../../../services/subtitle_search/online_subtitle_service.dart';
import '../../../utils/error_message_utils.dart';
import '../../../utils/language_codes.dart';
import '../../../utils/snackbar_helper.dart';
import '../../../widgets/app_icon.dart';
import '../../../widgets/focusable_list_tile.dart';
import '../../../widgets/overlay_sheet.dart';
import '../../../widgets/pill_input_decoration.dart';
import '../../loading_indicator_box.dart';
import '../models/track_controls_state.dart';
import 'base_video_control_sheet.dart';

@visibleForTesting
String resolveSubtitleSearchLanguageCode({String? savedLanguageCode, required Locale systemLocale}) {
  return LanguageCodes.getIso6391Code(savedLanguageCode ?? '') ??
      LanguageCodes.getIso6391Code(systemLocale.languageCode) ??
      'en';
}

class SubtitleSearchSheet extends StatefulWidget {
  final MediaItem? metadata;
  final String? mediaTitle;
  final String? mediaSourceId;
  final String? filePath;
  final Future<SubtitleDownloadApplyOutcome> Function(CachedOnlineSubtitle subtitle)? onOnlineSubtitleApplied;

  /// Optional overrides for unit/widget tests.
  final OnlineSubtitleService? subtitleService;
  final OnlineSubtitleStore? subtitleStore;
  final OnlineSubtitleServerConfig? serverConfig;

  const SubtitleSearchSheet({
    super.key,
    this.metadata,
    this.mediaTitle,
    this.mediaSourceId,
    this.filePath,
    this.onOnlineSubtitleApplied,
    this.subtitleService,
    this.subtitleStore,
    this.serverConfig,
  });

  @override
  State<SubtitleSearchSheet> createState() => _SubtitleSearchSheetState();
}

class _SubtitleSearchSheetState extends State<SubtitleSearchSheet> with ControllerDisposerMixin {
  String _languageCode = 'en';
  String _languageName = 'English';
  String _selectedProvider = 'all';
  late final _titleController = createTextEditingController();
  final _languageFocusNode = FocusNode(debugLabel: 'SubtitleSearch_language');
  final _titleFocusNode = FocusNode(debugLabel: 'SubtitleSearch_title');
  final _firstResultFocusNode = FocusNode(debugLabel: 'SubtitleSearch_firstResult');
  Timer? _debounceTimer;

  OnlineSubtitleService? _ownedService;
  OnlineSubtitleService get _service => widget.subtitleService ?? (_ownedService ??= OnlineSubtitleService());

  List<OnlineSubtitleCandidate>? _results;
  List<String> _enabledProviders = const [];
  Map<String, CachedOnlineSubtitle> _cachedByKey = const {};
  bool _isSearching = false;
  String? _error;
  String? _downloadingKey;
  int _searchGeneration = 0;

  bool _showLanguagePicker = false;

  @override
  void initState() {
    super.initState();
    _initDefaultLanguage();
    WidgetsBinding.instance.addPostFrameCallback((_) => _search());
  }

  void _initDefaultLanguage() {
    final code = resolveSubtitleSearchLanguageCode(
      savedLanguageCode: SettingsService.instanceOrNull?.read(SettingsService.subtitleSearchLanguage),
      systemLocale: WidgetsBinding.instance.platformDispatcher.locale,
    );
    final name = LanguageCodes.getLanguageName(code);
    if (name == null) return;
    _languageCode = code;
    _languageName = name;
  }

  @override
  void dispose() {
    ++_searchGeneration;
    _debounceTimer?.cancel();
    _ownedService?.close();
    _languageFocusNode.dispose();
    _titleFocusNode.dispose();
    _firstResultFocusNode.dispose();
    super.dispose();
  }

  MultiServerProvider? _tryMultiServer() {
    try {
      return Provider.of<MultiServerProvider?>(context, listen: false);
    } catch (_) {
      return null;
    }
  }

  OnlineSubtitleStore? _trySubtitleStore() {
    if (widget.subtitleStore != null) return widget.subtitleStore;
    try {
      final db = Provider.of<AppDatabase?>(context, listen: false);
      return db == null ? null : OnlineSubtitleStore(db);
    } catch (_) {
      return null;
    }
  }

  OnlineSubtitleServerConfig? _resolveEndpoint() {
    if (widget.serverConfig != null) return widget.serverConfig;
    return OnlineSubtitleService.resolveEndpoint(_tryMultiServer());
  }

  MediaServerClient? _resolveMediaClient(MultiServerProvider? multiServer) {
    final serverId = widget.metadata?.serverId;
    if (multiServer == null || serverId == null || serverId.isEmpty) return null;
    return multiServer.serverManager.getClient(ServerId(serverId));
  }

  String get _effectiveItemGlobalKey {
    final gk = widget.metadata?.globalKey;
    if (gk != null && gk.isNotEmpty) return gk;
    final title = widget.mediaTitle?.trim();
    return (title != null && title.isNotEmpty) ? 'title:$title' : 'unknown';
  }

  Future<void> _refreshCachedIndex(OnlineSubtitleStore? store) async {
    if (store == null) return;
    try {
      final cached = await store.findCachedRemoteIds(_effectiveItemGlobalKey, mediaSourceId: widget.mediaSourceId);
      if (mounted) {
        setState(() => _cachedByKey = cached);
      }
    } catch (_) {}
  }

  Future<void> _search() async {
    if (!mounted) return;
    final generation = ++_searchGeneration;
    setState(() {
      _isSearching = true;
      _error = null;
    });

    final endpoint = _resolveEndpoint();
    if (endpoint == null) {
      if (!mounted || generation != _searchGeneration) return;
      setState(() {
        _isSearching = false;
        _error = t.videoControls.subtitleServerUnavailable;
      });
      return;
    }

    try {
      final multiServer = _tryMultiServer();
      final mediaClient = _resolveMediaClient(multiServer);
      final store = _trySubtitleStore();
      unawaited(_refreshCachedIndex(store));

      final manual = _titleController.text.trim();
      final metadata = widget.metadata;
      final OnlineSubtitleQuery query;
      if (metadata != null) {
        query = await OnlineSubtitleService.buildQuery(
          metadata: metadata,
          client: mediaClient,
          mediaSourceId: widget.mediaSourceId,
          activeFilePath: widget.filePath,
          language: _languageCode,
          manualQuery: manual.isEmpty ? null : manual,
        );
      } else {
        query = OnlineSubtitleQuery(
          itemGlobalKey: _effectiveItemGlobalKey,
          mediaSourceId: widget.mediaSourceId,
          title: widget.mediaTitle,
          kind: 'movie',
          language: _languageCode,
          manualQuery: manual.isEmpty ? null : manual,
        );
      }

      if (!mounted || generation != _searchGeneration) return;
      final response = await _service.search(endpoint, query);
      if (!mounted || generation != _searchGeneration) return;

      setState(() {
        _results = response.candidates;
        _enabledProviders = response.enabledProviders;
        if (_selectedProvider != 'all' && !response.candidates.any((c) => c.provider == _selectedProvider)) {
          _selectedProvider = 'all';
        }
        _isSearching = false;
      });
    } catch (e) {
      if (!mounted || generation != _searchGeneration) return;
      setState(() {
        _error = t.errors.searchFailed(error: localizedErrorReason(e));
        _isSearching = false;
      });
    }
  }

  List<OnlineSubtitleCandidate> get _filteredResults {
    final all = _results;
    if (all == null) return const [];
    if (_selectedProvider == 'all') return all;
    return all.where((c) => c.provider == _selectedProvider).toList(growable: false);
  }

  List<String> get _presentProviders {
    final all = _results;
    if (all == null || all.isEmpty) return const [];
    final seen = <String>{};
    for (final c in all) {
      if (c.provider.isNotEmpty) seen.add(c.provider);
    }
    return seen.toList(growable: false);
  }

  String _providerDisplayName(String provider) => switch (provider) {
    'xunlei' => t.videoControls.subtitleProviderXunlei,
    'assrt' => t.videoControls.subtitleProviderAssrt,
    'subdl' => t.videoControls.subtitleProviderSubdl,
    'opensubtitles' => t.videoControls.subtitleProviderOpenSubtitles,
    _ => provider,
  };

  void _onTitleChanged(String _) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 500), _search);
  }

  void _showLanguagePickerView() {
    setState(() => _showLanguagePicker = true);
    OverlaySheetController.of(context).refocus();
  }

  void _hideLanguagePickerView() {
    setState(() => _showLanguagePicker = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _languageFocusNode.requestFocus();
    });
  }

  void _focusFirstResult() {
    if (_filteredResults.isNotEmpty && !_isSearching && _error == null) {
      _firstResultFocusNode.requestFocus();
    }
  }

  Future<void> _submitSearchAndFocusFirstResult() async {
    _debounceTimer?.cancel();
    await _search();
    if (!mounted || !InputModeTracker.isKeyboardMode(context, listen: false)) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusFirstResult();
    });
  }

  void _onLanguageSelected(String code, String name) {
    _debounceTimer?.cancel();
    setState(() {
      _languageCode = code;
      _languageName = name;
      _showLanguagePicker = false;
    });
    final settings = SettingsService.instanceOrNull;
    if (settings != null) {
      unawaited(settings.write(SettingsService.subtitleSearchLanguage, code));
    }
    OverlaySheetController.of(context).refocus();
    _search();
  }

  Future<void> _selectCandidate(OnlineSubtitleCandidate candidate) async {
    if (_downloadingKey != null) return;
    setState(() => _downloadingKey = candidate.cacheIdentity);

    try {
      final store = _trySubtitleStore();
      var cached = _cachedByKey[candidate.cacheIdentity];
      if (cached != null && store != null) {
        await store.markSelected(
          cached.id,
          itemGlobalKey: _effectiveItemGlobalKey,
          mediaSourceId: widget.mediaSourceId,
        );
      } else {
        final endpoint = _resolveEndpoint();
        if (endpoint == null || store == null) {
          if (!mounted) return;
          showErrorSnackBar(context, t.videoControls.subtitleDownloadFailed);
          setState(() => _downloadingKey = null);
          return;
        }
        final isEpisode = widget.metadata?.kind == MediaKind.episode;
        cached = await _service.downloadAndCache(
          endpoint,
          candidate: candidate,
          itemGlobalKey: _effectiveItemGlobalKey,
          mediaSourceId: widget.mediaSourceId,
          season: isEpisode ? widget.metadata?.parentIndex : null,
          episode: isEpisode ? widget.metadata?.index : null,
          store: store,
        );
        if (mounted) {
          setState(() {
            _cachedByKey = {..._cachedByKey, candidate.cacheIdentity: cached!};
          });
        }
      }

      if (!mounted) return;

      final outcome = await widget.onOnlineSubtitleApplied?.call(cached) ?? SubtitleDownloadApplyOutcome.unavailable;
      if (!mounted) return;
      if (outcome == SubtitleDownloadApplyOutcome.applied) {
        showSuccessSnackBar(context, t.videoControls.subtitleDownloaded);
        OverlaySheetController.of(context).close();
      } else {
        showErrorSnackBar(
          context,
          outcome == SubtitleDownloadApplyOutcome.timedOut
              ? t.videoControls.subtitleDownloadTimedOut
              : t.videoControls.subtitleDownloadedNotApplied,
        );
        setState(() => _downloadingKey = null);
      }
    } catch (e) {
      if (!mounted) return;
      showErrorSnackBar(context, t.videoControls.subtitleDownloadFailed);
      setState(() => _downloadingKey = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_showLanguagePicker) {
      return _LanguagePickerView(
        currentCode: _languageCode,
        onSelected: _onLanguageSelected,
        onBack: _hideLanguagePickerView,
      );
    }

    final fillColor = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08);
    final visibleResults = _filteredResults;
    final hasResults = visibleResults.isNotEmpty && !_isSearching && _error == null;
    final presentProviders = _presentProviders;

    return BaseVideoControlSheet(
      title: t.videoControls.searchSubtitles,
      icon: Symbols.search_rounded,
      onBack: () => OverlaySheetController.of(context).pop(),
      // Deliberately fills the sheet's height cap instead of hugging content.
      // Overlay sheets are bottom-anchored, so a content-driven height would
      // move the search field on every state transition — spinner, results,
      // error, empty — while the user is still typing in it.
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                FocusableButton(
                  focusNode: _languageFocusNode,
                  onPressed: _showLanguagePickerView,
                  onNavigateRight: _titleFocusNode.requestFocus,
                  onNavigateDown: hasResults ? _focusFirstResult : null,
                  autoScroll: false,
                  child: Material(
                    color: fillColor,
                    borderRadius: pillInputRadius,
                    child: InkWell(
                      borderRadius: pillInputRadius,
                      canRequestFocus: false,
                      onTap: _showLanguagePickerView,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_languageName),
                            const SizedBox(width: 2),
                            const AppIcon(Symbols.arrow_drop_down_rounded, size: 20),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FocusableTextField(
                    controller: _titleController,
                    focusNode: _titleFocusNode,
                    tvTextInputPresentation: TvTextInputPresentation.flutterOverlay,
                    decoration: pillInputDecoration(
                      context,
                      hintText: widget.mediaTitle ?? widget.metadata?.title ?? t.metadataEdit.title,
                      prefixIcon: const AppIcon(Symbols.search_rounded, size: 20),
                    ),
                    onChanged: _onTitleChanged,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => unawaited(_submitSearchAndFocusFirstResult()),
                    onSelect: () => unawaited(_submitSearchAndFocusFirstResult()),
                    onNavigateLeft: _languageFocusNode.requestFocus,
                    onNavigateDown: hasResults ? _focusFirstResult : null,
                  ),
                ),
              ],
            ),
          ),
          if (presentProviders.length > 1 && !_isSearching && _error == null)
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(t.videoControls.subtitleProviderAll),
                      selected: _selectedProvider == 'all',
                      onSelected: (_) => setState(() => _selectedProvider = 'all'),
                    ),
                  ),
                  for (final prov in presentProviders)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(_providerDisplayName(prov)),
                        selected: _selectedProvider == prov,
                        onSelected: (_) => setState(() => _selectedProvider = prov),
                      ),
                    ),
                ],
              ),
            ),
          Expanded(child: _buildResults(visibleResults)),
        ],
      ),
    );
  }

  String _buildCandidateSubtitle(OnlineSubtitleCandidate candidate) {
    final parts = <String>[
      _providerDisplayName(candidate.provider),
      candidate.format.toUpperCase(),
      if (candidate.hearingImpaired) 'HI',
      if (candidate.forced) 'Forced',
      if (candidate.releaseName != null &&
          candidate.releaseName!.trim().isNotEmpty &&
          candidate.releaseName!.trim() != candidate.title.trim())
        candidate.releaseName!.trim(),
    ];
    return parts.join(' · ');
  }

  Widget _buildResults(List<OnlineSubtitleCandidate> visibleResults) {
    if (_isSearching) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ),
      );
    }

    if (_results == null) {
      return const SizedBox.shrink();
    }

    if (_results!.isEmpty && _enabledProviders.isEmpty) {
      return Center(
        child: Text(
          t.videoControls.subtitleNoProvidersConfigured,
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      );
    }

    if (visibleResults.isEmpty) {
      return Center(
        child: Text(
          t.videoControls.noSubtitlesFound,
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      );
    }

    return ListView.builder(
      itemCount: visibleResults.length,
      itemBuilder: (context, index) {
        final candidate = visibleResults[index];
        final isDownloading = _downloadingKey == candidate.cacheIdentity;
        final isCached = _cachedByKey.containsKey(candidate.cacheIdentity);
        final colorScheme = Theme.of(context).colorScheme;

        Widget? trailing;
        if (isDownloading) {
          trailing = const LoadingIndicatorBox(size: 20);
        } else {
          final trailingChildren = <Widget>[];
          if (isCached) {
            trailingChildren.add(
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(color: colorScheme.primaryContainer, borderRadius: BorderRadius.circular(6)),
                child: Text(
                  t.videoControls.subtitleCached,
                  style: TextStyle(fontSize: 11, color: colorScheme.onPrimaryContainer, fontWeight: FontWeight.w600),
                ),
              ),
            );
          }
          if (candidate.perfectMatch) {
            trailingChildren.add(const AppIcon(Symbols.star_rounded, fill: 1, color: Color(0xFFCC7B19), size: 16));
          }
          if (candidate.downloads > 0) {
            trailingChildren.add(
              Text('${candidate.downloads}', style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant)),
            );
          } else if (candidate.score != null) {
            trailingChildren.add(
              Text(
                candidate.score!.toInt().toString(),
                style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
              ),
            );
          }
          if (trailingChildren.isNotEmpty) {
            trailing = Row(mainAxisSize: MainAxisSize.min, spacing: 6, children: trailingChildren);
          }
        }

        return FocusableListTile(
          focusNode: index == 0 ? _firstResultFocusNode : null,
          title: Text(
            candidate.title.trim().isNotEmpty ? candidate.title : (candidate.releaseName ?? t.common.unknown),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            _buildCandidateSubtitle(candidate),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: colorScheme.onSurfaceVariant),
          ),
          trailing: trailing,
          onTap: isDownloading ? null : () => _selectCandidate(candidate),
        );
      },
    );
  }
}

class _LanguagePickerView extends StatefulWidget {
  final String currentCode;
  final void Function(String code, String name) onSelected;
  final VoidCallback onBack;

  const _LanguagePickerView({required this.currentCode, required this.onSelected, required this.onBack});

  @override
  State<_LanguagePickerView> createState() => _LanguagePickerViewState();
}

class _LanguagePickerViewState extends State<_LanguagePickerView> with ControllerDisposerMixin {
  late final _filterController = createTextEditingController();
  final _filterFocusNode = FocusNode(debugLabel: 'SubtitleLanguage_filter');
  final _firstLanguageFocusNode = FocusNode(debugLabel: 'SubtitleLanguage_firstResult');
  late List<({String code, String name})> _allLanguages;
  List<({String code, String name})> _filteredLanguages = [];

  @override
  void initState() {
    super.initState();
    _allLanguages = LanguageCodes.getAllLanguages();
    _filteredLanguages = _allLanguages;
  }

  @override
  void dispose() {
    _filterFocusNode.dispose();
    _firstLanguageFocusNode.dispose();
    super.dispose();
  }

  void _focusFirstLanguage() {
    if (_filteredLanguages.isNotEmpty) {
      _firstLanguageFocusNode.requestFocus();
    }
  }

  void _focusFirstLanguageAfterSubmit() {
    if (!InputModeTracker.isKeyboardMode(context)) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusFirstLanguage();
    });
  }

  void _onFilterChanged(String query) {
    final lower = query.toLowerCase();
    setState(() {
      if (lower.isEmpty) {
        _filteredLanguages = _allLanguages;
      } else {
        _filteredLanguages = _allLanguages.where((l) {
          return l.name.toLowerCase().contains(lower) || l.code.toLowerCase().contains(lower);
        }).toList();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return BaseVideoControlSheet(
      title: t.videoControls.language,
      icon: Symbols.language_rounded,
      onBack: widget.onBack,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: FocusableTextField(
              controller: _filterController,
              focusNode: _filterFocusNode,
              tvTextInputPresentation: TvTextInputPresentation.flutterOverlay,
              autofocus: true,
              decoration: pillInputDecoration(
                context,
                hintText: t.videoControls.searchLanguages,
                prefixIcon: const AppIcon(Symbols.search_rounded, size: 20),
              ),
              onChanged: _onFilterChanged,
              onSubmitted: (_) => _focusFirstLanguageAfterSubmit(),
              onSelect: _focusFirstLanguageAfterSubmit,
              onNavigateDown: _filteredLanguages.isNotEmpty ? _focusFirstLanguage : null,
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _filteredLanguages.length,
              itemBuilder: (context, index) {
                final lang = _filteredLanguages[index];
                final isSelected = lang.code == widget.currentCode;
                return FocusableListTile(
                  focusNode: index == 0 ? _firstLanguageFocusNode : null,
                  title: Text(
                    lang.name,
                    style: TextStyle(color: isSelected ? Theme.of(context).colorScheme.primary : null),
                  ),
                  trailing: isSelected
                      ? AppIcon(Symbols.check_rounded, fill: 1, color: Theme.of(context).colorScheme.primary)
                      : null,
                  onTap: () => widget.onSelected(lang.code, lang.name),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
