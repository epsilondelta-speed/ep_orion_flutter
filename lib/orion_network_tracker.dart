/// OrionNetworkTracker
/// Tracks network requests per screen (used by OrionDioInterceptor and OrionHttpOverrides).

import 'orion_flutter.dart';
import 'orion_logger.dart';
import 'orion_sampling_manager.dart';

class OrionNetworkTracker {
  static final Map<String, List<Map<String, dynamic>>> _screenRequests = {};
  static String? currentScreenName;

  /// Configurable max number of requests per screen (default: 50)
  static int maxRequestsPerScreen = 50;

  /// Max number of screens retained at once (DART-02).
  ///
  /// The per-screen request cap bounded each bucket but nothing bounded the
  /// number of buckets. Entries are only freed by [consumeRequestsForScreen],
  /// which runs from `_ScreenMetrics.send()` — so any screen that never
  /// reaches a beacon kept its bucket for the life of the process:
  ///
  ///   * dialog and bottom-sheet routes, which are not `PageRoute`s
  ///   * screens inside a nested Navigator with no `OrionScreenTracker`
  ///   * the `'UnknownScreen'` fallback used by [OrionHttpOverrides] and
  ///     [OrionDioInterceptor] before the first route is observed
  ///
  /// Each stranded bucket holds up to [maxRequestsPerScreen] request maps
  /// carrying URL, content type and error strings, so the ceiling was
  /// unbounded × 50 maps.
  ///
  /// Same bound and same eviction as `OrionRageClickTracker._maxScreens`,
  /// which already solved this — Dart maps preserve insertion order, so
  /// `keys.first` is the oldest key.
  static const int _maxScreens = 50;

  // ── SDK-internal URL prefixes that must never appear in client beacons ────
  // The sampling CDN fetch and the beacon endpoint itself are internal to the
  // SDK — including them in the network waterfall would be misleading and would
  // waste beacon payload space.
  static const List<String> _sdkInternalPrefixes = [
    'https://cdn.epsilondelta.co/orion/',   // sampling config CDN
    'https://www.ed-sys.net/oriData',       // beacon endpoint
  ];

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Set the current screen name (e.g. in RouteObserver or manual tracker).
  static void setCurrentScreen(String screenName) {
    try {
      if (!OrionFlutter.isSupported) return;
      currentScreenName = screenName;
    } catch (_) {}
  }

  /// Add a request associated with a specific screen.
  ///
  /// No-ops when:
  ///   - Platform is not supported
  ///   - Sampling kill-switch is active (effectivePercent == 0)
  ///   - URL belongs to the Orion SDK itself
  ///   - maxRequestsPerScreen limit is reached
  static void addRequest(String screen, Map<String, dynamic> request) {
    try {
      if (!OrionFlutter.isSupported) return;

      // ✅ Sampling kill-switch: stop collecting when tracking is disabled.
      if (!SamplingManager.instance.isTrackingEnabled) return;

      // ✅ Filter out SDK-internal URLs so they never appear in client beacons.
      final url = request['url'] as String? ?? '';
      if (_isSdkInternalUrl(url)) return;

      // ✅ DART-02: bound the number of screens, not just the requests within
      //    one. Checked before putIfAbsent so the eviction only fires for a
      //    genuinely new key — an existing screen must never evict anything.
      if (!_screenRequests.containsKey(screen) &&
          _screenRequests.length >= _maxScreens) {
        final oldestKey = _screenRequests.keys.first;
        _screenRequests.remove(oldestKey);
        orionPrint('⚠️ OrionNetworkTracker: max screens limit ($_maxScreens) '
            'reached, evicted: $oldestKey');
      }

      final list = _screenRequests.putIfAbsent(screen, () => []);

      if (list.length >= maxRequestsPerScreen) {
        orionPrint('⚠️ OrionNetworkTracker: max limit ($maxRequestsPerScreen) '
            'reached for screen: $screen. Skipping.');
        return;
      }

      // Cap long URLs — keep domain + path, limit query string to 50 chars.
      if (url.isNotEmpty) {
        request['url'] = _capUrl(url);
      }

      list.add(request);
    } catch (e) {
      orionPrint('⚠️ OrionNetworkTracker: addRequest error (ignored): $e');
    }
  }

  /// Add a request to the currently active screen (if set).
  static void addRequestToCurrentScreen(Map<String, dynamic> request) {
    try {
      if (!OrionFlutter.isSupported || currentScreenName == null) return;
      addRequest(currentScreenName!, request);
    } catch (e) {
      orionPrint('⚠️ OrionNetworkTracker: addRequestToCurrentScreen error (ignored): $e');
    }
  }

  /// Consume and return all requests for a screen (clears after return).
  static List<Map<String, dynamic>> consumeRequestsForScreen(String screen) {
    try {
      if (!OrionFlutter.isSupported) return [];
      return _screenRequests.remove(screen) ?? [];
    } catch (e) {
      orionPrint('⚠️ OrionNetworkTracker: consumeRequestsForScreen error: $e');
      return [];
    }
  }

  static void clearAll() {
    try {
      if (!OrionFlutter.isSupported) return;
      _screenRequests.clear();
    } catch (_) {}
  }

  static void clearRequestsForScreen(String screen) {
    try {
      if (!OrionFlutter.isSupported) return;
      _screenRequests.remove(screen);
    } catch (_) {}
  }

  static int getRequestCount(String screen) {
    try {
      if (!OrionFlutter.isSupported) return 0;
      return _screenRequests[screen]?.length ?? 0;
    } catch (_) {
      return 0;
    }
  }

  static List<String> getTrackedScreens() {
    try {
      if (!OrionFlutter.isSupported) return [];
      return _screenRequests.keys.toList();
    } catch (_) {
      return [];
    }
  }

  // ── Private helpers ───────────────────────────────────────────────────────

  static bool _isSdkInternalUrl(String url) {
    if (url.isEmpty) return false;
    for (final prefix in _sdkInternalPrefixes) {
      if (url.startsWith(prefix)) return true;
    }
    return false;
  }

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

      final cappedQuery = query.length > 50 ? query.substring(0, 50) : query;
      return '$base?$cappedQuery';
    } catch (_) {
      return fullUrl;
    }
  }
}
