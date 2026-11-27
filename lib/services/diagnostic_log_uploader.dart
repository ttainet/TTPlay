import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../i18n/strings.g.dart';
import '../main.dart' show gitCommit;
import '../utils/app_logger.dart';
import '../utils/formatters.dart';
import '../utils/media_server_http_client.dart';
import '../utils/platform_detector.dart';
import 'background_work_diagnostics_service.dart';
import 'device_performance.dart';
import 'log_upload_service.dart';
import 'startup_diagnostics.dart';
import 'video_decode_capabilities.dart';

/// Collected device and runtime diagnostics attached to diagnostic log uploads
/// and shown at the top of the system Logs screen.
class DiagnosticDeviceSnapshot {
  const DiagnosticDeviceSnapshot({
    required this.headerText,
    required this.deviceName,
    required this.platformName,
    required this.osVersion,
    required this.appVersion,
    required this.isTv,
  });

  final String headerText;
  final String deviceName;
  final String platformName;
  final String osVersion;
  final String appVersion;
  final bool isTv;

  Map<String, String> toMetadataHeaders({required String source}) => {
    if (deviceName.isNotEmpty) 'X-Client-Device': deviceName,
    if (platformName.isNotEmpty) 'X-Client-Platform': platformName,
    if (osVersion.isNotEmpty) 'X-Client-OS': osVersion,
    if (appVersion.isNotEmpty) 'X-Client-Version': appVersion,
    'X-Client-Is-TV': isTv ? 'true' : 'false',
    'X-Client-Log-Source': source,
  };
}

/// Collects device, OS, decoder, and display capability summary for log headers.
Future<DiagnosticDeviceSnapshot> collectDiagnosticDeviceSnapshot({DeviceInfoPlugin? deviceInfoPlugin}) async {
  final deviceInfo = deviceInfoPlugin ?? DeviceInfoPlugin();
  final buffer = StringBuffer();
  final commitSuffix = gitCommit.isNotEmpty ? ' ${gitCommit.substring(0, 7)}' : '';
  var appVersion = '';
  try {
    final packageInfo = await PackageInfo.fromPlatform();
    appVersion = '${packageInfo.version} (${packageInfo.buildNumber})$commitSuffix';
  } catch (_) {
    appVersion = commitSuffix.trim().isEmpty ? 'unknown' : commitSuffix.trim();
  }
  buffer.writeln('${t.app.title} v$appVersion');

  var platformName = Platform.operatingSystem;
  var osVersion = '';
  var deviceName = '';
  var isTv = false;

  try {
    if (Platform.isAndroid) {
      final info = await deviceInfo.androidInfo;
      platformName = 'android';
      osVersion = 'Android ${info.version.release} (API ${info.version.sdkInt})';
      deviceName = '${info.manufacturer} ${info.model}'.trim();
      buffer.writeln(osVersion);
      buffer.writeln(deviceName);
      if (PlatformDetector.isTV()) {
        isTv = true;
        final reasons = TvDetectionService.tvDetectionReasonsSync();
        final suffix = reasons.isEmpty ? '' : ' (${reasons.join(', ')})';
        buffer.writeln('TV mode: yes$suffix');
      }
      // Renderer + effects tier turn "did the reduced tier engage on this
      // device" into something answerable from any uploaded log (#1349).
      String renderer;
      try {
        renderer = await const MethodChannel('com.ttai.ttplay/theme').invokeMethod<String>('getRenderer') ?? 'unknown';
      } catch (_) {
        renderer = 'unknown';
      }
      buffer.writeln('Renderer: $renderer');
      final backgroundWork = BackgroundWorkDiagnosticsService.instance;
      await backgroundWork.refresh();
      buffer.writeln('Background: ${backgroundWork.describeSync()}');
    } else if (Platform.isIOS) {
      final info = await deviceInfo.iosInfo;
      platformName = 'ios';
      osVersion = 'iOS ${info.systemVersion}';
      deviceName = info.utsname.machine;
      buffer.writeln(osVersion);
      buffer.writeln(deviceName);
    } else if (Platform.isMacOS) {
      final info = await deviceInfo.macOsInfo;
      platformName = 'macos';
      osVersion = 'macOS ${info.osRelease}';
      deviceName = info.model;
      buffer.writeln(osVersion);
      buffer.writeln(deviceName);
    } else if (Platform.isWindows) {
      platformName = 'windows';
      osVersion = 'Windows ${Platform.operatingSystemVersion}';
      deviceName = Platform.localHostname;
      buffer.writeln(osVersion);
      buffer.writeln(deviceName);
    } else if (Platform.isLinux) {
      final info = await deviceInfo.linuxInfo;
      platformName = 'linux';
      osVersion = 'Linux ${info.versionId ?? info.id}';
      deviceName = info.name;
      buffer.writeln(osVersion);
    }
  } catch (_) {
    // Headless unit tests may run without platform channels wired up.
  }

  buffer.writeln('Effects: ${DevicePerformance.describeSync()}');
  buffer.writeln('Display: ${DevicePerformance.describeDisplay()}');
  buffer.writeln('Video decoders: ${VideoDecodeCapabilities.describeSync()}');

  return DiagnosticDeviceSnapshot(
    headerText: buffer.toString().trimRight(),
    deviceName: deviceName,
    platformName: platformName,
    osVersion: osVersion,
    appVersion: appVersion,
    isTv: isTv,
  );
}

