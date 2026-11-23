import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../iptv/iptv_models.dart';
import '../../iptv/iptv_provider.dart';
import '../../utils/dialogs.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/desktop_app_bar.dart';
import '../sources/cloud_sources_screen.dart';
import '../ttplay_admin/ttplay_admin_guard.dart';

/// Manages local IPTV M3U/TXT playlists and surfaces synced cloud IPTV sources.
class IptvSourcesScreen extends StatelessWidget {
  const IptvSourcesScreen({super.key});

  Future<void> _openLocalEditor(BuildContext context, {IptvSource? existing}) async {
    final saved = await showScopedDialog<IptvSource>(
      context: context,
      builder: (_) => _IptvSourceEditDialog(existing: existing),
    );
    if (saved == null || !context.mounted) return;

    final provider = context.read<IptvProvider>();
    if (existing == null) {
      await provider.addLocalSource(saved);
    } else {
      await provider.updateLocalSource(saved);
    }
    unawaited(provider.ensureLoaded(saved, forceRefresh: true));
    if (!context.mounted) return;
    final count = provider.channelsFor(saved.id).length;
    showSuccessSnackBar(
      context,
      existing == null
          ? (count > 0 ? '已添加「${saved.name}」（$count 个频道）' : '已添加「${saved.name}」')
          : '已更新「${saved.name}」',
    );
  }

