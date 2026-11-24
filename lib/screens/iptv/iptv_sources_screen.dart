import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../iptv/iptv_models.dart';
import '../../iptv/iptv_provider.dart';
import '../../library_cloud/cloud_api_client.dart';
import '../../utils/dialogs.dart';
import '../../utils/platform_detector.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/desktop_app_bar.dart';
import '../ttplay_admin/ttplay_admin_guard.dart';

/// Mode-isolated IPTV subscription management screen.
///
/// Offline mode manages local device sources; Self-Hosted Sync mode displays
/// and (on PC/Mobile) edits encrypted cloud IPTV sources synced via the server.
class IptvSourcesScreen extends StatefulWidget {
  const IptvSourcesScreen({super.key});

  @override
  State<IptvSourcesScreen> createState() => _IptvSourcesScreenState();
}

class _IptvSourcesScreenState extends State<IptvSourcesScreen> {
  bool _syncing = false;

  static String _resolveCloudSourceId(IptvSource source) {
    final explicit = source.cloudSourceId?.trim() ?? '';
    if (explicit.isNotEmpty) return explicit;
    if (source.id.startsWith('cloud:')) {
      return source.id.substring('cloud:'.length);
    }
    return source.id;
  }

  static Map<String, dynamic> _buildCloudCredentialPayload(IptvSource source) => {
    'm3u_url': source.m3uUrl,
    if (source.epgUrl != null && source.epgUrl!.isNotEmpty) 'epg_url': source.epgUrl!,
    if (source.userAgent != null && source.userAgent!.isNotEmpty) 'user_agent': source.userAgent!,
    if (source.referer != null && source.referer!.isNotEmpty) 'referer': source.referer!,
  };

  static String _formatError(Object error) => error is CloudApiException ? error.message : '$error';

  Future<void> _openEditor(BuildContext context, {required bool isCloud, IptvSource? existing}) async {
    final provider = context.read<IptvProvider>();
    final binder = maybeReadTtplayBinder(context);
    final repo = binder?.cloudSourceRepository;

    final saved = await showScopedDialog<IptvSource>(
      context: context,
      builder: (_) => _IptvSourceEditDialog(
        isCloud: isCloud,
        provider: provider,
        existing: existing,
        onCommit: (candidate) async {
          if (isCloud) {
            if (repo == null || binder == null) {
              throw StateError('同步服务未就绪，请重新登录后重试');
            }
            final payload = _buildCloudCredentialPayload(candidate);
            final normalizedIdentity = 'iptv:${candidate.m3uUrl.toLowerCase()}';
            String targetCloudId;
            if (existing == null) {
              final created = await repo.createSource(
                kind: 'iptv',
                name: candidate.name,
                normalizedIdentity: normalizedIdentity,
                credentialPayload: payload,
              );
              targetCloudId = created.id;
            } else {
              targetCloudId = _resolveCloudSourceId(existing);
              final cred = await repo.fetchCredential(targetCloudId);
              if (candidate.name != existing.name) {
                await repo.renameSource(targetCloudId, candidate.name);
              }
              await repo.updateCredential(
                sourceId: targetCloudId,
                baseVersion: cred.version,
                credentialPayload: payload,
                mode: 'refresh',
                normalizedIdentity: normalizedIdentity,
              );
            }
            await binder.syncCloudProjection(full: true);
            final synced = provider.cloudSources
                .where((s) => s.cloudSourceId == targetCloudId || s.id == 'cloud:$targetCloudId')
                .firstOrNull;
            if (synced != null) {
              unawaited(provider.ensureLoaded(synced, forceRefresh: true));
            }
            return;
          }

          if (existing == null) {
            await provider.addLocalSource(candidate);
          } else {
            await provider.updateLocalSource(candidate);
          }
          unawaited(provider.ensureLoaded(candidate, forceRefresh: true));
        },
      ),
    );
    if (saved == null || !context.mounted) return;

    showSuccessSnackBar(
      context,
      existing == null
          ? (isCloud ? '已添加并同步「${saved.name}」' : '已添加「${saved.name}」')
          : (isCloud ? '已更新并同步「${saved.name}」' : '已更新「${saved.name}」'),
    );
  }

  Future<void> _confirmDelete(BuildContext context, IptvSource source, {required bool isCloud}) async {
    final ok = await showConfirmDialog(
      context,
      title: '删除 IPTV 直播源',
      message: isCloud
          ? '确定要从当前同步账号移除「${source.name}」吗？所有已登录设备将同步移除该直播源。'
          : '确定要从本设备移除「${source.name}」吗？',
      confirmText: '删除',
      isDestructive: true,
    );
    if (!ok || !context.mounted) return;

    final provider = context.read<IptvProvider>();
    final binder = maybeReadTtplayBinder(context);
    try {
      if (isCloud) {
        final repo = binder?.cloudSourceRepository;
        if (repo == null || binder == null) {
          throw StateError('同步服务未就绪，请重新登录后重试');
        }
        await repo.deleteSource(_resolveCloudSourceId(source));
        await provider.clearSourceDiskCache(source.id);
        await binder.syncCloudProjection(full: true);
      } else {
        await provider.removeLocalSource(source.id);
      }
      if (!context.mounted) return;
      showSuccessSnackBar(context, '已删除「${source.name}」');
    } catch (e) {
      if (!context.mounted) return;
      showErrorSnackBar(context, _formatError(e));
    }
  }

