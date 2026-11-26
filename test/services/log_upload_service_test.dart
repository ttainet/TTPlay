import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ttplay/exceptions/media_server_exceptions.dart';
import 'package:ttplay/services/log_upload_service.dart';
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
}
