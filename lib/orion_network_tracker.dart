/// OrionNetworkTracker
/// Tracks network requests per screen (used by OrionDioInterceptor).
/// Make sure to always call `OrionNetworkTracker.setCurrentScreen(screenName)`
/// when screen changes (OrionManualTracker or Router handles this).

import 'orion_flutter.dart';

class OrionNetworkTracker {
  static final Map<String, List<Map<String, dynamic>>> _screenRequests = {};
  static String? currentScreenName;

  /// Set the current screen name (e.g., in RouteObserver or manual tracker)
  static void setCurrentScreen(String screenName) {
    if (!OrionFlutter.isAndroid) return;
    currentScreenName = screenName;
  }

  /// Add a request associated with a screen
  static void addRequest(String screen, Map<String, dynamic> request) {
    if (!OrionFlutter.isAndroid) return;

    if (!_screenRequests.containsKey(screen)) {
      _screenRequests[screen] = [];
    }
    _screenRequests[screen]!.add(request);
  }

  /// Consume and return requests for a screen (clears after return)
  static List<Map<String, dynamic>> consumeRequestsForScreen(String screen) {
    if (!OrionFlutter.isAndroid) return [];

    final requests = _screenRequests.remove(screen);
    return requests ?? [];
  }

  /// Clear all stored requests (optional cleanup)
  static void clearAll() {
    if (!OrionFlutter.isAndroid) return;

    _screenRequests.clear();
  }
}