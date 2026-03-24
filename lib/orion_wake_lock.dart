import 'package:flutter/services.dart';

// Print helper (matches orion_flutter.dart pattern)
void _orionWakeLockPrint(String message) {
  // Use assert to only print in debug mode, avoiding production log spam
  assert(() {
    print('OrionWakeLock: $message');
    return true;
  }());
}

/// Wake lock types (matching Android PowerManager constants)
class OrionWakeLockType {
  /// Partial wake lock - keeps CPU running, screen can turn off
  /// This is the most common type and what Android Vitals tracks
  static const int partial = 1;

  /// Proximity screen off wake lock - turns screen off when near object
  static const int proximityScreenOff = 32;
}

/// OrionWakeLock - Tracked wake lock for Flutter apps
///
/// Automatically tracks wake lock acquisition and release for Orion metrics.
/// Use this instead of native wake lock plugins to get automatic tracking.
///
/// Usage:
/// ```dart
/// final wakeLock = OrionWakeLock('MyApp:SyncLock');
///
/// // Acquire (keeps CPU running)
/// await wakeLock.acquire();
///
/// // Do work...
/// await performBackgroundSync();
///
/// // Release (IMPORTANT - always release!)
/// await wakeLock.release();
///
/// // Or with timeout (auto-releases after timeout)
/// await wakeLock.acquire(timeoutMs: 30000); // 30 seconds max
/// ```
///
/// Best Practices:
/// - Always release wake locks as soon as possible
/// - Use timeouts to prevent stuck wake locks
/// - Prefer WorkManager/JobScheduler for background work
/// - Wake locks held > 60 seconds are flagged as "stuck"
class OrionWakeLock {
  static const MethodChannel _channel = MethodChannel('orion_flutter');

  /// The tag identifying this wake lock (e.g., "MyApp:SyncLock")
  final String tag;

  /// The wake lock type (default: partial)
  final int type;

  /// Whether the wake lock is currently held (local tracking)
  bool _isHeld = false;

  /// Creates a new tracked wake lock.
  ///
  /// [tag] should be in format "AppName:Purpose" for clarity in metrics
  /// [type] defaults to partial wake lock (most common)
  OrionWakeLock(this.tag, {this.type = OrionWakeLockType.partial});

  /// Acquire the wake lock.
  ///
  /// Keeps the CPU running even when the screen is off.
  /// IMPORTANT: Always call [release] when done!
  ///
  /// [timeoutMs] Optional timeout in milliseconds. The wake lock will
  /// automatically release after this time. Recommended for safety.
  ///
  /// Returns true if acquisition was successful, false if permission missing.
  ///
  /// Note: If WAKE_LOCK permission is not granted, this will return false
  /// but won't crash. The tracking will still work, so you can see the
  /// intent to use wake locks in your metrics.
  Future<bool> acquire({int? timeoutMs}) async {
    try {
      if (_isHeld) {
        _orionWakeLockPrint('⚠️ Wake lock "$tag" already held');
        return true;
      }

      // ✅ Non-blocking call with timeout to prevent ANR
      final result = await _channel.invokeMethod('wakeLockAcquire', {
        'tag': tag,
        'type': type,
        'timeoutMs': timeoutMs,
      }).timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          _orionWakeLockPrint('⚠️ Wake lock acquire timed out for "$tag"');
          return false;
        },
      );

      _isHeld = result == true;

      if (_isHeld) {
        final timeoutStr = timeoutMs != null ? ' (timeout: ${timeoutMs}ms)' : '';
        _orionWakeLockPrint('🔒 Acquired "$tag"$timeoutStr');
      } else {
        // Permission likely missing - warn but don't fail
        _orionWakeLockPrint('⚠️ Wake lock "$tag" not acquired (permission missing?)');
        _orionWakeLockPrint('💡 Add WAKE_LOCK permission or use manual tracking');
      }

      return _isHeld;
    } catch (e) {
      _orionWakeLockPrint('❌ Error acquiring "$tag": $e');
      return false;
    }
  }

  /// Release the wake lock.
  ///
  /// It is very important to call this as soon as possible to avoid
  /// draining the device's battery excessively.
  ///
  /// Returns true if release was successful.
  Future<bool> release() async {
    try {
      if (!_isHeld) {
        _orionWakeLockPrint('⚠️ Wake lock "$tag" not held, skipping release');
        return true;
      }

      // ✅ Non-blocking call with timeout to prevent ANR
      final result = await _channel.invokeMethod('wakeLockRelease', {
        'tag': tag,
      }).timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          _orionWakeLockPrint('⚠️ Wake lock release timed out for "$tag"');
          return false;
        },
      );

      _isHeld = false;
      _orionWakeLockPrint('🔓 Released "$tag"');

      return result == true;
    } catch (e) {
      _orionWakeLockPrint('❌ Error releasing "$tag": $e');
      // Mark as not held even on error to prevent leaks
      _isHeld = false;
      return false;
    }
  }

  /// Check if the wake lock is currently held.
  bool get isHeld => _isHeld;

  /// Execute a function while holding the wake lock.
  ///
  /// Automatically acquires before and releases after the function,
  /// even if an exception occurs.
  ///
  /// ```dart
  /// final result = await wakeLock.withWakeLock(() async {
  ///   return await performBackgroundWork();
  /// });
  /// ```
  Future<T> withWakeLock<T>(Future<T> Function() action, {int? timeoutMs}) async {
    await acquire(timeoutMs: timeoutMs);
    try {
      return await action();
    } finally {
      await release();
    }
  }

  @override
  String toString() => 'OrionWakeLock(tag: $tag, isHeld: $_isHeld)';
}

