import 'dart:io';

import 'package:auto_updater/auto_updater.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:ttplay/utils/app_logger.dart';
import 'package:ttplay/utils/media_server_http_client.dart';
import 'package:ttplay/utils/platform_detector.dart';
import 'base_shared_preferences_service.dart';

/// Release asset metadata for Android in-app updates.
class AndroidUpdateAsset {
  final String name;
  final String downloadUrl;
  final int? size;
  final bool isTarGz;

  const AndroidUpdateAsset({
    required this.name,
    required this.downloadUrl,
    this.size,
    required this.isTarGz,
  });
}

enum AndroidInstallResult { launched, permissionRequired }

/// Service to check for new versions on GitHub
/// Enabled by default via ENABLE_UPDATE_CHECK (can be disabled at build time)
///
/// On macOS (non-Homebrew) and installed Windows when ENABLE_NATIVE_UPDATER=true:
/// delegates to Sparkle/WinSparkle via auto_updater for native update dialogs and in-app installs.
/// On all other configurations: uses GitHub Releases API check + browser link dialog.
class UpdateService {
  static const String _githubRepo = 'ttainet/TTPlay';
  static const String _feedUrl = 'https://cdn.jsdelivr.net/gh/ttainet/TTPlay@appcast/appcast.xml';
  static const MethodChannel _apkInstallerChannel = MethodChannel('com.ttai.ttplay/apk_installer');
  static const List<String> _knownAndroidAbis = ['arm64-v8a', 'armeabi-v7a', 'x86_64', 'x86'];

  static const String _keySkippedVersion = 'update_skipped_version';
  static const String _keyLastCheckTime = 'update_last_check_time';

  // Check cooldown: 6 hours
  static const Duration _checkCooldown = Duration(hours: 6);

  static bool _nativeUpdaterInitialized = false;

  /// Check if update checking is enabled via build flag
  static bool get isUpdateCheckEnabled {
    return const bool.fromEnvironment('ENABLE_UPDATE_CHECK', defaultValue: true);
  }

  /// Whether the native Sparkle/WinSparkle appcast updater is enabled at build time
  static bool get isNativeUpdaterEnabled {
    return const bool.fromEnvironment('ENABLE_NATIVE_UPDATER', defaultValue: false);
  }

  /// Whether any in-app update path applies to this install.
  /// False inside a packaged (MSIX/Store) install: the Store owns updates and
  /// the package directory is read-only, so neither WinSparkle nor the GitHub
  /// fallback dialog has anything it can do. Gates the settings entry too, so
  /// no dead affordance ships.
  static bool get isUpdateCheckAvailable => isUpdateCheckEnabled && !PlatformDetector.isPackagedInstall();

  /// Whether the native auto_updater (Sparkle/WinSparkle) should be used.
  /// True on macOS (non-Homebrew) and installed Windows (has uninstaller) when ENABLE_NATIVE_UPDATER is enabled.
  static bool get useNativeUpdater {
    if (!isNativeUpdaterEnabled || !isUpdateCheckAvailable) return false;
    if (Platform.isMacOS) return !_isHomebrewInstall();
    if (Platform.isWindows) return _isInstalledApp() && !_isWingetInstall();
    return false;
  }

  /// Initialize the native auto_updater (Sparkle/WinSparkle).
  /// Call once at startup if [useNativeUpdater] is true.
  static Future<void> initNativeUpdater() async {
    if (_nativeUpdaterInitialized) return;

    try {
      await autoUpdater.setFeedURL(_feedUrl);
      _nativeUpdaterInitialized = true;
    } catch (error, stackTrace) {
      appLogger.e('Failed to initialize native auto updater', error: error, stackTrace: stackTrace);
    }
  }

  /// Trigger a background update check via Sparkle/WinSparkle.
  /// Only shows UI if an update is found.
  static Future<void> checkForUpdatesNative({bool inBackground = true}) async {
    if (!_nativeUpdaterInitialized) {
      await initNativeUpdater();
      if (!_nativeUpdaterInitialized) return;
    }
    try {
      await autoUpdater.checkForUpdates(inBackground: inBackground);
    } catch (error, stackTrace) {
      appLogger.e('Native update check failed', error: error, stackTrace: stackTrace);
    }
  }

