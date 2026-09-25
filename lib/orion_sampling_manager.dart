import 'dart:async';
import 'dart:math';
import 'package:flutter/services.dart';
import 'orion_logger.dart';

/// SamplingManager — Remote runtime configuration for Orion Flutter SDK.
///
/// Source: https://cdn.epsilondelta.co/orion/confOriSamplV2.json
///
/// V2 schema (a single CDN file controls multiple runtime knobs):
/// {
///   "s":   1,         // global sampling percent
///   "sa":  false,     // global show-analytics flag
///   "crm": 15,        // global config-refresh interval (minutes)
///   "cv":  "1.0",     // file version (global only — no resolution chain)
///   "c": {
///     "0002317": {
///       "s":   100,
///       "sa":  false,
///       "crm": 15,
///       "p": {
///         "0001": { "s": 100, "sa": false, "crm": 15 }
///       }
///     }
///   }
/// }
///
/// Resolution priority (first match wins) for s, sa, crm:
///   1. c[cid].p[pid].FIELD  → product-level override (most specific)
///   2. c[cid].FIELD         → company-level default
///   3. FIELD                → global default
///   4. hardcoded default    → fallback if CDN unreachable
///
/// `cv` is global-only — no resolution chain.
///
/// Behavioural fields exposed to consumers:
///   - getEffectivePercent()    → int 0..100
///   - showAnalytics            → bool
///   - shouldFilterAnalytics    → !showAnalytics (convenience)
///   - configRefreshMin         → int (clamped to >= 1)
///   - configVersion            → String
///   - getConfigSnapshot()      → {s, sa, crm, cv} for the `cf` beacon field
///
/// V1 → V2 migration notes:
///   - URL changed from confOriSampl.json to confOriSamplV2.json
///   - Field renames: top-level d → s; c[cid].d → c[cid].s
///   - Product-level c[cid].p[pid] was an int, now an object with `.s`
///   - V1 had only sampling. V2 also carries sa, crm, cv.
///
/// Type-permissive parsing (Fix #11 carried forward): the JSON parser accepts
/// num/int/double/string for sampling values to mirror Kotlin's optInt()
/// coercion behaviour. Same CDN config must resolve identically on both
/// platforms.
class SamplingManager {

  // ── Singleton ─────────────────────────────────────────────────────────────
  static final SamplingManager instance = SamplingManager._();
  SamplingManager._();

  // ── Constants ─────────────────────────────────────────────────────────────
  // The CDN URL and its timeout moved to the native layer in 1.2.39 — Dart no
  // longer makes this request. See _fetchConfig().
  static const MethodChannel _channel = MethodChannel('orion_flutter');

  // How soon to re-ask native for a config it has not resolved yet. Dart's
  // initialize() runs BEFORE initializeEdOrion reaches native, so the first
  // pull always arrives early; these local retries cover the window until
  // native's own fetch lands, without waiting a full crm.
  static const List<Duration> _earlyRetries = <Duration>[
    Duration(seconds: 1),
    Duration(seconds: 3),
    Duration(seconds: 8),
    Duration(seconds: 20),
  ];

  // Defaults (used as fail-open fallbacks if CDN unreachable)
  // _defaultPercent removed in 1.2.39 — the 100% fail-open now lives in the
  // native layer, which owns resolution. Dart's fallback while no config has
  // arrived is localSampleRate, applied in getEffectivePercent().
  static const bool    _defaultShowAnalytics = false;
  static const int     _defaultRefreshMin    = 15;
  static const int     _minRefreshMin        = 1;
  static const String  _defaultConfigVersion = '1.0';

  // ── State ─────────────────────────────────────────────────────────────────
  // cid/pid are forwarded to native, which resolves c[cid].p[pid]. Dart keeps
  // _cid only to know whether initialize() has run (see _scheduleEarlyRetries).
  String  _cid             = '';
  double  _localSampleRate = 1.0;

  // Remote-resolved values. Null until first successful fetch.
  int?    _remotePercent;
  bool?   _remoteShowAnalytics;
  int?    _remoteRefreshMin;
  String? _remoteConfigVersion;

  bool    _configLoaded    = false;
  bool    _firstBeaconSent = false;
  Timer?  _refreshTimer;

  // The interval currently driving _refreshTimer. Used to detect crm changes.
  int     _activeRefreshMin = _defaultRefreshMin;