/// Static helper class for wake lock tracking
///
/// Provides manual tracking API and configuration.
/// Manual tracking does NOT require WAKE_LOCK permission.
class OrionWakeLockTracker {
  static const MethodChannel _channel = MethodChannel('orion_flutter');

  OrionWakeLockTracker._(); // Private constructor

  /// Configure the stuck threshold.
  ///
  /// Wake locks held longer than this are flagged as "stuck" in metrics.
  /// Default is 60 seconds (60000 ms).
  ///
  /// ```dart
  /// // Flag wake locks held > 2 minutes as stuck
  /// await OrionWakeLockTracker.setStuckThreshold(120000);
  /// ```
  static Future<void> setStuckThreshold(int thresholdMs) async {
    try {
      await _channel.invokeMethod('wakeLockSetStuckThreshold', {
        'thresholdMs': thresholdMs,
      }).timeout(const Duration(seconds: 2), onTimeout: () => null);
      _orionWakeLockPrint('⚙️ Stuck threshold set to ${thresholdMs}ms');
    } catch (e) {
      _orionWakeLockPrint('Error setting stuck threshold: $e');
    }
  }

  /// Manual tracking - record wake lock acquisition.
  ///
  /// Use this when you can't use [OrionWakeLock] wrapper
  /// (e.g., using a third-party wake lock plugin).
  ///
  /// NO PERMISSION REQUIRED - this just records timing data.
  ///
  /// ```dart
  /// // Using native wake lock plugin
  /// OrionWakeLockTracker.trackAcquire('MyApp:Sync');
  /// await WakelockPlus.enable();
  /// // ... do work ...
  /// await WakelockPlus.disable();
  /// OrionWakeLockTracker.trackRelease('MyApp:Sync');
  /// ```
  static Future<void> trackAcquire(
      String tag, {
        int type = OrionWakeLockType.partial,
        int? timeoutMs,
      }) async {
    try {
      // ✅ Fire-and-forget to avoid blocking
      _channel.invokeMethod('wakeLockTrackAcquire', {
        'tag': tag,
        'type': type,
        'timeoutMs': timeoutMs,
      }).timeout(const Duration(seconds: 2), onTimeout: () => null);
      _orionWakeLockPrint('📊 Tracked acquire "$tag"');
    } catch (e) {
      _orionWakeLockPrint('Error tracking acquire: $e');
    }
  }

  /// Manual tracking - record wake lock release.
  ///
  /// Use this when you can't use [OrionWakeLock] wrapper.
  /// The tag must match the one used in [trackAcquire].
  ///
  /// NO PERMISSION REQUIRED - this just records timing data.
  static Future<void> trackRelease(String tag) async {
    try {
      // ✅ Fire-and-forget to avoid blocking
      _channel.invokeMethod('wakeLockTrackRelease', {
        'tag': tag,
      }).timeout(const Duration(seconds: 2), onTimeout: () => null);
      _orionWakeLockPrint('📊 Tracked release "$tag"');
    } catch (e) {
      _orionWakeLockPrint('Error tracking release: $e');
    }
  }

  /// Get the number of currently active (held) wake locks.
  static Future<int> getActiveCount() async {
    try {
      final result = await _channel.invokeMethod('wakeLockGetActiveCount')
          .timeout(const Duration(seconds: 2), onTimeout: () => 0);
      return result as int? ?? 0;
    } catch (e) {
      _orionWakeLockPrint('Error getting active count: $e');
      return 0;
    }
  }

  /// Check if a specific wake lock is currently held.
  static Future<bool> isHeld(String tag) async {
    try {
      final result = await _channel.invokeMethod('wakeLockIsHeld', {
        'tag': tag,
      }).timeout(const Duration(seconds: 2), onTimeout: () => false);
      return result as bool? ?? false;
    } catch (e) {
      _orionWakeLockPrint('Error checking isHeld: $e');
      return false;
    }
  }

  /// Get list of currently active wake lock tags.
  static Future<List<String>> getActiveTags() async {
    try {
      final result = await _channel.invokeMethod('wakeLockGetActiveTags')
          .timeout(const Duration(seconds: 2), onTimeout: () => <String>[]);
      if (result is List) {
        return result.cast<String>();
      }
      return [];
    } catch (e) {
      _orionWakeLockPrint('Error getting active tags: $e');
      return [];
    }
  }

  /// Log current wake lock state for debugging.
  static Future<void> logState() async {
    try {
      _channel.invokeMethod('wakeLockLogState')
          .timeout(const Duration(seconds: 2), onTimeout: () => null);
    } catch (e) {
      _orionWakeLockPrint('Error logging state: $e');
    }
  }
}