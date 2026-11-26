import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../utils/media_server_http_client.dart';
import 'ttplay_server.dart';

/// Default `media_library` server base URL for client diagnostic log uploads.
/// Hardcoded to the live media server for now; can still be overridden via
/// `--dart-define=TTPLAY_LOG_UPLOAD_URL=...` or `--dart-define=TTPLAY_RELAY_BASE_URL=...`.
const String defaultLogUploadBaseUrl = String.fromEnvironment(
  'TTPLAY_LOG_UPLOAD_URL',
  defaultValue: 'http://123.57.195.60:20001',
);

/// TTPlay server endpoint that returns a short, quotable Log ID.
const String logUploadEndpoint = '$defaultLogUploadBaseUrl/logs';

@visibleForTesting
String? logUploadBaseUrlOverride;

/// Resolves the target base URL for diagnostic log uploads without trailing `/`.
String resolveLogUploadBaseUrl() {
  final raw = logUploadBaseUrlOverride ??
      (ttplayServerBaseUrl.trim().isNotEmpty ? ttplayServerBaseUrl : defaultLogUploadBaseUrl);
  return raw.trim().replaceFirst(RegExp(r'/+$'), '');
}

String _encodeHeaderValue(String value) {
  final trimmed = value.trim();
  for (final codeUnit in trimmed.codeUnits) {
    if (codeUnit < 32 || codeUnit > 126) {
      return Uri.encodeComponent(trimmed);
    }
  }
  return trimmed;
}

/// The server's `/logs` accepts 1 MiB. The in-memory buffer intentionally remains
/// larger for local viewing and copying; uploads retain the device header and
/// newest log lines within this transport contract.
const int maxLogUploadBytes = 1 * 1024 * 1024;

/// Trims [logs] from the front so `header + logs` fits [maxBytes], keeping the
/// header intact and never splitting a UTF-8 sequence or a log line.
String constrainLogUploadPayload({required String header, required String logs, int maxBytes = maxLogUploadBytes}) {
  if (maxBytes <= 0) return '';

  final headerBytes = utf8.encode(header);
  if (headerBytes.length >= maxBytes) {
    var end = maxBytes;
    while (end > 0 && end < headerBytes.length && (headerBytes[end] & 0xC0) == 0x80) {
      end--;
    }
    return utf8.decode(headerBytes.sublist(0, end));
  }

  final logBytes = utf8.encode(logs);
  final availableLogBytes = maxBytes - headerBytes.length;
  if (logBytes.length <= availableLogBytes) return '$header$logs';

  var start = logBytes.length - availableLogBytes;
  while (start < logBytes.length && (logBytes[start] & 0xC0) == 0x80) {
    start++;
  }
  final nextLine = logBytes.indexOf(0x0A, start);
  if (nextLine >= 0 && nextLine + 1 < logBytes.length) {
    start = nextLine + 1;
  }
  return header + utf8.decode(logBytes.sublist(start));
}

/// Posts [payload] to the media server and returns the short Log ID.
///
/// Shared by Settings › Logs and by the startup failure screen, which cannot
/// reach Settings because the gate it needs has not completed (#1732).
///
/// [payload] must already be redacted and allowlisted by the caller; this
/// function performs no sanitisation of its own.
Future<String> uploadDiagnosticText(
  String payload, {
  MediaServerHttpClient? client,
  Map<String, String>? metadataHeaders,
}) async {
  final baseUrl = resolveLogUploadBaseUrl();
  if (baseUrl.isEmpty) {
    throw StateError('Diagnostic log upload relay is not configured');
  }
  final headers = <String, String>{
    'Content-Type': 'text/plain; charset=utf-8',
    'User-Agent': 'TTPlay/DiagnosticUploader',
  };
  if (metadataHeaders != null) {
    for (final entry in metadataHeaders.entries) {
      final key = entry.key.trim();
      final value = entry.value.trim();
      if (key.isEmpty || value.isEmpty) continue;
      headers[key] = _encodeHeaderValue(value);
    }
  }

  final response = await (client ?? httpClient).post(
    '$baseUrl/logs',
    body: payload,
    headers: headers,
  );
  throwIfHttpError(response);
  final data = response.data is String ? jsonDecode(response.data as String) : response.data;
  if (data is! Map<String, dynamic>) {
    throw const FormatException('Invalid diagnostic log upload response');
  }
  final id = data['id'];
  if (id is! String || id.trim().isEmpty) {
    throw const FormatException('Diagnostic log upload response missing id');
  }
  return id;
}
