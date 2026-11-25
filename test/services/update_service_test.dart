import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:ttplay/exceptions/media_server_exceptions.dart';
import 'package:ttplay/utils/media_server_http_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ttplay/services/base_shared_preferences_service.dart';
import 'package:ttplay/services/update_service.dart';

import '../test_helpers/prefs.dart';

void main() {
  const lastCheckKey = 'update_last_check_time';

  setUp(resetSharedPreferencesForTest);
  PackageInfo.setMockInitialValues(
    appName: 'Plezy',
    packageName: 'com.ttai.ttplay.test',
    version: '1.0.0',
    buildNumber: '1',
    buildSignature: '',
  );

  test('malformed cooldown state fails open and removes the invalid value', () async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    await prefs.setString(lastCheckKey, 'not-an-instant');

    expect(await UpdateService.shouldCheckForUpdates(), isTrue);
    expect(prefs.getString(lastCheckKey), isNull);
  });

  test('future cooldown state fails open and removes the invalid value', () async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    await prefs.setString(lastCheckKey, DateTime.now().add(const Duration(days: 30)).toIso8601String());

    expect(await UpdateService.shouldCheckForUpdates(), isTrue);
    expect(prefs.getString(lastCheckKey), isNull);
  });

  test('recent valid cooldown state suppresses a duplicate check and remains stored', () async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    final recent = DateTime.now().subtract(const Duration(minutes: 5)).toIso8601String();
    await prefs.setString(lastCheckKey, recent);

    expect(await UpdateService.shouldCheckForUpdates(), isFalse);
    expect(prefs.getString(lastCheckKey), recent);
  });

  test('old valid cooldown state permits a new check', () async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    final old = DateTime.now().subtract(const Duration(days: 2)).toIso8601String();
    await prefs.setString(lastCheckKey, old);

    expect(await UpdateService.shouldCheckForUpdates(), isTrue);
    expect(prefs.getString(lastCheckKey), old);
  });

  final failedResponses = <String, Future<http.Response> Function()>{
    'timeout': () async => throw TimeoutException('request timed out'),
    'non-200 response': () async => http.Response('unavailable', 503),
    'parse failure': () async => http.Response('not-json', 200, headers: {'content-type': 'application/json'}),
  };

  for (final failure in failedResponses.entries) {
    test('a manual check reports a ${failure.key} as a failure, not as the latest version', () async {
      final client = MediaServerHttpClient(client: MockClient((_) => failure.value()));
      addTearDown(client.close);

      await expectLater(
        UpdateService.debugPerformUpdateCheck(respectCooldown: false, client: client, throwOnFailure: true),
        throwsA(anything),
      );
    });
  }

  test('a manual check that finds no newer release returns null', () async {
    final client = MediaServerHttpClient(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({'tag_name': 'v1.0.0', 'html_url': 'https://example.com', 'published_at': '2026-01-01'}),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
    addTearDown(client.close);

    expect(
      await UpdateService.debugPerformUpdateCheck(respectCooldown: false, client: client, throwOnFailure: true),
      isNull,
    );
  });

  test('queries ttainet/TTPlay GitHub latest release and returns parsed update info', () async {
    Uri? requestedUri;
    final client = MediaServerHttpClient(
      client: MockClient((request) async {
        requestedUri = request.url;
        return http.Response(
          jsonEncode({
            'tag_name': 'v2.0.0',
            'html_url': 'https://github.com/ttainet/TTPlay/releases/tag/v2.0.0',
            'name': 'TTPlay v2.0.0',
            'body': 'Release notes',
            'published_at': '2026-11-23T00:00:00Z',
            'assets': [
              {
                'name': 'ttplay-android-arm64-v8a.apk',
                'browser_download_url': 'https://github.com/ttainet/TTPlay/releases/download/v2.0.0/ttplay-android-arm64-v8a.apk',
                'size': 123456,
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(client.close);

    final result = await UpdateService.debugPerformUpdateCheck(
      respectCooldown: false,
      client: client,
      throwOnFailure: true,
    );

    expect(requestedUri.toString(), 'https://api.github.com/repos/ttainet/TTPlay/releases/latest');
    expect(result, isNotNull);
    expect(result!['hasUpdate'], isTrue);
    expect(result['currentVersion'], '1.0.0');
    expect(result['latestVersion'], '2.0.0');
    expect(result['releaseUrl'], 'https://github.com/ttainet/TTPlay/releases/tag/v2.0.0');
    expect(result['releaseName'], 'TTPlay v2.0.0');
    expect((result['assets'] as List).single['name'], 'ttplay-android-arm64-v8a.apk');
  });

  group('selectAndroidAsset', () {
    test('prefers raw .apk over .tar.gz for the top supported ABI', () {
      final assets = [
        {
          'name': 'ttplay-android-arm64-v8a.tar.gz',
          'browser_download_url': 'https://github.com/ttainet/TTPlay/releases/download/v2.0.0/ttplay-android-arm64-v8a.tar.gz',
          'size': 100,
        },
        {
          'name': 'ttplay-android-arm64-v8a.apk',
          'browser_download_url': 'https://github.com/ttainet/TTPlay/releases/download/v2.0.0/ttplay-android-arm64-v8a.apk',
          'size': 200,
        },
        {
          'name': 'ttplay-android-armeabi-v7a.apk',
          'browser_download_url': 'https://github.com/ttainet/TTPlay/releases/download/v2.0.0/ttplay-android-armeabi-v7a.apk',
          'size': 150,
        },
      ];

      final selected = UpdateService.selectAndroidAsset(assets, ['arm64-v8a', 'armeabi-v7a']);
      expect(selected, isNotNull);
      expect(selected!.name, 'ttplay-android-arm64-v8a.apk');
      expect(selected.isTarGz, isFalse);
      expect(selected.size, 200);
    });

    test('prefers primary ABI .tar.gz over secondary ABI .apk', () {
      final assets = [
        {
          'name': 'ttplay-android-arm64-v8a.tar.gz',
          'browser_download_url': 'https://github.com/ttainet/TTPlay/releases/download/v2.0.0/ttplay-android-arm64-v8a.tar.gz',
          'size': 100,
        },
        {
          'name': 'ttplay-android-armeabi-v7a.apk',
          'browser_download_url': 'https://github.com/ttainet/TTPlay/releases/download/v2.0.0/ttplay-android-armeabi-v7a.apk',
          'size': 150,
        },
      ];

      final selected = UpdateService.selectAndroidAsset(assets, ['arm64-v8a', 'armeabi-v7a']);
      expect(selected, isNotNull);
      expect(selected!.name, 'ttplay-android-arm64-v8a.tar.gz');
      expect(selected.isTarGz, isTrue);
    });

    test('does not confuse x86 with x86_64 and falls back to universal .apk', () {
      final assets = [
        {
          'name': 'ttplay-android-x86_64.apk',
          'browser_download_url': 'https://github.com/ttainet/TTPlay/releases/download/v2.0.0/ttplay-android-x86_64.apk',
          'size': 180,
        },
        {
          'name': 'ttplay-android-universal.apk',
          'browser_download_url': 'https://github.com/ttainet/TTPlay/releases/download/v2.0.0/ttplay-android-universal.apk',
          'size': 300,
        },
      ];

      final selected = UpdateService.selectAndroidAsset(assets, ['x86']);
      expect(selected, isNotNull);
      expect(selected!.name, 'ttplay-android-universal.apk');
    });

    test('returns null when no matching HTTPS Android asset exists', () {
      final assets = [
        {
          'name': 'ttplay-macos.dmg',
          'browser_download_url': 'https://github.com/ttainet/TTPlay/releases/download/v2.0.0/ttplay-macos.dmg',
          'size': 1000,
        },
        {
          'name': 'ttplay-android-arm64-v8a.apk',
          'browser_download_url': 'http://insecure.example/ttplay.apk',
          'size': 1000,
        },
      ];

      expect(UpdateService.selectAndroidAsset(assets, ['arm64-v8a']), isNull);
      expect(UpdateService.selectAndroidAsset(null, ['arm64-v8a']), isNull);
    });
  });

  group('downloadAndroidUpdate', () {
    test('streams chunks with progress and saves verified file', () async {
      final tempDir = await Directory.systemTemp.createTemp('update_download_ok_');
      addTearDown(() => tempDir.delete(recursive: true));

      final payload = List<int>.generate(1024, (i) => i % 256);
      final client = MediaServerHttpClient(
        client: MockClient.streaming((request, bodyStream) async {
          return http.StreamedResponse(
            Stream.fromIterable([payload.sublist(0, 400), payload.sublist(400)]),
            200,
            contentLength: payload.length,
          );
        }),
      );
      addTearDown(client.close);

      final progressEvents = <(int, int?)>[];
      final asset = AndroidUpdateAsset(
        name: 'ttplay-android-arm64-v8a.apk',
        downloadUrl: 'https://github.com/ttainet/TTPlay/releases/download/v2.0.0/ttplay-android-arm64-v8a.apk',
        size: payload.length,
        isTarGz: false,
      );

      final downloadedPath = await UpdateService.downloadAndroidUpdate(
        asset: asset,
        version: '2.0.0',
        client: client,
        tempDirOverride: tempDir,
        onProgress: (received, total) => progressEvents.add((received, total)),
      );

      expect(File(downloadedPath).readAsBytesSync(), payload);
      expect(progressEvents, isNotEmpty);
      expect(progressEvents.last, (payload.length, payload.length));
    });

    test('deletes downloaded file and throws when size mismatches', () async {
      final tempDir = await Directory.systemTemp.createTemp('update_download_mismatch_');
      addTearDown(() => tempDir.delete(recursive: true));

      final payload = List<int>.filled(256, 7);
      final client = MediaServerHttpClient(
        client: MockClient.streaming((request, bodyStream) async {
          return http.StreamedResponse(Stream.value(payload), 200, contentLength: payload.length);
        }),
      );
      addTearDown(client.close);

      const asset = AndroidUpdateAsset(
        name: 'ttplay-android-arm64-v8a.apk',
        downloadUrl: 'https://github.com/ttainet/TTPlay/releases/download/v2.0.0/ttplay-android-arm64-v8a.apk',
        size: 512,
        isTarGz: false,
      );

      await expectLater(
        UpdateService.downloadAndroidUpdate(
          asset: asset,
          version: '2.0.0',
          client: client,
          tempDirOverride: tempDir,
        ),
        throwsStateError,
      );

      final updatesDir = Directory('${tempDir.path}${Platform.pathSeparator}updates');
      expect(updatesDir.existsSync() ? updatesDir.listSync() : const [], isEmpty);
    });

    test('aborts in-flight download and cleans up temporary file', () async {
      final tempDir = await Directory.systemTemp.createTemp('update_download_abort_');
      addTearDown(() => tempDir.delete(recursive: true));

      final controller = StreamController<List<int>>();
      final firstChunkSent = Completer<void>();
      final client = MediaServerHttpClient(
        client: MockClient.streaming((request, bodyStream) async {
          if (request case final http.Abortable abortable) {
            unawaited(
              abortable.abortTrigger?.whenComplete(() {
                if (!controller.isClosed) {
                  controller.addError(http.RequestAbortedException(request.url));
                  unawaited(controller.close());
                }
              }),
            );
          }
          unawaited(
            Future<void>(() async {
              controller.add(List<int>.filled(64, 1));
              firstChunkSent.complete();
            }),
          );
          return http.StreamedResponse(controller.stream, 200, contentLength: 2048);
        }),
      );
      addTearDown(() async {
        if (!controller.isClosed) await controller.close();
        client.close();
      });

      const asset = AndroidUpdateAsset(
        name: 'ttplay-android-arm64-v8a.apk',
        downloadUrl: 'https://github.com/ttainet/TTPlay/releases/download/v2.0.0/ttplay-android-arm64-v8a.apk',
        size: 2048,
        isTarGz: false,
      );
      final abort = AbortController();

      final downloadFuture = UpdateService.downloadAndroidUpdate(
        asset: asset,
        version: '2.0.0',
        client: client,
        abort: abort,
        tempDirOverride: tempDir,
      );

      await firstChunkSent.future;
      abort.abort();

      await expectLater(
        downloadFuture,
        throwsA(isA<MediaServerHttpException>().having((e) => e.isCancellation, 'isCancellation', isTrue)),
      );

      final updatesDir = Directory('${tempDir.path}${Platform.pathSeparator}updates');
      expect(updatesDir.existsSync() ? updatesDir.listSync() : const [], isEmpty);
    });
  });

  for (final failure in failedResponses.entries) {
    test('startup ${failure.key} records cooldown before request and manual check bypasses it', () async {
      final prefs = await BaseSharedPreferencesService.sharedCache();
      final cooldownAtRequest = <String?>[];
      var requestCount = 0;
      final client = MediaServerHttpClient(
        client: MockClient((_) async {
          requestCount++;
          cooldownAtRequest.add(prefs.getString(lastCheckKey));
          return failure.value();
        }),
      );
      addTearDown(client.close);

      expect(await UpdateService.debugPerformUpdateCheck(respectCooldown: true, client: client), isNull);
      expect(requestCount, 1);
      expect(cooldownAtRequest.single, isNotNull);
      final recordedCooldown = prefs.getString(lastCheckKey);
      expect(recordedCooldown, cooldownAtRequest.single);
      expect(DateTime.now().difference(DateTime.parse(recordedCooldown!)), lessThan(const Duration(minutes: 1)));

      expect(await UpdateService.debugPerformUpdateCheck(respectCooldown: true, client: client), isNull);
      expect(requestCount, 1, reason: 'a simulated next launch must honor the failed attempt cooldown');

      expect(await UpdateService.debugPerformUpdateCheck(respectCooldown: false, client: client), isNull);
      expect(requestCount, 2, reason: 'an explicit manual check must bypass a recent startup cooldown');
      expect(
        prefs.getString(lastCheckKey),
        recordedCooldown,
        reason: 'manual checks must not rewrite startup cooldown',
      );
    });
  }
}