  // Time since the last SUCCESSFUL CDN fetch, used by resumeRefresh() to decide
  // whether the config is stale enough to warrant an immediate re-fetch.
  //
  // A Stopwatch rather than DateTime.now(): Stopwatch is monotonic, so an NTP
  // correction or a user changing the device clock mid-session cannot make the
  // config look arbitrarily stale or fresh. Same reasoning as the 1.2.32 move of
  // iOS hang timing off the wall clock.
  final Stopwatch _sinceLastFetch = Stopwatch();

  final Random _random = Random();

  // ── Init ──────────────────────────────────────────────────────────────────

  void initialize(String cid, String pid, {double sampleRate = 1.0}) {
    try {
      _cid             = cid;
      _localSampleRate = sampleRate.clamp(0.0, 1.0);

      // Reset all remote-resolved state on (re-)init.
      _remotePercent       = null;
      _remoteShowAnalytics = null;
      _remoteRefreshMin    = null;
      _remoteConfigVersion = null;
      _configLoaded        = false;
      _firstBeaconSent     = false;

      // Start with the default refresh cadence; updated after the first fetch
      // completes (and again any time crm changes).
      _activeRefreshMin = _defaultRefreshMin;
      _scheduleRefresh(_activeRefreshMin);

      // Ask native immediately. It will usually answer `loaded: false` on this
      // first call — initializeEdOrion has not reached native yet — so back it
      // with a short local retry ladder rather than waiting a whole crm.
      _fetchConfig();
      _scheduleEarlyRetries();

      orionPrint('SamplingManager: initialized '
          'cid=$cid pid=$pid localRate=${(sampleRate * 100).round()}%');
    } catch (e) {
      orionPrint('SamplingManager: initialize error — $e');
    }
  }

  // ── Gates (unchanged from V1) ─────────────────────────────────────────────

  /// Whether telemetry *collection* should run.
  /// Returns false only when the effective sampling percent is 0.
  /// Crash/error beacons MUST NOT consult this — they always collect and send.
  bool get isTrackingEnabled {
    try {
      return getEffectivePercent() > 0;
    } catch (_) {
      return true; // fail-open
    }
  }

  /// Whether the current beacon should be transmitted.
  /// First beacon always sends. Crash/error beacons bypass this entirely.
  bool shouldSend() {
    try {
      if (!_firstBeaconSent) {
        _firstBeaconSent = true;
        orionPrint('SamplingManager: first beacon — always send');
        return true;
      }
      final percent = getEffectivePercent();
      if (percent >= 100) return true;
      if (percent <= 0) {
        orionPrint('SamplingManager: beacon dropped (0%)');
        return false;
      }
      final roll = _random.nextInt(100) + 1; // 1..100 inclusive
      final send = roll <= percent;
      orionPrint('SamplingManager: roll=$roll percent=$percent → '
          '${send ? "SEND" : "DROP"}');
      return send;
    } catch (e) {
      orionPrint('SamplingManager: shouldSend error — $e');
      return true; // fail-open
    }
  }

  // ── Public getters ────────────────────────────────────────────────────────

  /// Effective sampling percent (0..100). Falls back to localSampleRate
  /// while waiting for the first CDN fetch.
  int getEffectivePercent() {
    if (_remotePercent != null) return _remotePercent!;
    return (_localSampleRate * 100).round();
  }

  /// Whether analytics hosts should appear in the beacon network waterfall.
  /// Default false (analytics filtered out).
  bool get showAnalytics =>
      _remoteShowAnalytics ?? _defaultShowAnalytics;

  /// Convenience inverse — true means filter analytics out of the beacon.
  bool get shouldFilterAnalytics => !showAnalytics;

  /// CDN refresh interval in minutes (clamped to >= 1).
  int get configRefreshMin =>
      (_remoteRefreshMin ?? _defaultRefreshMin)
          .clamp(_minRefreshMin, 1 << 30);

  /// File-level config version. Global-only — no resolution chain.
  String get configVersion =>
      _remoteConfigVersion ?? _defaultConfigVersion;

  bool get isConfigLoaded => _configLoaded;

  /// Snapshot of the current resolved config for inclusion in beacons as `cf`.
  Map<String, dynamic> getConfigSnapshot() => {
    's':   getEffectivePercent(),
    'sa':  showAnalytics,
    'crm': configRefreshMin,
    'cv':  configVersion,
  };

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  void refreshConfig() {
    try { _fetchConfig(); } catch (_) {}
  }

