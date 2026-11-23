import 'package:flutter/services.dart';

/// Native device bridge (TV detection, device name, performance signals,
/// process-exit diagnostics). Implemented per platform under `com.ttai.ttplay/device`.
const MethodChannel deviceChannel = MethodChannel('com.ttai.ttplay/device');
