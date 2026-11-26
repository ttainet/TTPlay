import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../focus/focusable_slider.dart';
import '../../../focus/focusable_text_field.dart';
import '../../../focus/focusable_wrapper.dart';
import '../../../focus/input_mode_tracker.dart';
import '../../../i18n/strings.g.dart';
import '../../../services/danmaku/danmaku_controller.dart';
import '../../../services/danmaku/danmaku_models.dart';
import '../../../theme/mono_tokens.dart';
import '../../../widgets/app_icon.dart';
import '../../../widgets/focusable_list_tile.dart';
import '../../../widgets/overlay_sheet.dart';
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
  late final List<FocusNode> _tabFocusNodes = List.generate(
    _DanmakuSheetTab.values.length,
    (i) => FocusNode(debugLabel: 'danmaku_tab_$i'),
  );

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
    for (final node in _tabFocusNodes) {
      node.dispose();
    }
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

  String _tabLabel(_DanmakuSheetTab tab) {
    return switch (tab) {
      _DanmakuSheetTab.display => t.danmaku.tabDisplay,
      _DanmakuSheetTab.filter => t.danmaku.tabFilter,
      _DanmakuSheetTab.source => t.danmaku.tabSource,
    };
  }

  Widget _buildTabBar(BuildContext context) {
    final tabs = _DanmakuSheetTab.values;
    final colorScheme = Theme.of(context).colorScheme;
    final th = tokens(context);

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          for (var i = 0; i < tabs.length; i++) ...[
            if (i > 0) const SizedBox(width: 4),
            Expanded(
              child: FocusableWrapper(
                focusNode: _tabFocusNodes[i],
                autofocus: i == 0,
                autoScroll: false,
                descendantsAreFocusable: false,
                borderRadius: 10,
                semanticLabel: _tabLabel(tabs[i]),
                checked: _tab == tabs[i],
                onSelect: () => setState(() => _tab = tabs[i]),
                onNavigateLeft: i > 0 ? () => _tabFocusNodes[i - 1].requestFocus() : null,
                onNavigateRight: i < tabs.length - 1 ? () => _tabFocusNodes[i + 1].requestFocus() : null,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _tab = tabs[i]),
                  child: Container(
                    height: 36,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: _tab == tabs[i] ? colorScheme.primary.withValues(alpha: 0.22) : Colors.transparent,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      _tabLabel(tabs[i]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: _tab == tabs[i] ? FontWeight.w700 : FontWeight.w500,
                        color: _tab == tabs[i] ? colorScheme.primary : th.text,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return BaseVideoControlSheet(
      title: t.danmaku.title,
      icon: Symbols.tune_rounded,
      onBack: _tab == _DanmakuSheetTab.source && _selectedBangumi != null
          ? () => setState(() => _selectedBangumi = null)
          : null,
      child: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          return Column(
            children: [
              Padding(padding: const EdgeInsets.fromLTRB(16, 10, 16, 8), child: _buildTabBar(context)),
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

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        FocusableSwitchListTile(
          value: c.enabled,
          onChanged: (v) => unawaited(c.setEnabled(v)),
          title: Text(t.danmaku.enabled),
          contentPadding: EdgeInsets.zero,
        ),
        FocusableSwitchListTile(
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
              _FocusableChip(
                label: opt.$2,
                selected: (s.displayArea - opt.$1).abs() < 0.05,
                onPressed: () => unawaited(c.updateSettings(s.copyWith(displayArea: opt.$1))),
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
        FocusableSwitchListTile(
          value: s.mergeDuplicates,
          onChanged: (v) => unawaited(c.updateSettings(s.copyWith(mergeDuplicates: v))),
          title: Text(t.danmaku.mergeDuplicates),
          contentPadding: EdgeInsets.zero,
        ),
        FocusableSwitchListTile(
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
              style: TextStyle(color: tokens(context).textMuted, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _FocusableChip(label: '-5s', onPressed: () => c.setTimeOffset(s.timeOffsetSeconds - 5.0)),
            _FocusableChip(label: '-0.5s', onPressed: () => c.setTimeOffset(s.timeOffsetSeconds - 0.5)),
            _FocusableChip(label: t.danmaku.reset, onPressed: () => c.setTimeOffset(0.0)),
            _FocusableChip(label: '+0.5s', onPressed: () => c.setTimeOffset(s.timeOffsetSeconds + 0.5)),
            _FocusableChip(label: '+5s', onPressed: () => c.setTimeOffset(s.timeOffsetSeconds + 5.0)),
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
        FocusableSwitchListTile(
          value: s.blockScroll,
          onChanged: (v) => unawaited(c.updateSettings(s.copyWith(blockScroll: v))),
          title: Text(t.danmaku.blockScroll),
          contentPadding: EdgeInsets.zero,
        ),
        FocusableSwitchListTile(
          value: s.blockTop,
          onChanged: (v) => unawaited(c.updateSettings(s.copyWith(blockTop: v))),
          title: Text(t.danmaku.blockTop),
          contentPadding: EdgeInsets.zero,
        ),
        FocusableSwitchListTile(
          value: s.blockBottom,
          onChanged: (v) => unawaited(c.updateSettings(s.copyWith(blockBottom: v))),
          title: Text(t.danmaku.blockBottom),
          contentPadding: EdgeInsets.zero,
        ),
        FocusableSwitchListTile(
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
            _FocusableSheetButton(label: t.danmaku.addKeyword, filled: true, onPressed: () => unawaited(_addKeyword())),
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
                _FocusableChip(
                  label: kw,
                  trailingIcon: Symbols.close_rounded,
                  onPressed: () => unawaited(_removeKeyword(kw)),
                ),
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
                    _FocusableSheetButton(
                      label: t.danmaku.rematch,
                      icon: Symbols.refresh_rounded,
                      onPressed: c.isLoading ? null : () => unawaited(c.rematch(refresh: true)),
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
              _FocusableSheetButton(
                label: t.danmaku.searchButton,
                filled: true,
                onPressed: _searching ? null : () => unawaited(_performSearch()),
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
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: _FocusableSheetButton(
              label: '${t.danmaku.backToResults} · ${bangumi.animeTitle}',
              icon: Symbols.arrow_back_rounded,
              onPressed: () => setState(() => _selectedBangumi = null),
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
                    final overlay = OverlaySheetController.maybeOf(context);
                    if (overlay != null) {
                      overlay.close();
                    } else {
                      Navigator.of(context).maybePop();
                    }
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

class _FocusableChip extends StatelessWidget {
  final String label;
  final bool selected;
  final IconData? trailingIcon;
  final VoidCallback onPressed;

  const _FocusableChip({required this.label, required this.onPressed, this.selected = false, this.trailingIcon});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final th = tokens(context);
    final bgColor = selected
        ? colorScheme.primary.withValues(alpha: 0.22)
        : colorScheme.surfaceContainerHighest.withValues(alpha: 0.55);
    final fgColor = selected ? colorScheme.primary : th.text;

    return FocusableWrapper(
      autoScroll: false,
      descendantsAreFocusable: false,
      borderRadius: 10,
      semanticLabel: label,
      checked: selected ? true : null,
      onSelect: onPressed,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected
                  ? colorScheme.primary.withValues(alpha: 0.7)
                  : colorScheme.outlineVariant.withValues(alpha: 0.4),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: fgColor,
                ),
              ),
              if (trailingIcon != null) ...[
                const SizedBox(width: 6),
                AppIcon(trailingIcon, size: 15, color: th.textMuted),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _FocusableSheetButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool filled;
  final VoidCallback? onPressed;

  const _FocusableSheetButton({required this.label, required this.onPressed, this.icon, this.filled = false});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    final bgColor = filled
        ? (enabled ? colorScheme.primary : colorScheme.surfaceContainerHighest.withValues(alpha: 0.5))
        : colorScheme.surfaceContainerHighest.withValues(alpha: 0.35);
    final fgColor = filled
        ? (enabled ? colorScheme.onPrimary : colorScheme.onSurface.withValues(alpha: 0.38))
        : (enabled ? colorScheme.primary : colorScheme.onSurface.withValues(alpha: 0.38));

    return FocusableWrapper(
      autoScroll: false,
      descendantsAreFocusable: false,
      canRequestFocus: enabled,
      borderRadius: 10,
      semanticLabel: label,
      onSelect: onPressed,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(color: bgColor, borderRadius: BorderRadius.circular(10)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[AppIcon(icon, size: 16, color: fgColor), const SizedBox(width: 6)],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: fgColor),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SliderTile extends StatefulWidget {
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
  State<_SliderTile> createState() => _SliderTileState();
}

class _SliderTileState extends State<_SliderTile> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'danmaku_slider');
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_handleFocusChange);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChange);
    _focusNode.dispose();
    super.dispose();
  }

  void _handleFocusChange() {
    if (mounted && _focused != _focusNode.hasFocus) {
      setState(() => _focused = _focusNode.hasFocus);
    }
  }

  @override
  Widget build(BuildContext context) {
    final th = tokens(context);
    final showFocus = _focused && InputModeTracker.isKeyboardMode(context);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      margin: const EdgeInsets.symmetric(vertical: 2),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: showFocus ? th.text.withValues(alpha: 0.08) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: showFocus ? Theme.of(context).colorScheme.primary : Colors.transparent, width: 2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(widget.label, style: Theme.of(context).textTheme.bodyMedium)),
              Text(
                widget.valueLabel,
                style: TextStyle(color: th.textMuted, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(tickMarkShape: SliderTickMarkShape.noTickMark),
            child: FocusableSlider(
              focusNode: _focusNode,
              value: widget.value.clamp(widget.min, widget.max),
              min: widget.min,
              max: widget.max,
              divisions: widget.divisions,
              activeColor: Theme.of(context).colorScheme.primary,
              inactiveColor: Theme.of(context).colorScheme.outlineVariant,
              onChanged: widget.onChanged,
            ),
          ),
        ],
      ),
    );
  }
}
