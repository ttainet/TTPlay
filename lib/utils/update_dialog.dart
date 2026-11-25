import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../exceptions/media_server_exceptions.dart';
import '../i18n/strings.g.dart';
import '../services/update_service.dart';
import '../utils/formatters.dart';
import '../utils/media_server_http_client.dart';
import '../widgets/dialog_action_button.dart';
import 'dialogs.dart';

class AndroidUpdateDialogDelegate {
  final Future<AndroidUpdateAsset?> Function(Map<String, dynamic> updateInfo) resolveAsset;
  final Future<String> Function({
    required AndroidUpdateAsset asset,
    required String version,
    void Function(int receivedBytes, int? totalBytes)? onProgress,
    AbortController? abort,
  })
  downloadUpdate;
  final Future<String> Function(String archivePath, {String? outputApkPath}) extractApkFromTarGz;
  final Future<AndroidInstallResult> Function(String apkPath) installApk;
  final Future<bool> Function() canRequestPackageInstalls;
  final Future<bool> Function() openUnknownSourcesSettings;
  final Future<void> Function(String url) openReleaseUrl;
  final Future<void> Function(String filePath) deleteFile;

  const AndroidUpdateDialogDelegate({
    required this.resolveAsset,
    required this.downloadUpdate,
    required this.extractApkFromTarGz,
    required this.installApk,
    required this.canRequestPackageInstalls,
    required this.openUnknownSourcesSettings,
    required this.openReleaseUrl,
    required this.deleteFile,
  });

  factory AndroidUpdateDialogDelegate.defaults() => AndroidUpdateDialogDelegate(
    resolveAsset: UpdateService.resolveAndroidAssetForDevice,
    downloadUpdate: ({required asset, required version, onProgress, abort}) => UpdateService.downloadAndroidUpdate(
      asset: asset,
      version: version,
      onProgress: onProgress,
      abort: abort,
    ),
    extractApkFromTarGz: UpdateService.extractApkFromTarGz,
    installApk: UpdateService.installAndroidApk,
    canRequestPackageInstalls: UpdateService.canRequestPackageInstalls,
    openUnknownSourcesSettings: UpdateService.openUnknownSourcesSettings,
    openReleaseUrl: (url) async {
      final parsed = Uri.parse(url);
      if (await canLaunchUrl(parsed)) {
        await launchUrl(parsed, mode: LaunchMode.externalApplication);
      }
    },
    deleteFile: (filePath) async {
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
      }
    },
  );
}

enum _UpdateDialogPhase { idle, downloading, extracting, permissionRequired, readyToInstall, error }

Future<void> showUpdateAvailableDialog(
  BuildContext context,
  Map<String, dynamic> updateInfo, {
  required String title,
  required String dismissLabel,
  bool showSkipVersion = false,
  AndroidUpdateDialogDelegate? delegate,
}) {
  return showScopedDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => _UpdateAvailableDialog(
      updateInfo: updateInfo,
      title: title,
      dismissLabel: dismissLabel,
      showSkipVersion: showSkipVersion,
      delegate: delegate ?? AndroidUpdateDialogDelegate.defaults(),
    ),
  );
}

class _UpdateAvailableDialog extends StatefulWidget {
  final Map<String, dynamic> updateInfo;
  final String title;
  final String dismissLabel;
  final bool showSkipVersion;
  final AndroidUpdateDialogDelegate delegate;

  const _UpdateAvailableDialog({
    required this.updateInfo,
    required this.title,
    required this.dismissLabel,
    required this.showSkipVersion,
    required this.delegate,
  });

  @override
  State<_UpdateAvailableDialog> createState() => _UpdateAvailableDialogState();
}

class _UpdateAvailableDialogState extends State<_UpdateAvailableDialog> with WidgetsBindingObserver {
  _UpdateDialogPhase _phase = _UpdateDialogPhase.idle;
  AndroidUpdateAsset? _asset;
  AbortController? _abortController;
  int _receivedBytes = 0;
  int? _totalBytes;
  String? _downloadedApkPath;
  String? _errorMessage;
  bool _wasCancelled = false;

  String get _latestVersion => widget.updateInfo['latestVersion'] as String;
  String get _currentVersion => widget.updateInfo['currentVersion'] as String;
  String get _releaseUrl => widget.updateInfo['releaseUrl'] as String;
  String get _releaseNotes => (widget.updateInfo['releaseNotes'] as String?)?.trim() ?? '';