  void shutdown() {
    try {
      _refreshTimer?.cancel();
      _refreshTimer = null;

      // Reset all V2 fields to defaults so a subsequent re-init starts clean.
      _remotePercent       = null;
      _remoteShowAnalytics = null;
      _remoteRefreshMin    = null;
      _remoteConfigVersion = null;
      _configLoaded        = false;
      _firstBeaconSent     = false;
      _activeRefreshMin    = _defaultRefreshMin;
      _sinceLastFetch
        ..stop()
        ..reset();

      orionPrint('SamplingManager: shutdown');
    } catch (_) {}
  }

  // ── Refresh scheduling ────────────────────────────────────────────────────

  /// Stop the periodic CDN refresh while the app is backgrounded.
  ///
  /// On Android the Dart isolate keeps running after the app leaves the
  /// foreground, so `Timer.periodic` kept fetching the config every crm minutes
  /// for a user who had switched away — network and radio wakeups buying nothing,
  /// since beacons are only assembled in the foreground.
  ///
  /// Safe to call repeatedly. Config values are left intact; only the timer stops.
  void pauseRefresh() {
    try {
      if (_refreshTimer == null) return;
      _refreshTimer!.cancel();
      _refreshTimer = null;
      orionPrint('SamplingManager: refresh paused (backgrounded)');
    } catch (_) {}
  }

  /// Restart the periodic refresh on foreground, re-fetching immediately only if
  /// the config has actually gone stale while backgrounded.
  ///
  /// The staleness check is the important part. Foregrounding is a *frequent*
  /// event — a user switching between apps does it dozens of times an hour — so
  /// fetching unconditionally here would make ordinary app-switching cost far
  /// more CDN requests than the always-on timer this replaced, which is the
  /// opposite of the point. Fetch only when at least one full refresh interval
  /// has elapsed since the last successful fetch; otherwise just restart the
  /// timer and let it fire on its own schedule.
  ///
  /// No-op when a timer is already live, so a duplicate foreground notification
  /// cannot stack two timers or trigger a redundant fetch.
  void resumeRefresh() {
    try {
      if (_refreshTimer != null) return;
      _scheduleRefresh(_activeRefreshMin);

      // Not running => no successful fetch yet, so there is nothing to be fresh.
      final stale = !_sinceLastFetch.isRunning ||
          _sinceLastFetch.elapsed >= Duration(minutes: _activeRefreshMin);

      orionPrint('SamplingManager: refresh resumed (foregrounded), '
          'stale=$stale');

      if (stale) _fetchConfig();
    } catch (_) {}
  }

  void _scheduleRefresh(int minutes) {
    try {
      _refreshTimer?.cancel();
      final clamped = minutes < _minRefreshMin ? _minRefreshMin : minutes;
      _refreshTimer = Timer.periodic(
        Duration(minutes: clamped),
            (_) => _fetchConfig(),
      );
      _activeRefreshMin = clamped;
    } catch (e) {
      orionPrint('SamplingManager: scheduleRefresh error — $e');
    }
  }

  /// Reschedule the periodic refresh job if the new crm differs from the
  /// currently active one. Avoids tearing down the timer on every fetch.
  void _maybeRescheduleRefresh(int newCrm) {
    if (newCrm != _activeRefreshMin) {
      orionPrint('SamplingManager: crm changed '
          '$_activeRefreshMin → $newCrm — rescheduling refresh');
      _scheduleRefresh(newCrm);
    }
  }

  // ── CDN fetch ─────────────────────────────────────────────────────────────

