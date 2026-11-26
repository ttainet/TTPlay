import 'dart:convert';

/// A scraped movie or series inside one media source. Item and file ids are
/// deliberately kept out so rebuilding the local index preserves watch state.
class WorkIdentity {
  const WorkIdentity({required this.source, required this.kind, required this.provider, required this.externalId});

  static const localSource = 'local-library';

  final String source;
  final String kind;
  final String provider;
  final String externalId;

  static WorkIdentity? resolve({
    required String source,
    required String kind,
    String? tmdbId,
    String? imdbId,
    String? bangumiId,
    String? doubanId,
  }) {
    if (source.trim().isEmpty || (kind != 'movie' && kind != 'show')) return null;
    final tmdb = int.tryParse(tmdbId?.trim() ?? '');
    if (tmdb != null && tmdb > 0) {
      return WorkIdentity(source: source, kind: kind, provider: 'tmdb', externalId: '$tmdb');
    }
    final imdb = imdbId?.trim().toLowerCase();
    if (imdb != null && RegExp(r'^tt\d+$').hasMatch(imdb)) {
      return WorkIdentity(source: source, kind: kind, provider: 'imdb', externalId: imdb);
    }
    final bgm = int.tryParse(bangumiId?.trim() ?? '');
    if (bgm != null && bgm > 0) {
      return WorkIdentity(source: source, kind: kind, provider: 'bangumi', externalId: '$bgm');
    }
    final douban = int.tryParse(doubanId?.trim() ?? '');
    if (douban != null && douban > 0) {
      return WorkIdentity(source: source, kind: kind, provider: 'douban', externalId: '$douban');
    }
    return null;
  }

  String get cloudWorkKey => '$provider:$kind:$externalId';

  static WorkIdentity? fromCloudWorkKey(String rawWorkKey, {String source = localSource}) {
    var normalized = rawWorkKey.trim();
    if (normalized.isEmpty) return null;
    if (normalized.startsWith('work:')) {
      final legacyParts = normalized.split(':');
      if (legacyParts.length >= 4) {
        final legacyKind = legacyParts[1].trim();
        final legacyProvider = legacyParts[2].trim();
        final legacyExtId = legacyParts.sublist(3).join(':').trim();
        if (legacyKind.isNotEmpty && legacyProvider.isNotEmpty && legacyExtId.isNotEmpty) {
          normalized = '$legacyProvider:$legacyKind:$legacyExtId';
        }
      }
    }
    final parts = normalized.split(':');
    if (parts.length != 3) return null;
    final provider = parts[0].trim().toLowerCase();
    final kind = parts[1].trim().toLowerCase();
    final extId = parts[2].trim();
    if (provider.isEmpty || kind.isEmpty || extId.isEmpty) return null;
    return resolve(
      source: source,
      kind: kind,
      tmdbId: provider == 'tmdb' ? extId : null,
      imdbId: provider == 'imdb' ? extId : null,
      bangumiId: provider == 'bangumi' ? extId : null,
      doubanId: provider == 'douban' ? extId : null,
    );
  }

  /// -1 denotes the whole work; season 0 remains available for specials.
  String stateKey({int season = -1, int episode = -1}) =>
      jsonEncode([source, kind, provider, externalId, season, episode]);
}