  Future<void> _syncNow() async {
    final binder = maybeReadTtplayBinder(context);
    if (binder == null || _syncing) return;
    setState(() => _syncing = true);
    try {
      await binder.syncCloudProjection(full: true);
    } catch (e) {
      if (!mounted) return;
      showErrorSnackBar(context, _formatError(e));
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<IptvProvider>();
    final appSession = maybeWatchAppSession(context);
    final ttplayBinder = maybeWatchTtplayBinder(context);
    final isSelfHosted = (appSession?.isSelfHosted ?? false) || provider.isCloudMode;
    final repo = ttplayBinder?.cloudSourceRepository;
    final canManageCloud = isSelfHosted && !PlatformDetector.isTV() && repo != null;
    final canAdd = !isSelfHosted || canManageCloud;
    final sources = isSelfHosted ? provider.cloudSources : provider.localSources;
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
                if (canAdd)
                  IconButton(
                    tooltip: '添加 IPTV 源',
                    icon: const AppIcon(Symbols.add_rounded),
                    onPressed: () => _openEditor(context, isCloud: isSelfHosted),
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
                        if (sources.isEmpty)
                          _IptvEmptyCard(
                            icon: isSelfHosted && !canManageCloud ? Symbols.cloud_sync_rounded : Symbols.live_tv_rounded,
                            title: isSelfHosted && !canManageCloud ? '尚未同步 IPTV 直播源' : '尚未添加 IPTV 订阅',
                            subtitle: isSelfHosted
                                ? (canManageCloud
                                      ? '添加的直播源将加密同步至当前账号下的所有设备，支持 M3U / M3U8 / TXT (#genre#) 与 XMLTV EPG。'
                                      : '请在手机或电脑端登录同一账号添加 IPTV 订阅，TV 端将自动同步。')
                                : '支持 M3U / M3U8 / TXT (#genre#) 直播源、多线路自动聚合、自定义 User-Agent / Referer 以及 XMLTV EPG 节目单。',
                            actionLabel: isSelfHosted
                                ? (canManageCloud
                                      ? '添加 IPTV 源'
                                      : (ttplayBinder != null ? (_syncing ? '同步中...' : '立即同步') : null))
                                : '添加第一个 IPTV 源',
                            actionIcon: isSelfHosted && !canManageCloud ? Symbols.sync_rounded : Symbols.add_rounded,
                            onAction: isSelfHosted
                                ? (canManageCloud
                                      ? () => _openEditor(context, isCloud: true)
                                      : (ttplayBinder != null && !_syncing ? _syncNow : null))
                                : () => _openEditor(context, isCloud: false),
                          )
                        else ...[
                          for (final src in sources) ...[
                            _SourceCard(
                              source: src,
                              channelCount: provider.channelsFor(src.id).length,
                              isCached: provider.isUsingDiskCache(src.id),
                              isLoading: provider.isLoading(src.id),
                              error: provider.errorFor(src.id),
                              onRefresh: () => provider.ensureLoaded(src, forceRefresh: true),
                              onEdit: (!isSelfHosted || canManageCloud)
                                  ? () => _openEditor(context, isCloud: isSelfHosted, existing: src)
                                  : null,
                              onDelete: (!isSelfHosted || canManageCloud)
                                  ? () => _confirmDelete(context, src, isCloud: isSelfHosted)
                                  : null,
                            ),
                            const SizedBox(height: 10),
                          ],
                          if (isSelfHosted && !canManageCloud) ...[
                            const SizedBox(height: 6),
                            Text(
                              '直播源由同步服务器管理，请在手机或电脑端添加或编辑。',
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ],
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

class _IptvEmptyCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String? actionLabel;
  final IconData actionIcon;
  final VoidCallback? onAction;

  const _IptvEmptyCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.actionLabel,
    required this.actionIcon,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
        child: Column(
          children: [
            AppIcon(icon, size: 48, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(title, style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            if (actionLabel != null) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: onAction,
                icon: AppIcon(actionIcon, size: 18),
                label: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SourceCard extends StatelessWidget {
  final IptvSource source;
  final int channelCount;
  final bool isCached;
  final bool isLoading;
  final String? error;
  final VoidCallback onRefresh;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  const _SourceCard({
    required this.source,
    required this.channelCount,
    required this.isCached,
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
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        source.name,
                        style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
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
                      if (channelCount > 0)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: scheme.primaryContainer.withValues(alpha: 0.65),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text('$channelCount 频道', style: theme.textTheme.labelSmall),
                        ),
                      if (channelCount > 0 && isCached)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: scheme.secondaryContainer.withValues(alpha: 0.7),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text('本地缓存', style: theme.textTheme.labelSmall),
                        ),
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
  final bool isCloud;
  final IptvProvider provider;
  final IptvSource? existing;
  final Future<void> Function(IptvSource source)? onCommit;

  const _IptvSourceEditDialog({
    required this.isCloud,
    required this.provider,
    this.existing,
    this.onCommit,
  });

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
    final id = widget.existing?.id ??
        (widget.isCloud ? 'cloud:pending' : 'local:${DateTime.now().microsecondsSinceEpoch}');

    try {
      final parsed = await widget.provider.parsePlaylist(
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
        isCloud: widget.isCloud,
        cloudSourceId: widget.existing?.cloudSourceId,
      );
      if (widget.onCommit != null) {
        await widget.onCommit!(source);
      }
      if (!mounted) return;
      Navigator.of(context).pop(source);
    } on FormatException catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.message;
      });
    } on CloudApiException catch (e) {
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
    final dialogTitle = widget.isCloud
        ? (isEditing ? '编辑云端 IPTV 源' : '添加云端 IPTV 源')
        : (isEditing ? '编辑 IPTV 源' : '添加 IPTV 源');

    return AlertDialog(
      title: Text(dialogTitle),
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
                    if (uri == null ||
                        !uri.hasScheme ||
                        uri.host.isEmpty ||
                        (uri.scheme != 'http' && uri.scheme != 'https')) {
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