  Future<void> _confirmDelete(BuildContext context, IptvSource source) async {
    final ok = await showConfirmDialog(
      context,
      title: '删除 IPTV 直播源',
      message: '确定要从本设备移除「${source.name}」吗？',
      confirmText: '删除',
      isDestructive: true,
    );
    if (!ok || !context.mounted) return;
    await context.read<IptvProvider>().removeLocalSource(source.id);
    if (!context.mounted) return;
    showSuccessSnackBar(context, '已删除「${source.name}」');
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<IptvProvider>();
    final appSession = maybeWatchAppSession(context);
    final ttplayBinder = maybeWatchTtplayBinder(context);
    final showCloudShortcut = canUseTtplayAdmin(session: appSession, binder: ttplayBinder);
    final cloudSources = provider.cloudSources;
    final localSources = provider.localSources;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      body: SafeArea(
        top: false,
        bottom: false,
        child: CustomScrollView(
          slivers: [
            CustomAppBar(
              title: const Text('IPTV 直播源'),
              pinned: true,
              actions: [
                IconButton(
                  tooltip: '添加本地 IPTV 源',
                  icon: const AppIcon(Symbols.add_rounded),
                  onPressed: () => _openLocalEditor(context),
                ),
              ],
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              sliver: SliverToBoxAdapter(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 720),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (showCloudShortcut) ...[
                          Card(
                            color: scheme.secondaryContainer.withValues(alpha: 0.45),
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: Row(
                                children: [
                                  AppIcon(Symbols.cloud_sync_rounded, color: scheme.primary),
                                  const SizedBox(width: 12),
                                  const Expanded(
                                    child: Text(
                                      '已登录自建后端：可在「云端媒体源」添加加密同步的 IPTV 订阅，也可在此添加仅保存在本机的本地直播源。',
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  OutlinedButton(
                                    onPressed: () {
                                      Navigator.of(context).push(
                                        MaterialPageRoute<void>(builder: (_) => const CloudSourcesScreen()),
                                      );
                                    },
                                    child: const Text('云端媒体源'),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],
                        if (cloudSources.isNotEmpty) ...[
                          Row(
                            children: [
                              Text('云端同步直播源', style: theme.textTheme.titleMedium),
                              const Spacer(),
                              if (showCloudShortcut)
                                TextButton.icon(
                                  onPressed: () {
                                    Navigator.of(context).push(
                                      MaterialPageRoute<void>(builder: (_) => const CloudSourcesScreen()),
                                    );
                                  },
                                  icon: const AppIcon(Symbols.open_in_new_rounded, size: 16),
                                  label: const Text('前往管理'),
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          for (final src in cloudSources) ...[
                            _SourceCard(
                              source: src,
                              channelCount: provider.channelsFor(src.id).length,
                              isLoading: provider.isLoading(src.id),
                              error: provider.errorFor(src.id),
                              onRefresh: () => provider.ensureLoaded(src, forceRefresh: true),
                            ),
                            const SizedBox(height: 10),
                          ],
                          const SizedBox(height: 12),
                        ],
                        Row(
                          children: [
                            Text('本地直播源', style: theme.textTheme.titleMedium),
                            const Spacer(),
                            FilledButton.tonalIcon(
                              onPressed: () => _openLocalEditor(context),
                              icon: const AppIcon(Symbols.add_rounded, size: 18),
                              label: const Text('添加本地源'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        if (localSources.isEmpty)
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
                              child: Column(
                                children: [
                                  AppIcon(Symbols.live_tv_rounded, size: 48, color: scheme.onSurfaceVariant),
                                  const SizedBox(height: 12),
                                  Text('尚未添加本地 IPTV 订阅', style: theme.textTheme.titleSmall),
                                  const SizedBox(height: 6),
                                  Text(
                                    '支持 M3U / M3U8 / TXT (#genre#) 直播源、多线路自动聚合、自定义 User-Agent / Referer 以及 XMLTV EPG 节目单，例如 akiralereal/iptv 导出的订阅链接。',
                                    textAlign: TextAlign.center,
                                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                                  ),
                                  const SizedBox(height: 16),
                                  FilledButton.icon(
                                    onPressed: () => _openLocalEditor(context),
                                    icon: const AppIcon(Symbols.add_rounded, size: 18),
                                    label: const Text('添加第一个 IPTV 源'),
                                  ),
                                ],
                              ),
                            ),
                          )
                        else
                          for (final src in localSources) ...[
                            _SourceCard(
                              source: src,
                              channelCount: provider.channelsFor(src.id).length,
                              isLoading: provider.isLoading(src.id),
                              error: provider.errorFor(src.id),
                              onRefresh: () => provider.ensureLoaded(src, forceRefresh: true),
                              onEdit: () => _openLocalEditor(context, existing: src),
                              onDelete: () => _confirmDelete(context, src),
                            ),
                            const SizedBox(height: 10),
                          ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SourceCard extends StatelessWidget {
  final IptvSource source;
  final int channelCount;
  final bool isLoading;
  final String? error;
  final VoidCallback onRefresh;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  const _SourceCard({
    required this.source,
    required this.channelCount,
    required this.isLoading,
    required this.error,
    required this.onRefresh,
    this.onEdit,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: source.isCloud ? scheme.primaryContainer : scheme.secondaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: SizedBox.square(
                dimension: 42,
                child: Center(
                  child: AppIcon(
                    source.isCloud ? Symbols.cloud_done_rounded : Symbols.live_tv_rounded,
                    size: 22,
                    color: source.isCloud ? scheme.onPrimaryContainer : scheme.onSecondaryContainer,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          source.name,
                          style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          source.isCloud ? '云端同步' : '本地保存',
                          style: theme.textTheme.labelSmall,
                        ),
                      ),
                      if (channelCount > 0) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: scheme.primaryContainer.withValues(alpha: 0.65),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text('$channelCount 频道', style: theme.textTheme.labelSmall),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    source.m3uUrl,
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (source.epgUrl != null && source.epgUrl!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      'EPG: ${source.epgUrl}',
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  if (error != null && error!.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      error!,
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isLoading)
                  const Padding(
                    padding: EdgeInsets.all(10),
                    child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                else
                  IconButton(
                    tooltip: '刷新频道列表',
                    icon: const AppIcon(Symbols.refresh_rounded, size: 20),
                    onPressed: onRefresh,
                  ),
                if (onEdit != null)
                  IconButton(
                    tooltip: '编辑',
                    icon: const AppIcon(Symbols.edit_rounded, size: 20),
                    onPressed: onEdit,
                  ),
                if (onDelete != null)
                  IconButton(
                    tooltip: '删除',
                    icon: const AppIcon(Symbols.delete_rounded, size: 20),
                    onPressed: onDelete,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _IptvSourceEditDialog extends StatefulWidget {
  final IptvSource? existing;

  const _IptvSourceEditDialog({this.existing});

  @override
  State<_IptvSourceEditDialog> createState() => _IptvSourceEditDialogState();
}

class _IptvSourceEditDialogState extends State<_IptvSourceEditDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  late final TextEditingController _m3uCtrl;
  late final TextEditingController _epgCtrl;
  late final TextEditingController _uaCtrl;
  late final TextEditingController _refererCtrl;

  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _nameCtrl = TextEditingController(text: e?.name ?? '');
    _m3uCtrl = TextEditingController(text: e?.m3uUrl ?? '');
    _epgCtrl = TextEditingController(text: e?.epgUrl ?? '');
    _uaCtrl = TextEditingController(text: e?.userAgent ?? '');
    _refererCtrl = TextEditingController(text: e?.referer ?? '');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _m3uCtrl.dispose();
    _epgCtrl.dispose();
    _uaCtrl.dispose();
    _refererCtrl.dispose();
    super.dispose();
  }

  String _deriveName(String m3uUrl) {
    final explicit = _nameCtrl.text.trim();
    if (explicit.isNotEmpty) return explicit;
    final uri = Uri.tryParse(m3uUrl.trim());
    if (uri != null && uri.host.isNotEmpty) return uri.host;
    return 'IPTV 直播源';
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _saving = true;
      _error = null;
    });

    final m3uUrl = _m3uCtrl.text.trim();
    final epgUrl = _epgCtrl.text.trim();
    final ua = _uaCtrl.text.trim();
    final referer = _refererCtrl.text.trim();
    final id = widget.existing?.id ?? 'local:${DateTime.now().microsecondsSinceEpoch}';

    try {
      final parsed = await IptvProvider.fetchAndParsePlaylist(
        m3uUrl,
        sourceId: id,
        userAgent: ua.isEmpty ? null : ua,
        referer: referer.isEmpty ? null : referer,
      );
      final resolvedEpg = epgUrl.isNotEmpty ? epgUrl : parsed.headerEpgUrl;
      final source = IptvSource(
        id: id,
        name: _deriveName(m3uUrl),
        m3uUrl: m3uUrl,
        epgUrl: resolvedEpg,
        userAgent: ua.isEmpty ? null : ua,
        referer: referer.isEmpty ? null : referer,
        isCloud: false,
      );
      if (!mounted) return;
      Navigator.of(context).pop(source);
    } on FormatException catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isEditing = widget.existing != null;
    return AlertDialog(
      title: Text(isEditing ? '编辑本地 IPTV 源' : '添加本地 IPTV 源'),
      content: SizedBox(
        width: 460,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_error != null) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: scheme.errorContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(_error!, style: TextStyle(color: scheme.onErrorContainer, fontSize: 13)),
                  ),
                ],
                TextFormField(
                  controller: _nameCtrl,
                  enabled: !_saving,
                  decoration: const InputDecoration(
                    labelText: '显示名称（可选）',
                    hintText: '留空将使用订阅域名自动命名',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _m3uCtrl,
                  enabled: !_saving,
                  decoration: const InputDecoration(
                    labelText: 'M3U / TXT 订阅地址 *',
                    hintText: '例如：http://192.168.1.10:3000/all.m3u',
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) {
                    final raw = (v ?? '').trim();
                    final uri = Uri.tryParse(raw);
                    if (uri == null || !uri.hasScheme || uri.host.isEmpty || (uri.scheme != 'http' && uri.scheme != 'https')) {
                      return '请输入有效的 http:// 或 https:// 地址';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _epgCtrl,
                  enabled: !_saving,
                  decoration: const InputDecoration(
                    labelText: 'EPG 节目单地址（可选）',
                    hintText: '留空自动使用 M3U 头部的 x-tvg-url',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _uaCtrl,
                  enabled: !_saving,
                  decoration: const InputDecoration(
                    labelText: '默认 User-Agent（可选）',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _refererCtrl,
                  enabled: !_saving,
                  decoration: const InputDecoration(
                    labelText: '默认 Referer（可选）',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _saving ? null : _submit,
          icon: _saving
              ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const AppIcon(Symbols.check_rounded, size: 18),
          label: Text(_saving ? '校验中...' : '校验并保存'),
        ),
      ],
    );
  }
}