  bool get _isBusy => _phase == _UpdateDialogPhase.downloading || _phase == _UpdateDialogPhase.extracting;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _totalBytes = null;
    unawaited(_resolveAsset());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _abortController?.abort();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _phase == _UpdateDialogPhase.permissionRequired &&
        _downloadedApkPath != null) {
      unawaited(_recheckPermissionAndInstall());
    }
  }

  Future<void> _resolveAsset() async {
    final asset = await widget.delegate.resolveAsset(widget.updateInfo);
    if (!mounted) return;
    setState(() {
      _asset = asset;
      if (asset?.size != null && asset!.size! > 0) {
        _totalBytes = asset.size;
      }
    });
  }

  Future<void> _recheckPermissionAndInstall() async {
    final allowed = await widget.delegate.canRequestPackageInstalls();
    if (!mounted || !allowed || _phase != _UpdateDialogPhase.permissionRequired) return;
    await _launchInstaller();
  }

  Future<void> _startDownload() async {
    final asset = _asset;
    if (asset == null) {
      await _openReleasePage();
      return;
    }

    final abort = AbortController();
    setState(() {
      _abortController = abort;
      _phase = _UpdateDialogPhase.downloading;
      _receivedBytes = 0;
      _totalBytes = (asset.size != null && asset.size! > 0) ? asset.size : null;
      _errorMessage = null;
      _wasCancelled = false;
    });

    try {
      final downloadedPath = await widget.delegate.downloadUpdate(
        asset: asset,
        version: _latestVersion,
        abort: abort,
        onProgress: (received, total) {
          if (!mounted || abort.isAborted) return;
          setState(() {
            _receivedBytes = received;
            if (total != null && total > 0) {
              _totalBytes = total;
            }
          });
        },
      );
      if (!mounted) return;
      _abortController = null;

      var apkPath = downloadedPath;
      if (asset.isTarGz) {
        setState(() {
          _phase = _UpdateDialogPhase.extracting;
        });
        apkPath = await widget.delegate.extractApkFromTarGz(downloadedPath);
        try {
          await widget.delegate.deleteFile(downloadedPath);
        } catch (_) {}
        if (!mounted) return;
      }

      _downloadedApkPath = apkPath;
      await _launchInstaller();
    } on MediaServerHttpException catch (error) {
      if (!mounted) return;
      _abortController = null;
      if (error.isCancellation || abort.isAborted) {
        setState(() {
          _phase = _UpdateDialogPhase.idle;
          _wasCancelled = true;
        });
      } else {
        setState(() {
          _phase = _UpdateDialogPhase.error;
          _errorMessage = t.update.downloadFailed(error: error.message.isNotEmpty ? error.message : error.toString());
        });
      }
    } catch (error) {
      if (!mounted) return;
      _abortController = null;
      if (abort.isAborted) {
        setState(() {
          _phase = _UpdateDialogPhase.idle;
          _wasCancelled = true;
        });
      } else {
        setState(() {
          _phase = _UpdateDialogPhase.error;
          _errorMessage = t.update.downloadFailed(error: error.toString());
        });
      }
    }
  }

  void _cancelDownload() {
    _abortController?.abort();
  }

  Future<void> _launchInstaller() async {
    final apkPath = _downloadedApkPath;
    if (apkPath == null) return;

    try {
      final result = await widget.delegate.installApk(apkPath);
      if (!mounted) return;
      setState(() {
        _phase = switch (result) {
          AndroidInstallResult.permissionRequired => _UpdateDialogPhase.permissionRequired,
          AndroidInstallResult.launched => _UpdateDialogPhase.readyToInstall,
        };
        _errorMessage = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _phase = _UpdateDialogPhase.error;
        _errorMessage = t.update.installFailed;
      });
    }
  }

  Future<void> _openReleasePage() async {
    await widget.delegate.openReleaseUrl(_releaseUrl);
    if (mounted) Navigator.pop(context);
  }

  String _formatProgressText(double? progress) {
    final receivedText = ByteFormatter.formatBytes(_receivedBytes);
    final total = _totalBytes;
    if (total != null && total > 0 && progress != null) {
      final percent = (progress * 100).round();
      return '$receivedText / ${ByteFormatter.formatBytes(total)} ($percent%)';
    }
    return _receivedBytes > 0 ? receivedText : '';
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_isBusy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _phase == _UpdateDialogPhase.downloading) {
          _cancelDownload();
        }
      },
      child: AlertDialog(
        title: Text(widget.title),
        content: _buildContent(context),
        actions: _buildActions(context),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    switch (_phase) {
      case _UpdateDialogPhase.idle:
        final size = _asset?.size;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.update.versionAvailable(version: _latestVersion), style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(t.update.currentVersion(version: _currentVersion), style: theme.textTheme.bodySmall),
            if (size != null && size > 0) ...[
              const SizedBox(height: 4),
              Text(ByteFormatter.formatBytes(size), style: theme.textTheme.bodySmall),
            ],
            if (_releaseNotes.isNotEmpty) ...[
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 160),
                child: SingleChildScrollView(
                  child: Text(_releaseNotes, style: theme.textTheme.bodySmall),
                ),
              ),
            ],
            if (_wasCancelled) ...[
              const SizedBox(height: 12),
              Text(
                t.update.downloadCancelled,
                style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.primary),
              ),
            ],
          ],
        );

      case _UpdateDialogPhase.downloading:
        final total = _totalBytes;
        final progress = (total != null && total > 0) ? (_receivedBytes / total).clamp(0.0, 1.0) : null;
        final progressText = _formatProgressText(progress);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.update.downloading, style: theme.textTheme.titleMedium),
            const SizedBox(height: 16),
            LinearProgressIndicator(value: progress),
            if (progressText.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(progressText, style: theme.textTheme.bodySmall),
            ],
          ],
        );

      case _UpdateDialogPhase.extracting:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.update.extracting, style: theme.textTheme.titleMedium),
            const SizedBox(height: 16),
            const LinearProgressIndicator(),
          ],
        );

      case _UpdateDialogPhase.permissionRequired:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.update.versionAvailable(version: _latestVersion), style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            Text(t.update.installPermissionRequired, style: theme.textTheme.bodyMedium),
          ],
        );

      case _UpdateDialogPhase.readyToInstall:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.update.installing, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(t.update.versionAvailable(version: _latestVersion), style: theme.textTheme.bodySmall),
          ],
        );

      case _UpdateDialogPhase.error:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.update.versionAvailable(version: _latestVersion), style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            Text(
              _errorMessage ?? t.update.installFailed,
              style: theme.textTheme.bodyMedium?.copyWith(color: colorScheme.error),
            ),
          ],
        );
    }
  }

  List<Widget> _buildActions(BuildContext context) {
    switch (_phase) {
      case _UpdateDialogPhase.idle:
        return [
          DialogActionButton(onPressed: () => Navigator.pop(context), label: widget.dismissLabel),
          if (widget.showSkipVersion)
            DialogActionButton(
              onPressed: () async {
                await UpdateService.skipVersion(_latestVersion);
                if (context.mounted) Navigator.pop(context);
              },
              label: t.update.skipVersion,
            ),
          if (_asset != null)
            DialogActionButton(
              onPressed: _startDownload,
              label: t.update.downloadAndInstall,
              isPrimary: true,
              autofocus: true,
            )
          else
            DialogActionButton(
              onPressed: _openReleasePage,
              label: t.update.viewRelease,
              isPrimary: true,
              autofocus: true,
            ),
        ];

      case _UpdateDialogPhase.downloading:
        return [
          DialogActionButton(onPressed: _cancelDownload, label: t.common.cancel, autofocus: true),
        ];

      case _UpdateDialogPhase.extracting:
        return const [];

      case _UpdateDialogPhase.permissionRequired:
        return [
          DialogActionButton(onPressed: () => Navigator.pop(context), label: t.common.close),
          DialogActionButton(onPressed: _launchInstaller, label: t.update.installNow),
          DialogActionButton(
            onPressed: () => widget.delegate.openUnknownSourcesSettings(),
            label: t.update.openSettings,
            isPrimary: true,
            autofocus: true,
          ),
        ];

      case _UpdateDialogPhase.readyToInstall:
        return [
          DialogActionButton(onPressed: () => Navigator.pop(context), label: t.common.close),
          DialogActionButton(
            onPressed: _launchInstaller,
            label: t.update.installNow,
            isPrimary: true,
            autofocus: true,
          ),
        ];

      case _UpdateDialogPhase.error:
        return [
          DialogActionButton(onPressed: () => Navigator.pop(context), label: t.common.close),
          DialogActionButton(onPressed: _openReleasePage, label: t.update.viewRelease),
          DialogActionButton(
            onPressed: _downloadedApkPath != null ? _launchInstaller : _startDownload,
            label: t.update.retry,
            isPrimary: true,
            autofocus: true,
          ),
        ];
    }
  }
}
