import 'dart:async';

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../focus/focus_memory_tracker.dart';
import '../../focus/focusable_action_bar.dart';
import '../../focus/focusable_text_field.dart';
import '../../focus/focusable_wrapper.dart';
import '../../iptv/iptv_models.dart';
import '../../iptv/iptv_playback_session.dart';
import '../../iptv/iptv_provider.dart';
import '../../mixins/refreshable.dart';
import '../../navigation/main_screen_scope.dart';
import '../../utils/desktop_window_padding.dart';
import '../../utils/dialogs.dart';
import '../../utils/platform_detector.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/dialog_action_button.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/focusable_tab_chip.dart';
import '../libraries/state_messages.dart';
import 'iptv_sources_screen.dart';

/// Dedicated IPTV screen displaying grouped live channels, favorites, search, multi-line picker, and EPG info.
class IptvScreen extends StatefulWidget {
  const IptvScreen({super.key});

  @override
  State<IptvScreen> createState() => _IptvScreenState();
}

class _IptvScreenState extends State<IptvScreen> with FocusableTab, ManualRefreshable {
  static const String _allGroupKey = '__iptv_all__';
  static const String _favoritesGroupKey = '__iptv_favorites__';
  static final DateFormat _epgTimeFmt = DateFormat('HH:mm');

  final GlobalKey<FocusableActionBarState> _actionBarKey = GlobalKey();
  final FocusNode _firstContentFocusNode = FocusNode(debugLabel: 'iptv_first_content');
  final FocusNode _searchFocusNode = FocusNode(debugLabel: 'iptv_search');
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _gridScrollController = ScrollController();
  final FocusMemoryTracker _groupFocusTracker = FocusMemoryTracker(debugLabelPrefix: 'iptv_group');
  final List<FocusNode> _sourceTabFocusNodes = [];

