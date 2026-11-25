import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ttplay/exceptions/media_server_exceptions.dart';
import 'package:ttplay/focus/input_mode_tracker.dart';
import 'package:ttplay/i18n/strings.g.dart';
import 'package:ttplay/services/update_service.dart';
import 'package:ttplay/utils/media_server_http_client.dart';
import 'package:ttplay/utils/update_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

  final baseUpdateInfo = <String, dynamic>{
    'hasUpdate': true,
    'currentVersion': '1.0.0',
    'latestVersion': '2.0.0',
    'releaseUrl': 'https://github.com/ttainet/TTPlay/releases/tag/v2.0.0',
    'releaseName': 'TTPlay v2.0.0',
    'releaseNotes': 'Bug fixes and improvements',
  };

  Future<void> pumpHostAndOpenDialog(
    WidgetTester tester, {
    required AndroidUpdateDialogDelegate delegate,
    Map<String, dynamic>? updateInfo,
  }) async {
    await tester.pumpWidget(
      InputModeTracker(
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => ElevatedButton(
                  onPressed: () => unawaited(
                    showUpdateAvailableDialog(
                      context,
                      updateInfo ?? baseUpdateInfo,
                      title: t.update.available,
                      dismissLabel: t.common.later,
                      showSkipVersion: true,
                      delegate: delegate,
                    ),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  testWidgets('downloads APK with progress bar and launches installer on completion', (tester) async {
    const asset = AndroidUpdateAsset(
      name: 'ttplay-android-arm64-v8a.apk',
      downloadUrl: 'https://github.com/ttainet/TTPlay/releases/download/v2.0.0/ttplay-android-arm64-v8a.apk',
      size: 1024 * 1024,
      isTarGz: false,
    );
    final downloadCompleter = Completer<String>();
    void Function(int, int?)? capturedProgress;
    String? installedPath;

    final delegate = AndroidUpdateDialogDelegate(
      resolveAsset: (_) async => asset,
      downloadUpdate: ({required asset, required version, onProgress, abort}) {
        capturedProgress = onProgress;
        return downloadCompleter.future;
      },
      extractApkFromTarGz: (archivePath, {outputApkPath}) async => archivePath,
      installApk: (apkPath) async {
        installedPath = apkPath;
        return AndroidInstallResult.launched;
      },
      canRequestPackageInstalls: () async => true,
      openUnknownSourcesSettings: () async => true,
      openReleaseUrl: (_) async {},
      deleteFile: (_) async {},
    );

    await pumpHostAndOpenDialog(tester, delegate: delegate);

    expect(find.text(t.update.downloadAndInstall), findsOneWidget);
    expect(find.text('1.0 MB'), findsOneWidget);
    expect(find.text('Bug fixes and improvements'), findsOneWidget);

    await tester.tap(find.text(t.update.downloadAndInstall));
    await tester.pump();

    expect(find.text(t.update.downloading), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text(t.common.cancel), findsOneWidget);

    capturedProgress?.call(512 * 1024, 1024 * 1024);
    await tester.pump();

    expect(find.text('512.0 KB / 1.0 MB (50%)'), findsOneWidget);

    downloadCompleter.complete('/tmp/updates/ttplay.apk');
    await tester.pumpAndSettle();

    expect(installedPath, '/tmp/updates/ttplay.apk');
    expect(find.text(t.update.installing), findsOneWidget);
    expect(find.text(t.update.installNow), findsOneWidget);
  });

  testWidgets('cancelling download aborts request and returns to idle state', (tester) async {
    const asset = AndroidUpdateAsset(
      name: 'ttplay-android-arm64-v8a.apk',
      downloadUrl: 'https://github.com/ttainet/TTPlay/releases/download/v2.0.0/ttplay-android-arm64-v8a.apk',
      size: 2048,
      isTarGz: false,
    );
    final downloadCompleter = Completer<String>();
    AbortController? capturedAbort;

    final delegate = AndroidUpdateDialogDelegate(
      resolveAsset: (_) async => asset,
      downloadUpdate: ({required asset, required version, onProgress, abort}) {
        capturedAbort = abort;
        abort?.trigger.then((_) {
          if (!downloadCompleter.isCompleted) {
            downloadCompleter.completeError(
              MediaServerHttpException(type: MediaServerHttpErrorType.cancelled, message: 'cancelled'),
            );
          }
        });
        return downloadCompleter.future;
      },
      extractApkFromTarGz: (archivePath, {outputApkPath}) async => archivePath,
      installApk: (_) async => AndroidInstallResult.launched,
      canRequestPackageInstalls: () async => true,
      openUnknownSourcesSettings: () async => true,
      openReleaseUrl: (_) async {},
      deleteFile: (_) async {},
    );

    await pumpHostAndOpenDialog(tester, delegate: delegate);
    await tester.tap(find.text(t.update.downloadAndInstall));
    await tester.pump();

    expect(find.text(t.update.downloading), findsOneWidget);

    await tester.tap(find.text(t.common.cancel));
    await tester.pumpAndSettle();

    expect(capturedAbort?.isAborted, isTrue);
    expect(find.text(t.update.downloadCancelled), findsOneWidget);
    expect(find.text(t.update.downloadAndInstall), findsOneWidget);
  });

  testWidgets('prompts for install permission and resumes installation when granted', (tester) async {
    const asset = AndroidUpdateAsset(
      name: 'ttplay-android-arm64-v8a.apk',
      downloadUrl: 'https://github.com/ttainet/TTPlay/releases/download/v2.0.0/ttplay-android-arm64-v8a.apk',
      size: 2048,
      isTarGz: false,
    );
    var permissionGranted = false;
    var settingsOpened = false;
    var installCalls = 0;

    final delegate = AndroidUpdateDialogDelegate(
      resolveAsset: (_) async => asset,
      downloadUpdate: ({required asset, required version, onProgress, abort}) async => '/tmp/updates/ttplay.apk',
      extractApkFromTarGz: (archivePath, {outputApkPath}) async => archivePath,
      installApk: (_) async {
        installCalls++;
        return permissionGranted ? AndroidInstallResult.launched : AndroidInstallResult.permissionRequired;
      },
      canRequestPackageInstalls: () async => permissionGranted,
      openUnknownSourcesSettings: () async {
        settingsOpened = true;
        return true;
      },
      openReleaseUrl: (_) async {},
      deleteFile: (_) async {},
    );

    await pumpHostAndOpenDialog(tester, delegate: delegate);
    await tester.tap(find.text(t.update.downloadAndInstall));
    await tester.pumpAndSettle();

    expect(installCalls, 1);
    expect(find.text(t.update.installPermissionRequired), findsOneWidget);
    expect(find.text(t.update.openSettings), findsOneWidget);

    await tester.tap(find.text(t.update.openSettings));
    await tester.pump();
    expect(settingsOpened, isTrue);

    permissionGranted = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(installCalls, 2);
    expect(find.text(t.update.installing), findsOneWidget);
  });

  testWidgets('extracts .tar.gz asset, deletes archive, and installs APK', (tester) async {
    const asset = AndroidUpdateAsset(
      name: 'ttplay-android-arm64-v8a.tar.gz',
      downloadUrl: 'https://github.com/ttainet/TTPlay/releases/download/v2.0.0/ttplay-android-arm64-v8a.tar.gz',
      size: 2048,
      isTarGz: true,
    );
    String? extractedFrom;
    String? deletedArchive;
    String? installedApk;

    final delegate = AndroidUpdateDialogDelegate(
      resolveAsset: (_) async => asset,
      downloadUpdate: ({required asset, required version, onProgress, abort}) async =>
          '/tmp/updates/ttplay-android-arm64-v8a.tar.gz',
      extractApkFromTarGz: (archivePath, {outputApkPath}) async {
        extractedFrom = archivePath;
        return '/tmp/updates/ttplay.apk';
      },
      installApk: (apkPath) async {
        installedApk = apkPath;
        return AndroidInstallResult.launched;
      },
      canRequestPackageInstalls: () async => true,
      openUnknownSourcesSettings: () async => true,
      openReleaseUrl: (_) async {},
      deleteFile: (path) async {
        deletedArchive = path;
      },
    );

    await pumpHostAndOpenDialog(tester, delegate: delegate);
    await tester.tap(find.text(t.update.downloadAndInstall));
    await tester.pumpAndSettle();

    expect(extractedFrom, '/tmp/updates/ttplay-android-arm64-v8a.tar.gz');
    expect(deletedArchive, '/tmp/updates/ttplay-android-arm64-v8a.tar.gz');
    expect(installedApk, '/tmp/updates/ttplay.apk');
    expect(find.text(t.update.installing), findsOneWidget);
  });

  testWidgets('shows retry and view release fallback when download fails', (tester) async {
    const asset = AndroidUpdateAsset(
      name: 'ttplay-android-arm64-v8a.apk',
      downloadUrl: 'https://github.com/ttainet/TTPlay/releases/download/v2.0.0/ttplay-android-arm64-v8a.apk',
      size: 2048,
      isTarGz: false,
    );
    String? openedUrl;

    final delegate = AndroidUpdateDialogDelegate(
      resolveAsset: (_) async => asset,
      downloadUpdate: ({required asset, required version, onProgress, abort}) async {
        throw StateError('network unreachable');
      },
      extractApkFromTarGz: (archivePath, {outputApkPath}) async => archivePath,
      installApk: (_) async => AndroidInstallResult.launched,
      canRequestPackageInstalls: () async => true,
      openUnknownSourcesSettings: () async => true,
      openReleaseUrl: (url) async {
        openedUrl = url;
      },
      deleteFile: (_) async {},
    );

    await pumpHostAndOpenDialog(tester, delegate: delegate);
    await tester.tap(find.text(t.update.downloadAndInstall));
    await tester.pumpAndSettle();

    expect(find.text(t.update.retry), findsOneWidget);
    expect(find.text(t.update.viewRelease), findsOneWidget);

    await tester.tap(find.text(t.update.viewRelease));
    await tester.pumpAndSettle();

    expect(openedUrl, 'https://github.com/ttainet/TTPlay/releases/tag/v2.0.0');
  });
}
