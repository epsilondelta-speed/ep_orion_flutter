import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

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
  static const String _cdnUrl =
      'https://cdn.epsilondelta.co/orion/confOriSamplV2.json';
  static const Duration _fetchTimeout = Duration(seconds: 10);

  // Defaults (used as fail-open fallbacks if CDN unreachable)
  static const int     _defaultPercent      = 100;
  static const bool    _defaultShowAnalytics = false;
  static const int     _defaultRefreshMin    = 15;
  static const int     _minRefreshMin        = 1;
  static const String  _defaultConfigVersion = '1.0';

  // ── State ─────────────────────────────────────────────────────────────────
  String  _cid             = '';
  String  _pid             = '';
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

  final Random _random = Random();

  // ── Init ──────────────────────────────────────────────────────────────────

  void initialize(String cid, String pid, {double sampleRate = 1.0}) {
    try {
      _cid             = cid;
      _pid             = pid;
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

      // Kick off the first fetch immediately.
      _fetchConfig();

      debugPrint('[Orion] SamplingManager: initialized '
          'cid=$cid pid=$pid localRate=${(sampleRate * 100).round()}%');
    } catch (e) {
      debugPrint('[Orion] SamplingManager: initialize error — $e');
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
        debugPrint('[Orion] SamplingManager: first beacon — always send');
        return true;
      }
      final percent = getEffectivePercent();
      if (percent >= 100) return true;
      if (percent <= 0) {
        debugPrint('[Orion] SamplingManager: beacon dropped (0%)');
        return false;
      }
      final roll = _random.nextInt(100) + 1; // 1..100 inclusive
      final send = roll <= percent;
      debugPrint('[Orion] SamplingManager: roll=$roll percent=$percent → '
          '${send ? "SEND" : "DROP"}');
      return send;
    } catch (e) {
      debugPrint('[Orion] SamplingManager: shouldSend error — $e');
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

      debugPrint('[Orion] SamplingManager: shutdown');
    } catch (_) {}
  }

  // ── Refresh scheduling ────────────────────────────────────────────────────

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
      debugPrint('[Orion] SamplingManager: scheduleRefresh error — $e');
    }
  }

  /// Reschedule the periodic refresh job if the new crm differs from the
  /// currently active one. Avoids tearing down the timer on every fetch.
  void _maybeRescheduleRefresh(int newCrm) {
    if (newCrm != _activeRefreshMin) {
      debugPrint('[Orion] SamplingManager: crm changed '
          '$_activeRefreshMin → $newCrm — rescheduling refresh');
      _scheduleRefresh(newCrm);
    }
  }

  // ── CDN fetch ─────────────────────────────────────────────────────────────

  Future<void> _fetchConfig() async {
    try {
      debugPrint('[Orion] SamplingManager: fetching CDN config...');

      final response = await http.get(
        Uri.parse(_cdnUrl),
        headers: {'Cache-Control': 'no-cache'},
      ).timeout(_fetchTimeout);

      if (response.statusCode != 200) {
        debugPrint('[Orion] SamplingManager: CDN returned '
            '${response.statusCode} — using fallback');
        return;
      }

      final Map<String, dynamic> json =
      jsonDecode(response.body) as Map<String, dynamic>;

      // Resolve all four pieces of state.
      _remotePercent       = _resolvePercent(json);
      _remoteShowAnalytics = _resolveShowAnalytics(json);
      _remoteRefreshMin    = _resolveRefreshMin(json);
      _remoteConfigVersion = _resolveConfigVersion(json);
      _configLoaded        = true;

      debugPrint(
        '[Orion] SamplingManager: config loaded — '
            's=$_remotePercent% sa=$_remoteShowAnalytics '
            'crm=${_remoteRefreshMin}m cv=$_remoteConfigVersion',
      );

      // Reschedule periodic refresh if crm changed.
      _maybeRescheduleRefresh(configRefreshMin);
    } on TimeoutException {
      debugPrint('[Orion] SamplingManager: CDN timeout — using fallback');
    } catch (e) {
      debugPrint('[Orion] SamplingManager: CDN error — $e — using fallback');
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

  // ── Field resolvers ───────────────────────────────────────────────────────

  /// Generic resolver that walks the priority chain for a given field name.
  /// Returns the first non-null coercion result, or null if nothing resolved.
  T? _resolveField<T>(
      Map<String, dynamic> config,
      String fieldName,
      T? Function(Object?) coerce,
      ) {
    if (_cid.isNotEmpty) {
      final cidEntry = config['c']?[_cid];
      if (cidEntry is Map) {
        // 1. Product-level override
        if (_pid.isNotEmpty) {
          final productEntry = cidEntry['p']?[_pid];
          if (productEntry is Map) {
            final v = coerce(productEntry[fieldName]);
            if (v != null) return v;
          }
        }
        // 2. Company-level default
        final v = coerce(cidEntry[fieldName]);
        if (v != null) return v;
      }
    }
    // 3. Global default
    return coerce(config[fieldName]);
  }

  int _resolvePercent(Map<String, dynamic> config) {
    final v = _resolveField(config, 's', _coercePercent);
    if (v != null) {
      debugPrint('[Orion] SamplingManager: resolved s=$v');
      return v;
    }
    debugPrint('[Orion] SamplingManager: s not found — defaulting to '
        '$_defaultPercent');
    return _defaultPercent;
  }

  bool _resolveShowAnalytics(Map<String, dynamic> config) {
    final v = _resolveField(config, 'sa', _coerceBool);
    if (v != null) {
      debugPrint('[Orion] SamplingManager: resolved sa=$v');
      return v;
    }
    return _defaultShowAnalytics;
  }

  int _resolveRefreshMin(Map<String, dynamic> config) {
    final v = _resolveField(config, 'crm', _coerceMinutes);
    if (v != null) {
      // Clamp at read time to guarantee invariant, but log the raw value here.
      final clamped = v < _minRefreshMin ? _minRefreshMin : v;
      debugPrint('[Orion] SamplingManager: resolved crm=$v '
          '${clamped != v ? "(clamped to $clamped)" : ""}');
      return v;
    }
    return _defaultRefreshMin;
  }

  /// `cv` is global-only — no resolution chain.
  String _resolveConfigVersion(Map<String, dynamic> config) {
    final raw = config['cv'];
    if (raw is String && raw.isNotEmpty) return raw;
    if (raw is num) return raw.toString();
    return _defaultConfigVersion;
  }
}