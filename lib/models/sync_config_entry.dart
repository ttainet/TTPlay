enum SyncConfigScope {
  household('household'),
  member('member');

  const SyncConfigScope(this.wireName);

  final String wireName;

  static SyncConfigScope? fromWireName(String? raw) {
    final norm = raw?.trim().toLowerCase();
    for (final value in values) {
      if (value.wireName == norm) return value;
    }
    return null;
  }
}

abstract final class SyncConfigNamespaces {
  static const workSkip = 'work.skip';
  static const workTracks = 'work.tracks';
  static const workSpeed = 'work.speed';
  static const workSubOffset = 'work.sub_offset';
  static const appPrefs = 'app.prefs';
}

/// Typed schema descriptor for a synchronized configuration namespace stored in
/// `SyncConfigStore`. New features only need to register a new `SyncConfigSpec`.
class SyncConfigSpec<T> {
  const SyncConfigSpec({
    required this.scope,
    required this.namespace,
    required this.encode,
    required this.decode,
    this.isValid,
  });

  final SyncConfigScope scope;
  final String namespace;
  final Map<String, dynamic> Function(T value) encode;
  final T Function(Map<String, dynamic> json) decode;
  final bool Function(T value)? isValid;

  bool validate(T value) => isValid?.call(value) ?? true;
}

class SyncConfigChange {
  const SyncConfigChange({
    required this.scope,
    required this.namespace,
    required this.itemKey,
    this.workKey,
    this.value,
    required this.deleted,
    required this.updatedAt,
    required this.fromRemote,
  });

  final SyncConfigScope scope;
  final String namespace;
  final String itemKey;
  final String? workKey;
  final Map<String, dynamic>? value;
  final bool deleted;
  final int updatedAt;
  final bool fromRemote;
}
