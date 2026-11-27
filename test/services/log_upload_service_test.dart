import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:logger/logger.dart';
import 'package:ttplay/exceptions/media_server_exceptions.dart';
import 'package:ttplay/services/diagnostic_log_uploader.dart';
import 'package:ttplay/services/log_upload_service.dart';
import 'package:ttplay/utils/app_logger.dart';
import 'package:ttplay/utils/media_server_http_client.dart';

void main() {
  tearDown(() {
    logUploadBaseUrlOverride = null;
  });

  test('resolveLogUploadBaseUrl defaults to hardcoded media server and trims trailing slashes', () {
    expect(resolveLogUploadBaseUrl(), 'http://123.57.195.60:20001');

    logUploadBaseUrlOverride = 'http://192.168.1.50:8090///';
    expect(resolveLogUploadBaseUrl(), 'http://192.168.1.50:8090');

    logUploadBaseUrlOverride = '';
    expect(resolveLogUploadBaseUrl(), '');
  });

  test('uploadDiagnosticText sends content-type, user-agent, and encoded metadata headers', () async {
    logUploadBaseUrlOverride = 'http://192.168.1.10:8090/';
    http.Request? captured;

    final client = MediaServerHttpClient(
      client: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode(<String, dynamic>{'code': 0, 'id': 'k7m4p9x2'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(client.close);

    final id = await uploadDiagnosticText(
      'TTPlay v2.26.15\n---\n[INFO] hello',
      client: client,
      metadataHeaders: {
        'X-Client-Device': '客厅电视盒子',
        'X-Client-Platform': 'android',
        'X-Client-Is-TV': 'true',
      },
    );

    expect(id, 'k7m4p9x2');
    expect(captured, isNotNull);
    expect(captured!.url, Uri.parse('http://192.168.1.10:8090/logs'));
    expect(captured!.headers['Content-Type'] ?? captured!.headers['content-type'], startsWith('text/plain'));
    expect(captured!.headers['User-Agent'] ?? captured!.headers['user-agent'], 'TTPlay/DiagnosticUploader');
    expect(
      captured!.headers['X-Client-Device'] ?? captured!.headers['x-client-device'],
      Uri.encodeComponent('客厅电视盒子'),
    );
    expect(captured!.headers['X-Client-Platform'] ?? captured!.headers['x-client-platform'], 'android');
  });

  test('uploadDiagnosticText throws on HTTP error or missing id', () async {
    logUploadBaseUrlOverride = 'https://play.ttai.net';

    final errorClient = MediaServerHttpClient(
      client: MockClient((_) async => http.Response('{"code":500,"message":"boom"}', 500)),
    );
    addTearDown(errorClient.close);

    await expectLater(
      uploadDiagnosticText('payload', client: errorClient),
      throwsA(isA<MediaServerHttpException>()),
    );

    final badPayloadClient = MediaServerHttpClient(
      client: MockClient((_) async => http.Response('{"code":0}', 200)),
    );
    addTearDown(badPayloadClient.close);

    await expectLater(
      uploadDiagnosticText('payload', client: badPayloadClient),
      throwsFormatException,
    );
  });

  test('formatDiagnosticLogsPayload includes headers, reverses entry order, and respects maxBytes', () {
    final entries = [
      LogEntry(timestamp: DateTime(2026, 11, 27, 11, 0, 2), level: Level.warning, message: 'newest event'),
      LogEntry(timestamp: DateTime(2026, 11, 27, 11, 0, 1), level: Level.info, message: 'oldest event'),
    ];

    final full = formatDiagnosticLogsPayload(
      logs: entries,
      deviceHeader: 'TTPlay v2.26.21',
      extraHeader: 'Player: mpv (playing=true, buffering=false)',
    );
    expect(full, contains('TTPlay v2.26.21\n\nPlayer: mpv (playing=true, buffering=false)\n---\n'));
    expect(full.indexOf('oldest event'), lessThan(full.indexOf('newest event')));

    final trimmed = formatDiagnosticLogsPayload(
      logs: entries,
      deviceHeader: 'TTPlay v2.26.21',
      extraHeader: 'Player: mpv',
      maxBytes: 75,
    );
    expect(trimmed, startsWith('TTPlay v2.26.21\n\nPlayer: mpv\n---\n'));
    expect(trimmed, endsWith('newest event'));
    expect(trimmed, isNot(contains('oldest event')));
  });

  test('uploadCurrentDiagnosticLogs sends source header and extraHeader for in-player uploads', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    logUploadBaseUrlOverride = 'http://192.168.1.10:8090/';
    MemoryLogOutput.clearLogs();
    addTearDown(MemoryLogOutput.clearLogs);
    appLogger.i('Playback diag test sample');

    http.Request? captured;
    final client = MediaServerHttpClient(
      client: MockClient((request) async {
        captured = request;
        return http.Response(jsonEncode(<String, dynamic>{'id': 'vp99x1'}), 200);
      }),
    );
    addTearDown(client.close);

    final id = await uploadCurrentDiagnosticLogs(
      source: 'video_settings',
      extraHeader: 'Player: exoplayer (playing=true, buffering=true)',
      client: client,
    );

    expect(id, 'vp99x1');
    expect(captured, isNotNull);
    expect(captured!.headers['X-Client-Log-Source'] ?? captured!.headers['x-client-log-source'], 'video_settings');
    expect(captured!.body, contains('Player: exoplayer (playing=true, buffering=true)'));
    expect(captured!.body, contains('Playback diag test sample'));
  });
}
