import 'tmdb_provider.dart';

/// Helpers for converting between relative TMDB artwork paths (`/abc.jpg`)
/// and full image URLs at the desired resolution bucket.
abstract final class TmdbImageUrl {
  static final RegExp _tmdbFullImageRe = RegExp(
    r'^(https?://[^/]+(?:/[^?#]*)?/t/p/)([^/]+)(/[^?#]+)$',
    caseSensitive: false,
  );

  /// Returns whether [path] is a TMDB-style relative image path (`/abc.jpg`).
  static bool isRelativePath(String? path) {
    final s = path?.trim();
    return s != null && s.startsWith('/') && !s.startsWith('//');
  }

  /// Converts a full TMDB image URL into a mirror-independent relative path
  /// (`/foo.jpg`). Leaves already-relative paths, `mount:...` paths, and
  /// non-TMDB URLs (such as Bangumi URLs) unchanged.
  static String? toRelativePath(String? source) {
    final trimmed = source?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    if (trimmed.startsWith('mount:')) return trimmed;
    final match = _tmdbFullImageRe.firstMatch(trimmed);
    if (match != null) {
      return match.group(3);
    }
    return trimmed;
  }

  /// Replaces the `/t/p/<size>/` bucket in a full TMDB image URL with [size].
  /// Non-TMDB URLs are returned unchanged.
  static String replaceSize(String url, String size) {
    final trimmed = url.trim();
    final match = _tmdbFullImageRe.firstMatch(trimmed);
    if (match == null) return url;
    return '${match.group(1)}$size${match.group(3)}';
  }

  /// Picks a TMDB size bucket that covers [width] without upscaling low-res
  /// thumbnails, balancing scroll speed for small/poster slots and crispness
  /// for large posters and full-bleed backdrops (`cover: false`).
  static String sizeForWidth(int? width, {String? path, bool cover = true}) {
    final normalizedPath = path?.split('?').first.toLowerCase();
    if (normalizedPath != null && normalizedPath.endsWith('.png')) {
      if (width == null || width <= 500) return 'w500';
      return 'original';
    }
    if (width == null || width <= 0) {
      return cover ? 'w780' : 'w1280';
    }
    if (!cover) {
      if (width <= 780) return 'w780';
      if (width <= 1280) return 'w1280';
      return 'original';
    }
    if (width <= 185) return 'w185';
    if (width <= 240) return 'w342';
    if (width <= 500) return 'w500';
    if (width <= 780) return 'w780';
    if (width <= 1280) return 'w1280';
    return 'original';
  }

  /// Expands a relative TMDB path (`/foo.jpg`) against [imageBase] and [size].
  /// Non-leading-slash values (`http://...`, `https://...`, `mount:...`) pass
  /// through unchanged.
  static String resolve(String path, {String? imageBase, String size = 'w780'}) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return '';
    if (trimmed.startsWith('/') && !trimmed.startsWith('//')) {
      final base = TmdbProvider.normalizeBase(imageBase, TmdbProvider.defaultImageBase, defaultPath: '/t/p');
      return '$base/$size$trimmed';
    }
    return trimmed;
  }

  /// Rewrites or inserts the `size=` query parameter on a metadata artwork
  /// proxy URL (`/api/v1/metadata/artwork` or `/api/v1/public/metadata/artwork`)
  /// when its `src` is a relative TMDB path. Leaves non-proxy URLs and full
  /// external `src` URLs untouched.
  static String rewriteProxyArtworkSize(String url, {int? width, bool cover = true}) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    final isArtworkProxy =
        uri.path == '/api/v1/metadata/artwork' ||
        uri.path.endsWith('/api/v1/metadata/artwork') ||
        uri.path == '/api/v1/public/metadata/artwork' ||
        uri.path.endsWith('/api/v1/public/metadata/artwork');
    if (!isArtworkProxy) return url;

    final params = Map<String, String>.from(uri.queryParameters);
    final src = params['src']?.trim();
    if (!isRelativePath(src)) return url;

    final existingSize = params['size']?.trim() ?? '';
    if (width != null || existingSize.isEmpty) {
      params['size'] = sizeForWidth(width, path: src, cover: cover);
      return uri.replace(queryParameters: params).toString();
    }
    return url;
  }
}
