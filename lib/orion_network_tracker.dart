/// OrionNetworkTracker
/// Tracks network requests per screen (used by OrionDioInterceptor).
/// Make sure to always call `OrionNetworkTracker.setCurrentScreen(screenName)`
/// when screen changes (OrionManualTracker or Router handles this).

import 'orion_flutter.dart';
import 'orion_logger.dart';

class OrionNetworkTracker {
  static final Map<String, List<Map<String, dynamic>>> _screenRequests = {};
  static String? currentScreenName;

  /// 🛠️ Configurable max number of requests per screen (default: 150)
  static int maxRequestsPerScreen = 150;

  /// Set the current screen name (e.g., in RouteObserver or manual tracker)
  static void setCurrentScreen(String screenName) {
    if (!OrionFlutter.isSupported) return;
    currentScreenName = screenName;
  }

  /// Add a request associated with a specific screen
  /// - Requests beyond [maxRequestsPerScreen] are ignored (not removed or replaced)
  /// - URLs are capped: path kept, query string limited to 25 characters
  static void addRequest(String screen, Map<String, dynamic> request) {
    if (!OrionFlutter.isSupported) return;

    final list = _screenRequests.putIfAbsent(screen, () => []);

    if (list.length >= maxRequestsPerScreen) {
      orionPrint(
          "⚠️ OrionNetworkTracker: max request limit ($maxRequestsPerScreen) reached for screen: $screen. Skipping.");
      return;
    }

    // 🧹 Cap long URLs (keep path, limit query string to 25 chars)
    if (request.containsKey("url") && request["url"] is String) {
      request["url"] = _capUrl(request["url"]);
    }

    list.add(request);
  }

  /// Cap URLs by keeping domain & path and truncating query string to max 50 chars
  static String _capUrl(String fullUrl) {
    try {
      final uri = Uri.tryParse(fullUrl);
      if (uri == null) return fullUrl;

      final base = uri.hasAuthority
          ? '${uri.scheme}://${uri.host}${uri.path}'
          : uri.path.isNotEmpty
          ? uri.path
          : fullUrl;

      final query = uri.query;
      if (query.isEmpty) return base;

      final cappedQuery =
      query.length > 50 ? query.substring(0, 50) : query;

      return '$base?$cappedQuery';
    } catch (_) {
      return fullUrl;
    }
  }


  /// Add request to the currently active screen (if set)
  static void addRequestToCurrentScreen(Map<String, dynamic> request) {
    if (!OrionFlutter.isSupported || currentScreenName == null) return;
    addRequest(currentScreenName!, request);
  }

  /// Consume and return all requests for a screen (clears after return)
  static List<Map<String, dynamic>> consumeRequestsForScreen(String screen) {
    if (!OrionFlutter.isSupported) return [];

    final requests = _screenRequests.remove(screen);
    return requests ?? [];
  }

  /// Clear all stored requests (optional cleanup)
  static void clearAll() {
    if (!OrionFlutter.isSupported) return;
    _screenRequests.clear();
  }

  /// Clear requests for a specific screen (optional)
  static void clearRequestsForScreen(String screen) {
    if (!OrionFlutter.isSupported) return;
    _screenRequests.remove(screen);
  }

  /// Get current request count for a given screen (for debugging or diagnostics)
  static int getRequestCount(String screen) {
    if (!OrionFlutter.isSupported) return 0;
    return _screenRequests[screen]?.length ?? 0;
  }

  /// Get all stored screens being tracked (useful for debugging)
  static List<String> getTrackedScreens() {
    if (!OrionFlutter.isSupported) return [];
    return _screenRequests.keys.toList();
  }
}