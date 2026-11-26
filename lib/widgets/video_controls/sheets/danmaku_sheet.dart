import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../focus/focusable_text_field.dart';
import '../../../i18n/strings.g.dart';
import '../../../services/danmaku/danmaku_controller.dart';
import '../../../services/danmaku/danmaku_models.dart';
import '../../../theme/mono_tokens.dart';
import '../../../widgets/app_icon.dart';
import '../../../widgets/focusable_list_tile.dart';
import '../../../widgets/pill_input_decoration.dart';
import '../../loading_indicator_box.dart';
import 'base_video_control_sheet.dart';

enum _DanmakuSheetTab { display, filter, source }

class DanmakuSheet extends StatefulWidget {
  final DanmakuController controller;

  const DanmakuSheet({super.key, required this.controller});

  @override
  State<DanmakuSheet> createState() => _DanmakuSheetState();
}

class _DanmakuSheetState extends State<DanmakuSheet> {
  _DanmakuSheetTab _tab = _DanmakuSheetTab.display;
  final TextEditingController _keywordController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();

  bool _searching = false;
  String? _searchError;
  List<DanmakuAnimeItem>? _searchResults;
  DanmakuBangumiDetail? _selectedBangumi;
  bool _loadingBangumi = false;

  @override
  void initState() {
    super.initState();
    final currentAnime = widget.controller.matchedAnimeTitle;
    if (currentAnime != null && currentAnime.isNotEmpty) {
      _searchController.text = currentAnime;
    }
  }