  /// Check if the macOS app was installed via Homebrew.
  /// Homebrew casks live under /opt/homebrew/Caskroom/ or /usr/local/Caskroom/.
  static bool _isHomebrewInstall() {
    final execPath = Platform.resolvedExecutable;
    return execPath.contains('/Caskroom/') || execPath.contains('/homebrew/');
  }

  /// Check if the Windows app was installed via winget.
  /// The Inno Setup installer writes a .winget marker file when invoked with /WINGET=1.
  static bool _isWingetInstall() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    return File('$exeDir\\.winget').existsSync();
  }

  /// Check if the Windows app is an installed copy (not portable).
  /// The Inno Setup installer places unins000.exe next to the executable.
  static bool _isInstalledApp() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    return File('$exeDir\\unins000.exe').existsSync();
  }

  static Future<void> skipVersion(String version) async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    await prefs.setString(_keySkippedVersion, version);
  }

  static Future<String?> getSkippedVersion() async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    return prefs.getString(_keySkippedVersion);
  }

  /// Check if cooldown period has passed since last check
  static Future<bool> shouldCheckForUpdates() async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    final lastCheckString = prefs.getString(_keyLastCheckTime);
    if (lastCheckString == null) return true;

    final now = DateTime.now();
    final lastCheck = DateTime.tryParse(lastCheckString);
    if (lastCheck == null || lastCheck.isAfter(now)) {
      await prefs.remove(_keyLastCheckTime);
      return true;
    }

    return now.difference(lastCheck) >= _checkCooldown;
  }

  static Future<void> _updateLastCheckTime() async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    await prefs.setString(_keyLastCheckTime, DateTime.now().toIso8601String());
  }

  /// Internal method that performs the actual update check
  /// [respectCooldown] - if true, checks cooldown and records the attempt before the request
  /// [throwOnFailure] - if true, a failed check (network, non-200, bad payload)
  /// is rethrown instead of reading as "no update"
  static Future<Map<String, dynamic>?> _performUpdateCheck({
    required bool respectCooldown,
    MediaServerHttpClient? client,
    bool forceEnabled = false,
    bool throwOnFailure = false,
  }) async {
    if (!forceEnabled && !isUpdateCheckAvailable) {
      return null;
    }

    // Check cooldown if requested
    if (respectCooldown && !await shouldCheckForUpdates()) {
      return null;
    }

    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      if (respectCooldown) {
        await _updateLastCheckTime();
      }

      final response = await (client ?? httpClient).get(
        'https://api.github.com/repos/$_githubRepo/releases/latest',
        headers: {'Accept': 'application/vnd.github+json'},
      );

      if (response.statusCode != 200) {
        throw StateError('Release check returned HTTP ${response.statusCode}');
      }
      final data = response.data;
      final latestVersion = data['tag_name'] as String;

      // Remove 'v' prefix if present
      final cleanVersion = latestVersion.startsWith('v') ? latestVersion.substring(1) : latestVersion;

      final hasUpdate = _isNewerVersion(cleanVersion, currentVersion);

      if (hasUpdate) {
        // Check if this version was skipped
        final skippedVersion = await getSkippedVersion();
        if (skippedVersion == cleanVersion) {
          return null;
        }

        final rawAssets = data['assets'];
        final assets = rawAssets is List
            ? rawAssets
                  .whereType<Map>()
                  .map(
                    (asset) => <String, dynamic>{
                      'name': asset['name'],
                      'browser_download_url': asset['browser_download_url'],
                      'size': asset['size'],
                    },
                  )
                  .toList()
            : const <Map<String, dynamic>>[];

        return {
          'hasUpdate': true,
          'currentVersion': currentVersion,
          'latestVersion': cleanVersion,
          'releaseUrl': data['html_url'] as String,
          'releaseName': data['name'] as String? ?? 'Version $cleanVersion',
          'releaseNotes': data['body'] as String? ?? '',
          'publishedAt': data['published_at'] as String,
          'assets': assets,
        };
      }
    } catch (error, stackTrace) {
      appLogger.e('Failed to check for updates', error: error, stackTrace: stackTrace);
      if (throwOnFailure) rethrow;
    }

    return null;
  }

  @visibleForTesting
  static Future<Map<String, dynamic>?> debugPerformUpdateCheck({
    required bool respectCooldown,
    required MediaServerHttpClient client,
    bool throwOnFailure = false,
  }) {
    return _performUpdateCheck(
      respectCooldown: respectCooldown,
      client: client,
      forceEnabled: true,
      throwOnFailure: throwOnFailure,
    );
  }

  /// Check for updates on GitHub (manual check, ignores cooldown)
  /// Returns a map with update info, or null when there is no update (or the
  /// release is skipped). Throws when the check itself fails, so the caller
  /// can say so instead of reporting the latest version.
  static Future<Map<String, dynamic>?> checkForUpdates() {
    return _performUpdateCheck(respectCooldown: false, throwOnFailure: true);
  }

  /// Check for updates on startup (respects cooldown and skipped versions)
  /// Returns update info if available, null otherwise
  static Future<Map<String, dynamic>?> checkForUpdatesOnStartup() {
    return _performUpdateCheck(respectCooldown: true);
  }

  static bool _matchesAbiToken(String lowerName, String lowerAbi) {
    final pattern = RegExp('(^|[-_./])${RegExp.escape(lowerAbi)}(?!_64)([-_./]|\$)');
    return pattern.hasMatch(lowerName);
  }

  /// Select the best Android update asset for [supportedAbis], preferring raw
  /// `.apk` over `.tar.gz` for each ABI and falling back to a universal `.apk`.
  static AndroidUpdateAsset? selectAndroidAsset(List<dynamic>? rawAssets, List<String> supportedAbis) {
    if (rawAssets == null || rawAssets.isEmpty) return null;

    final candidates = <AndroidUpdateAsset>[];
    for (final raw in rawAssets) {
      if (raw is! Map) continue;
      final name = (raw['name'] as String?)?.trim() ?? '';
      final url = (raw['browser_download_url'] as String?)?.trim() ?? '';
      final parsedUri = Uri.tryParse(url);
      if (name.isEmpty || parsedUri == null || parsedUri.scheme.toLowerCase() != 'https') continue;

      final lowerName = name.toLowerCase();
      final isApk = lowerName.endsWith('.apk');
      final isTarGz = lowerName.endsWith('.tar.gz');
      if (!isApk && !isTarGz) continue;

      final rawSize = raw['size'];
      final size = rawSize is num ? rawSize.toInt() : null;
      candidates.add(AndroidUpdateAsset(name: name, downloadUrl: url, size: size, isTarGz: isTarGz));
    }

    if (candidates.isEmpty) return null;

    for (final abi in supportedAbis) {
      final lowerAbi = abi.trim().toLowerCase();
      if (lowerAbi.isEmpty) continue;

      for (final asset in candidates) {
        if (!asset.isTarGz && _matchesAbiToken(asset.name.toLowerCase(), lowerAbi)) {
          return asset;
        }
      }
      for (final asset in candidates) {
        if (asset.isTarGz && _matchesAbiToken(asset.name.toLowerCase(), lowerAbi)) {
          return asset;
        }
      }
    }

    for (final asset in candidates) {
      if (asset.isTarGz) continue;
      final lowerName = asset.name.toLowerCase();
      final hasSpecificAbi = _knownAndroidAbis.any((abi) => _matchesAbiToken(lowerName, abi));
      if (!hasSpecificAbi) return asset;
    }

    return null;
  }

  /// Resolve the best Android update asset for the current device.
  static Future<AndroidUpdateAsset?> resolveAndroidAssetForDevice(Map<String, dynamic> updateInfo) async {
    if (!Platform.isAndroid) return null;
    final rawAssets = updateInfo['assets'] as List<dynamic>?;
    if (rawAssets == null || rawAssets.isEmpty) return null;
    try {
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      return selectAndroidAsset(rawAssets, androidInfo.supportedAbis);
    } catch (error, stackTrace) {
      appLogger.e('Failed to resolve Android ABI for update', error: error, stackTrace: stackTrace);
      return null;
    }
  }

  static String _sanitizeFileNameSegment(String value) {
    final sanitized = value.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    return sanitized.isEmpty ? 'update' : sanitized;
  }

  static Future<Directory> _updatesDirectory({Directory? tempDirOverride}) async {
    final baseDir = tempDirOverride ?? await getTemporaryDirectory();
    return Directory(path.join(baseDir.path, 'updates'));
  }

  /// Download an Android update asset into the app's temporary `updates/` directory.
  static Future<String> downloadAndroidUpdate({
    required AndroidUpdateAsset asset,
    required String version,
    void Function(int receivedBytes, int? totalBytes)? onProgress,
    AbortController? abort,
    MediaServerHttpClient? client,
    Directory? tempDirOverride,
  }) async {
    final updatesDir = await _updatesDirectory(tempDirOverride: tempDirOverride);
    final fileName = 'ttplay_${_sanitizeFileNameSegment(version)}_${_sanitizeFileNameSegment(asset.name)}';
    final targetPath = path.join(updatesDir.path, fileName);

    await (client ?? httpClient).downloadFile(
      asset.downloadUrl,
      targetPath,
      timeout: const Duration(minutes: 15),
      abort: abort,
      onProgress: onProgress,
    );

    final downloadedFile = File(targetPath);
    if (asset.size != null && asset.size! > 0) {
      final actualLength = await downloadedFile.length();
      if (actualLength != asset.size) {
        try {
          if (await downloadedFile.exists()) await downloadedFile.delete();
        } catch (_) {}
        throw StateError('Downloaded update size mismatch: expected ${asset.size}, got $actualLength');
      }
    }

    return targetPath;
  }

  static Future<bool> canRequestPackageInstalls() async {
    if (!Platform.isAndroid) return false;
    final allowed = await _apkInstallerChannel.invokeMethod<bool>('canRequestPackageInstalls');
    return allowed ?? false;
  }

  static Future<bool> openUnknownSourcesSettings() async {
    if (!Platform.isAndroid) return false;
    final opened = await _apkInstallerChannel.invokeMethod<bool>('openUnknownSourcesSettings');
    return opened ?? false;
  }

  static Future<String> extractApkFromTarGz(String archivePath, {String? outputApkPath}) async {
    final defaultApkPath = archivePath.toLowerCase().endsWith('.tar.gz')
        ? '${archivePath.substring(0, archivePath.length - 7)}.apk'
        : '${path.withoutExtension(archivePath)}.apk';
    final targetApkPath = outputApkPath ?? defaultApkPath;
    final extractedPath = await _apkInstallerChannel.invokeMethod<String>('extractApkFromTarGz', {
      'archivePath': archivePath,
      'outputPath': targetApkPath,
    });
    if (extractedPath == null || extractedPath.isEmpty) {
      throw StateError('Failed to extract APK from archive');
    }
    return extractedPath;
  }

  static Future<AndroidInstallResult> installAndroidApk(String apkPath) async {
    final result = await _apkInstallerChannel.invokeMapMethod<String, dynamic>('installApk', {'apkPath': apkPath});
    final status = result?['status'] as String?;
    return switch (status) {
      'launched' => AndroidInstallResult.launched,
      'permission_required' => AndroidInstallResult.permissionRequired,
      _ => throw StateError('Unexpected APK install status: $status'),
    };
  }

  /// Clean up cached update archives and APKs from previous runs.
  static Future<void> cleanupCachedUpdates({Directory? tempDirOverride}) async {
    if (!Platform.isAndroid && tempDirOverride == null) return;
    try {
      final updatesDir = await _updatesDirectory(tempDirOverride: tempDirOverride);
      if (await updatesDir.exists()) {
        await updatesDir.delete(recursive: true);
      }
    } catch (error) {
      appLogger.w('Failed to clean up cached updates', error: error);
    }
  }

  /// Parse version string into list of integers
  /// Handles versions like "1.2.3+4" by taking only the numeric parts
  static List<int> _parseVersionParts(String version) {
    return version.split('.').map((p) {
      final numPart = p.split('+').first.split('-').first;
      return int.tryParse(numPart) ?? 0;
    }).toList();
  }

  /// Compare two version strings
  /// Returns true if newVersion is newer than currentVersion
  static bool _isNewerVersion(String newVersion, String currentVersion) {
    try {
      final newParts = _parseVersionParts(newVersion);
      final currentParts = _parseVersionParts(currentVersion);

      // Compare each part
      final maxLength = newParts.length > currentParts.length ? newParts.length : currentParts.length;

      for (int i = 0; i < maxLength; i++) {
        final newPart = i < newParts.length ? newParts[i] : 0;
        final currentPart = i < currentParts.length ? currentParts[i] : 0;

        if (newPart > currentPart) return true;
        if (newPart < currentPart) return false;
      }

      return false;
    } catch (error, stackTrace) {
      appLogger.e('Error comparing versions', error: error, stackTrace: stackTrace);
      return false;
    }
  }
}