String _formatEntryTime(DateTime time) {
  final hour = padNumber(time.hour, 2);
  final minute = padNumber(time.minute, 2);
  final second = padNumber(time.second, 2);
  final millisecond = padNumber(time.millisecond, 3);
  return '$hour:$minute:$second.$millisecond';
}

/// Formats diagnostic headers and log entries newest-last for upload or clipboard copy.
String formatDiagnosticLogsPayload({
  required List<LogEntry> logs,
  String deviceHeader = '',
  String? extraHeader,
  StartupFailureRecord? startupFailure,
  int? maxBytes,
}) {
  final sections = <String>[
    if (deviceHeader.trim().isNotEmpty) deviceHeader.trimRight(),
    if (extraHeader != null && extraHeader.trim().isNotEmpty) extraHeader.trim(),
    ?startupFailure?.describe(),
  ];
  final header = sections.isEmpty ? '' : '${sections.join('\n\n')}\n---\n';

  final body = StringBuffer();
  var isFirst = true;
  for (final log in logs.reversed) {
    if (!isFirst) {
      body.write('\n');
    }
    isFirst = false;

    body.write('[${_formatEntryTime(log.timestamp)}] [${log.level.name.toUpperCase()}] ${log.message}');
    if (log.error != null) {
      body.write('\nError: ${log.error}');
    }
    if (log.stackTrace != null) {
      body.write('\nStack trace:\n${log.stackTrace}');
    }
  }

  final logText = body.toString();
  return maxBytes == null
      ? '$header$logText'
      : constrainLogUploadPayload(header: header, logs: logText, maxBytes: maxBytes);
}

/// Collects device info and current memory logs, constrains to [maxLogUploadBytes],
/// and uploads them to the configured diagnostic log relay.
Future<String> uploadCurrentDiagnosticLogs({
  required String source,
  String? extraHeader,
  MediaServerHttpClient? client,
  DeviceInfoPlugin? deviceInfoPlugin,
}) async {
  final snapshot = await collectDiagnosticDeviceSnapshot(deviceInfoPlugin: deviceInfoPlugin);
  final payload = formatDiagnosticLogsPayload(
    logs: MemoryLogOutput.getLogs(),
    deviceHeader: snapshot.headerText,
    extraHeader: extraHeader,
    startupFailure: StartupDiagnosticsStore.pending,
    maxBytes: maxLogUploadBytes,
  );
  return uploadDiagnosticText(
    payload,
    client: client,
    metadataHeaders: snapshot.toMetadataHeaders(source: source),
  );
}