  @override
  void dispose() {
    _keywordController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _addKeyword() async {
    final kw = _keywordController.text.trim();
    if (kw.isEmpty) return;
    final current = widget.controller.settings.blockedKeywords;
    if (!current.contains(kw)) {
      await widget.controller.updateSettings(widget.controller.settings.copyWith(blockedKeywords: [...current, kw]));
    }
    _keywordController.clear();
  }

  Future<void> _removeKeyword(String kw) async {
    final next = widget.controller.settings.blockedKeywords.where((e) => e != kw).toList(growable: false);
    await widget.controller.updateSettings(widget.controller.settings.copyWith(blockedKeywords: next));
  }

  Future<void> _performSearch() async {
    final query = _searchController.text.trim();
    if (query.isEmpty || _searching) return;
    setState(() {
      _searching = true;
      _searchError = null;
      _selectedBangumi = null;
    });
    try {
      final results = await widget.controller.searchAnime(query);
      if (!mounted) return;
      setState(() {
        _searchResults = results;
        _searching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _searchError = e.toString();
      });
    }
  }

  Future<void> _openBangumi(DanmakuAnimeItem anime) async {
    if (_loadingBangumi) return;
    setState(() {
      _loadingBangumi = true;
      _searchError = null;
    });
    try {
      final detail = await widget.controller.getBangumi(anime.animeId);
      if (!mounted) return;
      setState(() {
        _selectedBangumi = detail;
        _loadingBangumi = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingBangumi = false;
        _searchError = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return BaseVideoControlSheet(
      title: t.danmaku.title,
      icon: Symbols.comment_rounded,
      child: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                child: SegmentedButton<_DanmakuSheetTab>(
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(value: _DanmakuSheetTab.display, label: Text(t.danmaku.tabDisplay)),
                    ButtonSegment(value: _DanmakuSheetTab.filter, label: Text(t.danmaku.tabFilter)),
                    ButtonSegment(value: _DanmakuSheetTab.source, label: Text(t.danmaku.tabSource)),
                  ],
                  selected: {_tab},
                  onSelectionChanged: (sel) {
                    if (sel.isNotEmpty) {
                      setState(() => _tab = sel.first);
                    }
                  },
                ),
              ),
              Expanded(
                child: switch (_tab) {
                  _DanmakuSheetTab.display => _buildDisplayTab(context),
                  _DanmakuSheetTab.filter => _buildFilterTab(context),
                  _DanmakuSheetTab.source => _buildSourceTab(context),
                },
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildDisplayTab(BuildContext context) {
    final c = widget.controller;
    final s = c.settings;
    final th = tokens(context);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        SwitchListTile(
          value: c.enabled,
          onChanged: (v) => unawaited(c.setEnabled(v)),
          title: Text(t.danmaku.enabled),
          contentPadding: EdgeInsets.zero,
        ),
        SwitchListTile(
          value: c.autoMatch,
          onChanged: (v) => unawaited(c.setAutoMatch(v)),
          title: Text(t.danmaku.autoMatch),
          contentPadding: EdgeInsets.zero,
        ),
        const Divider(),
        _SliderTile(
          label: t.danmaku.fontSize,
          valueLabel: '${s.fontSize.round()}',
          value: s.fontSize,
          min: 12,
          max: 44,
          divisions: 32,
          onChanged: (v) => unawaited(c.updateSettings(s.copyWith(fontSize: v.roundToDouble()))),
        ),
        _SliderTile(
          label: t.danmaku.opacity,
          valueLabel: '${(s.opacity * 100).round()}%',
          value: s.opacity,
          min: 0.1,
          max: 1.0,
          divisions: 18,
          onChanged: (v) => unawaited(c.updateSettings(s.copyWith(opacity: v))),
        ),
        _SliderTile(
          label: t.danmaku.scrollSpeed,
          valueLabel: '${s.scrollDurationSeconds.toStringAsFixed(1)}s',
          value: s.scrollDurationSeconds,
          min: 4.0,
          max: 18.0,
          divisions: 28,
          onChanged: (v) => unawaited(c.updateSettings(s.copyWith(scrollDurationSeconds: v))),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 6),
          child: Text(t.danmaku.displayArea, style: Theme.of(context).textTheme.bodyMedium),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final opt in [
              (0.25, t.danmaku.areaQuarter),
              (0.50, t.danmaku.areaHalf),
              (0.75, t.danmaku.areaThreeQuarters),
              (1.00, t.danmaku.areaFull),
            ])
              ChoiceChip(
                label: Text(opt.$2),
                selected: (s.displayArea - opt.$1).abs() < 0.05,
                onSelected: (_) => unawaited(c.updateSettings(s.copyWith(displayArea: opt.$1))),
              ),
          ],
        ),
        const SizedBox(height: 8),
        _SliderTile(
          label: t.danmaku.strokeWidth,
          valueLabel: s.strokeWidth.toStringAsFixed(1),
          value: s.strokeWidth,
          min: 0.0,
          max: 3.0,
          divisions: 15,
          onChanged: (v) => unawaited(c.updateSettings(s.copyWith(strokeWidth: v))),
        ),
        SwitchListTile(
          value: s.mergeDuplicates,
          onChanged: (v) => unawaited(c.updateSettings(s.copyWith(mergeDuplicates: v))),
          title: Text(t.danmaku.mergeDuplicates),
          contentPadding: EdgeInsets.zero,
        ),
        SwitchListTile(
          value: s.allowStacking,
          onChanged: (v) => unawaited(c.updateSettings(s.copyWith(allowStacking: v))),
          title: Text(t.danmaku.allowStacking),
          contentPadding: EdgeInsets.zero,
        ),
        const Divider(),
        Row(
          children: [
            Expanded(child: Text(t.danmaku.timeOffset, style: Theme.of(context).textTheme.bodyMedium)),
            Text(
              '${s.timeOffsetSeconds >= 0 ? '+' : ''}${s.timeOffsetSeconds.toStringAsFixed(1)}s',
              style: TextStyle(color: th.textMuted, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ActionChip(label: const Text('-5s'), onPressed: () => c.setTimeOffset(s.timeOffsetSeconds - 5.0)),
            ActionChip(label: const Text('-0.5s'), onPressed: () => c.setTimeOffset(s.timeOffsetSeconds - 0.5)),
            ActionChip(label: Text(t.danmaku.reset), onPressed: () => c.setTimeOffset(0.0)),
            ActionChip(label: const Text('+0.5s'), onPressed: () => c.setTimeOffset(s.timeOffsetSeconds + 0.5)),
            ActionChip(label: const Text('+5s'), onPressed: () => c.setTimeOffset(s.timeOffsetSeconds + 5.0)),
          ],
        ),
      ],
    );
  }

  Widget _buildFilterTab(BuildContext context) {
    final c = widget.controller;
    final s = c.settings;
    final th = tokens(context);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        SwitchListTile(
          value: s.blockScroll,
          onChanged: (v) => unawaited(c.updateSettings(s.copyWith(blockScroll: v))),
          title: Text(t.danmaku.blockScroll),
          contentPadding: EdgeInsets.zero,
        ),
        SwitchListTile(
          value: s.blockTop,
          onChanged: (v) => unawaited(c.updateSettings(s.copyWith(blockTop: v))),
          title: Text(t.danmaku.blockTop),
          contentPadding: EdgeInsets.zero,
        ),
        SwitchListTile(
          value: s.blockBottom,
          onChanged: (v) => unawaited(c.updateSettings(s.copyWith(blockBottom: v))),
          title: Text(t.danmaku.blockBottom),
          contentPadding: EdgeInsets.zero,
        ),
        SwitchListTile(
          value: s.blockColor,
          onChanged: (v) => unawaited(c.updateSettings(s.copyWith(blockColor: v))),
          title: Text(t.danmaku.blockColor),
          contentPadding: EdgeInsets.zero,
        ),
        const Divider(),
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 8),
          child: Text(t.danmaku.blockedKeywords, style: Theme.of(context).textTheme.titleSmall),
        ),
        Row(
          children: [
            Expanded(
              child: FocusableTextField(
                controller: _keywordController,
                decoration: pillInputDecoration(context, hintText: t.danmaku.keywordHint),
                onSubmitted: (_) => unawaited(_addKeyword()),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(onPressed: () => unawaited(_addKeyword()), child: Text(t.danmaku.addKeyword)),
          ],
        ),
        const SizedBox(height: 12),
        if (s.blockedKeywords.isEmpty)
          Text(t.danmaku.noKeywords, style: TextStyle(color: th.textMuted, fontSize: 13))
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final kw in s.blockedKeywords)
                InputChip(label: Text(kw), onDeleted: () => unawaited(_removeKeyword(kw))),
            ],
          ),
      ],
    );
  }

  Widget _buildSourceTab(BuildContext context) {
    final c = widget.controller;
    final th = tokens(context);
    final endpoint = c.resolveEndpoint();

    if (endpoint == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(t.danmaku.serverUnavailable, style: TextStyle(color: th.textMuted)),
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        c.matchedAnimeTitle?.isNotEmpty == true ? c.matchedAnimeTitle! : t.danmaku.notMatched,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    TextButton.icon(
                      onPressed: c.isLoading ? null : () => unawaited(c.rematch(refresh: true)),
                      icon: const AppIcon(Symbols.refresh_rounded, size: 16),
                      label: Text(t.danmaku.rematch),
                    ),
                  ],
                ),
                if (c.matchedEpisodeTitle?.isNotEmpty == true)
                  Text(c.matchedEpisodeTitle!, style: TextStyle(color: th.textMuted, fontSize: 12)),
                if (c.isLoading)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(t.danmaku.loading, style: TextStyle(color: th.textMuted, fontSize: 12)),
                  )
                else if (c.rawComments.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      t.danmaku.loadedSummary(count: c.processedComments.length, totalCount: c.totalCount),
                      style: TextStyle(color: th.textMuted, fontSize: 12),
                    ),
                  ),
                if (c.error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      c.error!,
                      style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: FocusableTextField(
                  controller: _searchController,
                  decoration: pillInputDecoration(context, hintText: t.danmaku.searchHint),
                  onSubmitted: (_) => unawaited(_performSearch()),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _searching ? null : () => unawaited(_performSearch()),
                child: Text(t.danmaku.searchButton),
              ),
            ],
          ),
        ),
        if (_searchError != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(_searchError!, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
          ),
        Expanded(child: _buildSearchBody(context, c, th)),
      ],
    );
  }

  Widget _buildSearchBody(BuildContext context, DanmakuController c, dynamic th) {
    if (_searching || _loadingBangumi) {
      return const LoadingIndicatorBox();
    }
    final bangumi = _selectedBangumi;
    if (bangumi != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: TextButton.icon(
              onPressed: () => setState(() => _selectedBangumi = null),
              icon: const AppIcon(Symbols.arrow_back_rounded, size: 18),
              label: Text('${t.danmaku.backToResults} · ${bangumi.animeTitle}'),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: bangumi.episodes.length,
              itemBuilder: (context, index) {
                final ep = bangumi.episodes[index];
                final isSelected = c.episodeId == ep.episodeId && ep.episodeId.isNotEmpty;
                return FocusableListTile(
                  title: Text(ep.episodeTitle.isNotEmpty ? ep.episodeTitle : 'E${ep.episodeNumber}'),
                  trailing: isSelected ? const AppIcon(Symbols.check_rounded, fill: 1) : null,
                  onTap: () {
                    unawaited(
                      c.selectEpisode(
                        episodeId: ep.episodeId,
                        sourceUrl: ep.sourceUrl,
                        animeTitle: bangumi.animeTitle,
                        episodeTitle: ep.episodeTitle,
                      ),
                    );
                    Navigator.of(context).maybePop();
                  },
                );
              },
            ),
          ),
        ],
      );
    }

    final results = _searchResults;
    if (results == null) {
      return const SizedBox.shrink();
    }
    if (results.isEmpty) {
      return Center(
        child: Text(t.danmaku.noResults, style: TextStyle(color: th.textMuted)),
      );
    }
    return ListView.builder(
      itemCount: results.length,
      itemBuilder: (context, index) {
        final item = results[index];
        final subtitleParts = <String>[
          if (item.source.isNotEmpty) item.source,
          if (item.typeDescription.isNotEmpty) item.typeDescription,
          if (item.episodeCount > 0) '${item.episodeCount} ${t.danmaku.episodes}',
        ];
        return FocusableListTile(
          title: Text(item.animeTitle),
          subtitle: subtitleParts.isNotEmpty ? Text(subtitleParts.join(' · ')) : null,
          trailing: const AppIcon(Symbols.chevron_right_rounded, fill: 1),
          onTap: () => unawaited(_openBangumi(item)),
        );
      },
    );
  }
}

class _SliderTile extends StatelessWidget {
  final String label;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;

  const _SliderTile({
    required this.label,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final th = tokens(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(label, style: Theme.of(context).textTheme.bodyMedium)),
            Text(
              valueLabel,
              style: TextStyle(color: th.textMuted, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        Slider(value: value.clamp(min, max), min: min, max: max, divisions: divisions, onChanged: onChanged),
      ],
    );
  }
}