  /// Pull the resolved config from the native layer.
  ///
  /// 1.2.39 — this used to make its own HTTPS request to confOriSamplV2.json.
  /// The native layer fetches the same file at the same moment, because it has
  /// to: it needs `bu` before it can POST anything, and the crash/ANR path
  /// needs `s` at a point where Dart may be gone. So every launch cost two
  /// identical CDN requests, and the config object is 83% of all requests on
  /// the distribution. Native is now the single owner; Dart reads its already
  /// resolved snapshot over the channel — no network, no second request.
  ///
  /// Failure modes are unchanged. If the channel call fails, or native has not
  /// resolved a config yet, the remote fields stay null and every getter falls
  /// back to the same hardcoded defaults it used while the old HTTP fetch was
  /// in flight. The first beacon always sends regardless.
  Future<void> _fetchConfig() async {
    try {
      final raw = await _channel.invokeMethod<dynamic>('getSamplingConfig');
      if (raw is! Map) {
        orionPrint('SamplingManager: no config from native — using fallback');
        return;
      }
      final map = Map<String, dynamic>.from(raw);

      // Native resolves c[cid].p[pid] -> c[cid] -> global itself, so the
      // chain-walking resolvers are not used on this path — only the
      // coercers, which must stay because the channel hands back platform
      // types (Android int/bool, iOS NSNumber).
      if (map['loaded'] != true) {
        orionPrint('SamplingManager: native config not resolved yet — '
            'staying on defaults');
        return;
      }

      _remotePercent       = _coercePercent(map['s']);
      _remoteShowAnalytics = _coerceBool(map['sa']);
      _remoteRefreshMin    = _coerceMinutes(map['crm']);
      final cv             = map['cv'];
      _remoteConfigVersion = cv is String && cv.isNotEmpty ? cv : null;
      _configLoaded        = true;

      // Restart the staleness clock. Only on success — a failed channel call
      // must leave the config looking stale so the next foreground retries
      // rather than sitting on a value we failed to confirm.
      _sinceLastFetch
        ..reset()
        ..start();

      orionPrint(
        'SamplingManager: config from native — '
            's=$_remotePercent% sa=$_remoteShowAnalytics '
            'crm=${_remoteRefreshMin}m cv=$_remoteConfigVersion',
      );

      // Reschedule periodic refresh if crm changed.
      _maybeRescheduleRefresh(configRefreshMin);
    } catch (e) {
      orionPrint('SamplingManager: config channel error — $e — using fallback');
    }
  }

  /// Ask native again, a few times, until it reports a resolved config.
  /// Cancels itself as soon as one arrives or the attempts run out. Purely
  /// local — each attempt is an in-memory read on the native side.
  void _scheduleEarlyRetries() {
    for (var i = 0; i < _earlyRetries.length; i++) {
      Timer(_earlyRetries[i], () {
        if (_configLoaded) return;
        if (_cid.isEmpty) return;
        _fetchConfig();
      });
    }
  }

  // ── Coercion helpers ──────────────────────────────────────────────────────

  /// Coerce a JSON value to a percentage int (0-100) or null if not coercible.
  /// Accepts int, double, num, and numeric strings — mirrors Kotlin optInt().
  int? _coercePercent(Object? value) {
    if (value is int)    return value.clamp(0, 100);
    if (value is num)    return value.toInt().clamp(0, 100);
    if (value is String) {
      final parsed = int.tryParse(value) ?? double.tryParse(value)?.toInt();
      if (parsed != null) return parsed.clamp(0, 100);
    }
    return null;
  }

  /// Coerce a JSON value to a boolean or null if not coercible.
  /// Accepts bool, "true"/"false" strings, and integers (0 = false, non-zero = true).
  bool? _coerceBool(Object? value) {
    if (value is bool) return value;
    if (value is num)  return value != 0;
    if (value is String) {
      final lower = value.toLowerCase().trim();
      if (lower == 'true')  return true;
      if (lower == 'false') return false;
    }
    return null;
  }

  /// Coerce a JSON value to a positive int (minutes) or null if not coercible.
  /// Returned value is NOT clamped here — clamping is applied at read-time
  /// via the `configRefreshMin` getter so the raw resolved value is preserved.
  int? _coerceMinutes(Object? value) {
    if (value is int)    return value;
    if (value is num)    return value.toInt();
    if (value is String) {
      final parsed = int.tryParse(value) ?? double.tryParse(value)?.toInt();
      return parsed;
    }
    return null;
  }

  // ── Field resolvers: REMOVED in 1.2.39 ────────────────────────────────────
  //
  // Dart used to walk the c[cid].p[pid] -> c[cid] -> global chain itself,
  // duplicating Kotlin's resolveField()/SamplingManager.swift's. Both copies
  // had to stay behaviourally identical or the same CDN file would resolve to
  // different sampling on the two platforms — a standing correctness risk that
  // the old comments called out explicitly.
  //
  // Native now resolves the chain and Dart reads the resolved values over the
  // channel, so there is exactly one implementation and the invariant holds by
  // construction. The coercers above stay: the channel hands back platform
  // types (Android int/bool, iOS NSNumber) which still need normalising.
}