  String? _lastObservedSourceId;
  String? _selectedGroup;
  bool _searchVisible = false;
  String _searchQuery = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncObservedActiveSource(context.read<IptvProvider>());
  }

  @override
  void dispose() {
    _firstContentFocusNode.dispose();
    _searchFocusNode.dispose();
    _searchController.dispose();
    _gridScrollController.dispose();
    _groupFocusTracker.dispose();
    for (final node in _sourceTabFocusNodes) {
      node.dispose();
    }
    _sourceTabFocusNodes.clear();
    super.dispose();
  }

  void _syncSourceTabFocusNodes(int count) {
    while (_sourceTabFocusNodes.length < count) {
      _sourceTabFocusNodes.add(FocusNode(debugLabel: 'iptv_source_${_sourceTabFocusNodes.length}'));
    }
    while (_sourceTabFocusNodes.length > count) {
      _sourceTabFocusNodes.removeLast().dispose();
    }
  }

  String _groupFocusKey(String? group) {
    if (group == null) return _allGroupKey;
    if (group == _favoritesGroupKey) return _favoritesGroupKey;
    return 'g:$group';
  }

  void _syncObservedActiveSource(IptvProvider provider) {
    final active = provider.activeSource;
    if (active == null) {
      _lastObservedSourceId = null;
      return;
    }
    if (_lastObservedSourceId == active.id) return;
    _lastObservedSourceId = active.id;
    _selectedGroup = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_gridScrollController.hasClients) {
        _gridScrollController.jumpTo(0);
      }
      unawaited(provider.ensureLoaded(active));
    });
  }

  void _selectSource(IptvSource source) {
    final provider = context.read<IptvProvider>();
    if (provider.activeSource?.id == source.id) return;
    _lastObservedSourceId = source.id;
    setState(() => _selectedGroup = null);
    if (_gridScrollController.hasClients) {
      _gridScrollController.jumpTo(0);
    }
    provider.selectSource(source.id);
    unawaited(provider.ensureLoaded(source));
  }

  void _focusSidebar() => MainScreenFocusScope.focusSidebarOf(context);

  void _focusSelectedGroup() {
    final target =
        _groupFocusTracker.nodeFor(_groupFocusKey(_selectedGroup)) ?? _groupFocusTracker.nodeFor(_allGroupKey);
    if (target != null && target.canRequestFocus) {
      target.requestFocus();
    } else {
      _focusSidebar();
    }
  }

  void _focusChannelGrid() {
    if (_firstContentFocusNode.canRequestFocus) {
      _firstContentFocusNode.requestFocus();
      return;
    }
    if (_searchVisible && _searchFocusNode.canRequestFocus) {
      _searchFocusNode.requestFocus();
    }
  }

  void _focusAppBar({bool hasSourceChips = false}) {
    if (hasSourceChips && _sourceTabFocusNodes.isNotEmpty && _sourceTabFocusNodes.first.canRequestFocus) {
      _sourceTabFocusNodes.first.requestFocus();
      return;
    }
    _actionBarKey.currentState?.requestFocusOnFirst();
  }

  void _selectGroup(String? group, {bool focusGridIfAlreadySelected = false}) {
    if (_selectedGroup == group) {
      if (focusGridIfAlreadySelected) {
        _focusChannelGrid();
      }
      return;
    }
    setState(() => _selectedGroup = group);
    if (_gridScrollController.hasClients) {
      _gridScrollController.jumpTo(0);
    }
  }

  void _selectGroupAndFocusGrid(String? group) {
    if (_selectedGroup != group) {
      setState(() => _selectedGroup = group);
      if (_gridScrollController.hasClients) {
        _gridScrollController.jumpTo(0);
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusChannelGrid();
    });
  }

  @override
  void focusActiveTabIfReady() {
    if (!mounted) return;
    final activeGroupNode =
        _groupFocusTracker.nodeFor(_groupFocusKey(_selectedGroup)) ?? _groupFocusTracker.nodeFor(_allGroupKey);
    if (activeGroupNode != null && activeGroupNode.canRequestFocus) {
      activeGroupNode.requestFocus();
      return;
    }
    if (_firstContentFocusNode.canRequestFocus) {
      _firstContentFocusNode.requestFocus();
    }
  }

  @override
  void manualRefresh() {
    final provider = context.read<IptvProvider>();
    final active = provider.activeSource;
    if (active == null) return;
    unawaited(provider.ensureLoaded(active, forceRefresh: true));
  }

  void _toggleSearch({bool restoreGroupFocus = false}) {
    final opening = !_searchVisible;
    setState(() {
      _searchVisible = opening;
      if (!opening) {
        _searchQuery = '';
        _searchController.clear();
      }
    });
    if (opening) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _searchFocusNode.requestFocus();
      });
    } else if (restoreGroupFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusSelectedGroup();
      });
    }
  }

  void _openManageSources() {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const IptvSourcesScreen()));
  }

  void _playChannel(IptvChannel channel, List<IptvChannel> queue, {int variantIndex = 0}) {
    unawaited(navigateToIptvChannel(context, channel: channel, channels: queue, variantIndex: variantIndex));
  }

  Future<void> _showChannelActions(IptvChannel channel, List<IptvChannel> queue) async {
    final provider = context.read<IptvProvider>();
    final isFav = provider.isFavorite(channel);
    await showScopedDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(channel.name),
          content: SizedBox(
            width: 340,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FocusableListTile(
                  autofocus: true,
                  leading: const AppIcon(Symbols.play_arrow_rounded),
                  title: const Text('立即播放'),
                  onTap: () {
                    Navigator.of(dialogContext).pop();
                    _playChannel(channel, queue);
                  },
                ),
                if (channel.variants.length > 1)
                  FocusableListTile(
                    leading: const AppIcon(Symbols.alt_route_rounded),
                    title: Text('选择线路（${channel.variants.length} 条）'),
                    onTap: () {
                      Navigator.of(dialogContext).pop();
                      unawaited(_pickAndPlayVariant(channel, queue));
                    },
                  ),
                FocusableListTile(
                  leading: AppIcon(
                    isFav ? Symbols.star_rounded : Symbols.star_outline_rounded,
                    fill: isFav ? 1.0 : 0.0,
                    color: isFav ? Colors.amber : null,
                  ),
                  title: Text(isFav ? '取消收藏' : '收藏频道'),
                  onTap: () {
                    Navigator.of(dialogContext).pop();
                    unawaited(provider.toggleFavorite(channel));
                  },
                ),
              ],
            ),
          ),
          actions: [
            DialogActionButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              label: '取消',
            ),
          ],
        );
      },
    );
  }

  Future<void> _pickAndPlayVariant(IptvChannel channel, List<IptvChannel> queue) async {
    final chosen = await showScopedDialog<int>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text('${channel.name} · 选择线路'),
          content: SizedBox(
            width: 380,
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: channel.variants.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (_, idx) {
                final variant = channel.variants[idx];
                final uri = Uri.tryParse(variant.url);
                final subtitle = uri != null && uri.host.isNotEmpty
                    ? '${uri.scheme.toUpperCase()} · ${uri.host}'
                    : variant.url;
                return FocusableListTile(
                  autofocus: idx == 0,
                  leading: CircleAvatar(radius: 14, child: Text('${idx + 1}')),
                  title: Text(variant.label?.isNotEmpty == true ? variant.label! : '线路 ${idx + 1}'),
                  subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: const AppIcon(Symbols.play_arrow_rounded),
                  onTap: () => Navigator.of(dialogContext).pop(idx),
                );
              },
            ),
          ),
          actions: [
            DialogActionButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              label: '取消',
            ),
          ],
        );
      },
    );
    if (chosen == null || !mounted) return;
    _playChannel(channel, queue, variantIndex: chosen);
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<IptvProvider>();
    _syncObservedActiveSource(provider);
    final sources = provider.sources;
    final useSideNav = PlatformDetector.shouldUseSideNavigation(context);
    final hasSourceChips = !useSideNav && sources.length > 1;
    _syncSourceTabFocusNodes(hasSourceChips ? sources.length : 0);
    final activeSource = provider.activeSource;

    return Scaffold(
      appBar: AppBar(
        title: _buildAppBarTitle(sources, activeSource, hasSourceChips: hasSourceChips),
        actions: DesktopAppBarHelper.buildAdjustedActions([
          FocusableActionBar(
            key: _actionBarKey,
            onBack: _focusSidebar,
            onNavigateLeft: hasSourceChips && _sourceTabFocusNodes.isNotEmpty
                ? () => _sourceTabFocusNodes.last.requestFocus()
                : _focusSidebar,
            onNavigateDown: focusActiveTabIfReady,
            actions: [
              if (activeSource != null)
                FocusableAction(
                  icon: _searchVisible ? Symbols.search_off_rounded : Symbols.search_rounded,
                  tooltip: _searchVisible ? '收起搜索' : '搜索频道',
                  onPressed: () => _toggleSearch(),
                ),
              if (activeSource != null)
                FocusableAction(
                  icon: Symbols.refresh_rounded,
                  tooltip: '刷新频道列表',
                  onPressed: manualRefresh,
                ),
              FocusableAction(
                icon: Symbols.tune_rounded,
                tooltip: '管理 IPTV 源',
                onPressed: _openManageSources,
              ),
            ],
          ),
        ]),
      ),
      body: SafeArea(
        top: false,
        bottom: false,
        child: activeSource == null
            ? EmptyStateWidget(
                icon: Symbols.live_tv_rounded,
                message: '暂无 IPTV 直播源',
                subtitle: '添加 M3U / M3U8 / TXT 订阅后即可在此浏览分组与观看直播',
                actionLabel: '管理 IPTV 源',
                actionIcon: Symbols.add_rounded,
                actionFocusNode: _firstContentFocusNode,
                onActionNavigateLeft: _focusSidebar,
                onActionNavigateUp: () => _focusAppBar(hasSourceChips: hasSourceChips),
                onActionBack: _focusSidebar,
                onAction: _openManageSources,
              )
            : _buildSourceBody(provider, activeSource, hasSourceChips: hasSourceChips),
      ),
    );
  }

  Widget _buildAppBarTitle(List<IptvSource> sources, IptvSource? active, {required bool hasSourceChips}) {
    if (sources.isEmpty || active == null) return const Text('IPTV');
    if (!hasSourceChips) return Text(active.name);
    return TabChipStrip(
      children: [
        for (int i = 0; i < sources.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          FocusableTabChip(
            focusNode: _sourceTabFocusNodes[i],
            label: sources[i].name,
            isSelected: sources[i].id == active.id,
            onSelect: () => _selectSource(sources[i]),
            onBack: _focusSidebar,
            onNavigateDown: focusActiveTabIfReady,
            onNavigateLeft: i == 0 ? _focusSidebar : () => _sourceTabFocusNodes[i - 1].requestFocus(),
            onNavigateRight: i == sources.length - 1
                ? () => _actionBarKey.currentState?.requestFocusOnFirst()
                : () => _sourceTabFocusNodes[i + 1].requestFocus(),
          ),
        ],
      ],
    );
  }

  Widget _buildSourceBody(IptvProvider provider, IptvSource activeSource, {required bool hasSourceChips}) {
    final channels = provider.channelsFor(activeSource.id);
    final isLoading = provider.isLoading(activeSource.id);
    final error = provider.errorFor(activeSource.id);

    if (isLoading && channels.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [CircularProgressIndicator(), SizedBox(height: 12), Text('正在加载频道订阅...')],
        ),
      );
    }

    if (error != null && channels.isEmpty) {
      return ErrorStateWidget(
        message: error,
        icon: Symbols.error_outline_rounded,
        onRetry: manualRefresh,
        actionFocusNode: _firstContentFocusNode,
        onActionNavigateLeft: _focusSidebar,
        onActionNavigateUp: () => _focusAppBar(hasSourceChips: hasSourceChips),
        onActionBack: _focusSidebar,
      );
    }

    if (channels.isEmpty) {
      return EmptyStateWidget(
        icon: Symbols.live_tv_rounded,
        message: '订阅内暂无频道',
        actionLabel: '重新加载',
        actionIcon: Symbols.refresh_rounded,
        actionFocusNode: _firstContentFocusNode,
        onActionNavigateLeft: _focusSidebar,
        onActionNavigateUp: () => _focusAppBar(hasSourceChips: hasSourceChips),
        onActionBack: _focusSidebar,
        onAction: manualRefresh,
      );
    }

    final groupCounts = <String, int>{};
    var favoriteCount = 0;
    for (final ch in channels) {
      groupCounts[ch.group] = (groupCounts[ch.group] ?? 0) + 1;
      if (provider.isFavorite(ch)) favoriteCount++;
    }

    var effectiveGroup = _selectedGroup;
    if (effectiveGroup == _favoritesGroupKey && favoriteCount == 0) {
      effectiveGroup = null;
    } else if (effectiveGroup != null &&
        effectiveGroup != _favoritesGroupKey &&
        !groupCounts.containsKey(effectiveGroup)) {
      effectiveGroup = null;
    }

    final categoryEntries = <({String? value, String key, String label, int count, IconData? icon, Color? iconColor})>[
      (value: null, key: _allGroupKey, label: '全部', count: channels.length, icon: Symbols.grid_view_rounded, iconColor: null),
      if (favoriteCount > 0)
        (
          value: _favoritesGroupKey,
          key: _favoritesGroupKey,
          label: '收藏',
          count: favoriteCount,
          icon: Symbols.star_rounded,
          iconColor: Colors.amber,
        ),
      for (final entry in groupCounts.entries)
        (value: entry.key, key: _groupFocusKey(entry.key), label: entry.key, count: entry.value, icon: null, iconColor: null),
    ];
    _groupFocusTracker.pruneExcept({for (final entry in categoryEntries) entry.key});

    final normalizedQuery = _searchQuery.trim().toLowerCase();
    final filtered = [
      for (final ch in channels)
        if ((effectiveGroup == null ||
                (effectiveGroup == _favoritesGroupKey && provider.isFavorite(ch)) ||
                ch.group == effectiveGroup) &&
            (normalizedQuery.isEmpty ||
                ch.name.toLowerCase().contains(normalizedQuery) ||
                ch.group.toLowerCase().contains(normalizedQuery)))
          ch,
    ];

    final epg = provider.epgFor(activeSource.id);
    final scheme = Theme.of(context).colorScheme;

    return Column(
      children: [
        if (isLoading) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final categoryWidth = constraints.maxWidth >= 720 ? 196.0 : 136.0;
              final rightWidth = (constraints.maxWidth - categoryWidth - 1).clamp(1.0, double.infinity);
              final gridUsableWidth = (rightWidth - 32).clamp(1.0, double.infinity);
              final crossAxisCount = ((gridUsableWidth + 12) / (260 + 12)).floor().clamp(1, 4);

              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: categoryWidth,
                    child: FocusTraversalGroup(
                      child: ListView.separated(
                        padding: const EdgeInsets.fromLTRB(12, 8, 8, 24),
                        itemCount: categoryEntries.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 4),
                        itemBuilder: (_, index) {
                          final item = categoryEntries[index];
                          return _GroupNavTile(
                            focusNode: _groupFocusTracker.get(item.key),
                            label: item.label,
                            count: item.count,
                            icon: item.icon,
                            iconColor: item.iconColor,
                            selected: effectiveGroup == item.value,
                            onTap: () => _selectGroup(item.value),
                            onSelect: () => _selectGroup(item.value, focusGridIfAlreadySelected: true),
                            onNavigateUp: index == 0 ? () => _focusAppBar(hasSourceChips: hasSourceChips) : null,
                            onNavigateLeft: _focusSidebar,
                            onNavigateRight: () => _selectGroupAndFocusGrid(item.value),
                            onBack: _focusSidebar,
                          );
                        },
                      ),
                    ),
                  ),
                  VerticalDivider(
                    width: 1,
                    thickness: 1,
                    color: scheme.outlineVariant.withValues(alpha: 0.45),
                  ),
                  Expanded(
                    child: FocusTraversalGroup(
                      child: Column(
                        children: [
                          if (_searchVisible)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                              child: FocusableTextField(
                                controller: _searchController,
                                focusNode: _searchFocusNode,
                                decoration: InputDecoration(
                                  hintText: '搜索频道名称或分组...',
                                  prefixIcon: const AppIcon(Symbols.search_rounded),
                                  suffixIcon: _searchQuery.isEmpty
                                      ? null
                                      : ExcludeFocus(
                                          child: IconButton(
                                            icon: const AppIcon(Symbols.close_rounded),
                                            onPressed: () {
                                              _searchController.clear();
                                              setState(() => _searchQuery = '');
                                            },
                                          ),
                                        ),
                                  border: const OutlineInputBorder(),
                                  isDense: true,
                                ),
                                onChanged: (v) => setState(() => _searchQuery = v),
                                onNavigateUp: () => _focusAppBar(hasSourceChips: hasSourceChips),
                                onNavigateDown: _focusChannelGrid,
                                onNavigateLeft: _focusSelectedGroup,
                                onBack: () => _toggleSearch(restoreGroupFocus: true),
                              ),
                            ),
                          Expanded(
                            child: filtered.isEmpty
                                ? EmptyStateWidget(
                                    icon: Symbols.filter_alt_off_rounded,
                                    message: '未找到匹配的频道',
                                    actionLabel: '清除筛选',
                                    actionIcon: Symbols.clear_all_rounded,
                                    actionFocusNode: _firstContentFocusNode,
                                    onActionNavigateLeft: _focusSelectedGroup,
                                    onActionNavigateUp: _searchVisible
                                        ? () => _searchFocusNode.requestFocus()
                                        : () => _focusAppBar(hasSourceChips: hasSourceChips),
                                    onActionBack: _focusSelectedGroup,
                                    onAction: () {
                                      _searchController.clear();
                                      setState(() {
                                        _selectedGroup = null;
                                        _searchQuery = '';
                                      });
                                      if (_gridScrollController.hasClients) {
                                        _gridScrollController.jumpTo(0);
                                      }
                                    },
                                  )
                                : CustomScrollView(
                                    controller: _gridScrollController,
                                    slivers: [
                                      SliverPadding(
                                        padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
                                        sliver: SliverGrid(
                                          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                                            crossAxisCount: crossAxisCount,
                                            mainAxisSpacing: 12,
                                            crossAxisSpacing: 12,
                                            mainAxisExtent: 124,
                                          ),
                                          delegate: SliverChildBuilderDelegate(
                                            (context, idx) {
                                              final channel = filtered[idx];
                                              final prog = epg.currentAndNextFor(channel);
                                              return _IptvChannelCard(
                                                channel: channel,
                                                focusNode: idx == 0 ? _firstContentFocusNode : null,
                                                isFavorite: provider.isFavorite(channel),
                                                currentProgram: prog.current,
                                                nextProgram: prog.next,
                                                timeFormat: _epgTimeFmt,
                                                onTap: () => _playChannel(channel, filtered),
                                                onLongPress: () => unawaited(_showChannelActions(channel, filtered)),
                                                onToggleFavorite: () => unawaited(provider.toggleFavorite(channel)),
                                                onPickVariant: channel.variants.length > 1
                                                    ? () => unawaited(_pickAndPlayVariant(channel, filtered))
                                                    : null,
                                                onNavigateLeft: idx % crossAxisCount == 0 ? _focusSelectedGroup : null,
                                                onNavigateUp: idx < crossAxisCount
                                                    ? (_searchVisible
                                                          ? () => _searchFocusNode.requestFocus()
                                                          : () => _focusAppBar(hasSourceChips: hasSourceChips))
                                                    : null,
                                                onBack: _focusSelectedGroup,
                                              );
                                            },
                                            childCount: filtered.length,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _GroupNavTile extends StatelessWidget {
  final FocusNode focusNode;
  final String label;
  final int count;
  final IconData? icon;
  final Color? iconColor;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onSelect;
  final VoidCallback? onNavigateUp;
  final VoidCallback? onNavigateLeft;
  final VoidCallback? onNavigateRight;
  final VoidCallback? onBack;

  const _GroupNavTile({
    required this.focusNode,
    required this.label,
    required this.count,
    this.icon,
    this.iconColor,
    required this.selected,
    required this.onTap,
    required this.onSelect,
    this.onNavigateUp,
    this.onNavigateLeft,
    this.onNavigateRight,
    this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fg = selected ? scheme.onSecondaryContainer : scheme.onSurface;
    final countFg = selected ? scheme.onSecondaryContainer.withValues(alpha: 0.78) : scheme.onSurfaceVariant;

    return FocusableWrapper(
      focusNode: focusNode,
      borderRadius: 10,
      useBackgroundFocus: true,
      disableScale: true,
      descendantsAreFocusable: false,
      semanticLabel: '$label ($count)',
      checked: selected,
      onSelect: onSelect,
      onNavigateUp: onNavigateUp,
      onNavigateLeft: onNavigateLeft,
      onNavigateRight: onNavigateRight,
      onBack: onBack,
      child: Material(
        color: selected ? scheme.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          canRequestFocus: false,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                if (icon != null) ...[
                  AppIcon(icon!, size: 17, fill: 1.0, color: iconColor ?? fg),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: fg,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '$count',
                  style: theme.textTheme.labelSmall?.copyWith(color: countFg),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _IptvChannelCard extends StatelessWidget {
  final IptvChannel channel;
  final FocusNode? focusNode;
  final bool isFavorite;
  final IptvEpgProgram? currentProgram;
  final IptvEpgProgram? nextProgram;
  final DateFormat timeFormat;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onToggleFavorite;
  final VoidCallback? onPickVariant;
  final VoidCallback? onNavigateUp;
  final VoidCallback? onNavigateLeft;
  final VoidCallback? onBack;

  const _IptvChannelCard({
    required this.channel,
    this.focusNode,
    required this.isFavorite,
    required this.currentProgram,
    required this.nextProgram,
    required this.timeFormat,
    required this.onTap,
    required this.onLongPress,
    required this.onToggleFavorite,
    this.onPickVariant,
    this.onNavigateUp,
    this.onNavigateLeft,
    this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    String programLabel;
    bool hasLiveEpg = false;
    if (currentProgram != null) {
      hasLiveEpg = true;
      programLabel = '${timeFormat.format(currentProgram!.start.toLocal())} ${currentProgram!.title}';
    } else if (nextProgram != null) {
      programLabel = '稍后 ${timeFormat.format(nextProgram!.start.toLocal())} ${nextProgram!.title}';
    } else {
      final firstUri = Uri.tryParse(channel.variants.firstOrNull?.url ?? '');
      programLabel = (firstUri != null && firstUri.host.isNotEmpty) ? firstUri.host : '点击播放';
    }

    return FocusableWrapper(
      focusNode: focusNode,
      borderRadius: 12,
      enableLongPress: true,
      descendantsAreFocusable: false,
      semanticLabel: channel.name,
      onSelect: onTap,
      onLongPress: onLongPress,
      onNavigateUp: onNavigateUp,
      onNavigateLeft: onNavigateLeft,
      onBack: onBack,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          canRequestFocus: false,
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _ChannelLogo(logoUrl: channel.logo),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            channel.name,
                            style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600, height: 1.25),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            channel.group,
                            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    ExcludeFocus(
                      child: IconButton(
                        visualDensity: VisualDensity.compact,
                        style: IconButton.styleFrom(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                        tooltip: isFavorite ? '取消收藏' : '收藏频道',
                        icon: AppIcon(
                          isFavorite ? Symbols.star_rounded : Symbols.star_outline_rounded,
                          size: 18,
                          fill: isFavorite ? 1.0 : 0.0,
                          color: isFavorite ? Colors.amber : scheme.onSurfaceVariant,
                        ),
                        onPressed: onToggleFavorite,
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                Row(
                  children: [
                    if (hasLiveEpg) ...[
                      Container(
                        width: 6,
                        height: 6,
                        margin: const EdgeInsets.only(right: 6),
                        decoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
                      ),
                    ],
                    Expanded(
                      child: Text(
                        programLabel,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: hasLiveEpg ? scheme.onSurface : scheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (onPickVariant != null) ...[
                      const SizedBox(width: 8),
                      ExcludeFocus(
                        child: InkWell(
                          canRequestFocus: false,
                          borderRadius: BorderRadius.circular(999),
                          onTap: onPickVariant,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: scheme.secondaryContainer,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              '${channel.variants.length} 线路',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: scheme.onSecondaryContainer,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ChannelLogo extends StatelessWidget {
  final String? logoUrl;

  const _ChannelLogo({this.logoUrl});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final url = logoUrl?.trim();
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: DecoratedBox(
        decoration: BoxDecoration(color: scheme.surfaceContainerHighest),
        child: SizedBox.square(
          dimension: 40,
          child: (url != null && (url.startsWith('http://') || url.startsWith('https://')))
              ? CachedNetworkImage(
                  imageUrl: url,
                  fit: BoxFit.contain,
                  placeholder: (_, _) => Center(
                    child: AppIcon(Symbols.tv_rounded, size: 20, color: scheme.onSurfaceVariant),
                  ),
                  errorBuilder: (_, _, _) => Center(
                    child: AppIcon(Symbols.tv_rounded, size: 20, color: scheme.onSurfaceVariant),
                  ),
                )
              : Center(child: AppIcon(Symbols.tv_rounded, size: 20, color: scheme.onSurfaceVariant)),
        ),
      ),
    );
  }
}
