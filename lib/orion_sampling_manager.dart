import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// SamplingManager — Remote sampling configuration for Orion Flutter SDK.
///
/// Mirrors SamplingManager.kt (Android) and samplingManager.ts (React Native).
/// All three must produce identical sampling decisions for the same config.
///
/// Resolution priority (first match wins):
///   1. c[cid].p[pid]  → product-level override (most specific)
///   2. c[cid].d       → company-level default
///   3. d              → global default
///   4. localSampleRate → fallback if CDN unreachable
class SamplingManager {

  // ─── Singleton ────────────────────────────────────────────────────────────
  static final SamplingManager instance = SamplingManager._();
  SamplingManager._();

  // ─── Constants ────────────────────────────────────────────────────────────
  static const String _cdnUrl =
      'https://cdn.epsilondelta.co/orion/confOriSampl.json';
  static const Duration _refreshInterval = Duration(minutes: 15);
  static const Duration _fetchTimeout    = Duration(seconds: 10);

  // ─── State ────────────────────────────────────────────────────────────────
  String  _cid             = '';
  String  _pid             = '';
  double  _localSampleRate = 1.0;   // 0.0 – 1.0 fallback
  int?    _remotePercent;           // null = CDN not loaded yet
  bool    _configLoaded    = false;
  bool    _firstBeaconSent = false;
  Timer?  _refreshTimer;

  final Random _random = Random();

  // ─── Init ─────────────────────────────────────────────────────────────────

  /// Call once during SDK init.
  /// [sampleRate] is 0.0–1.0 local fallback (default 1.0 = 100%).
  void initialize(String cid, String pid, {double sampleRate = 1.0}) {
    _cid             = cid;
    _pid             = pid;
    _localSampleRate = sampleRate.clamp(0.0, 1.0);
    _firstBeaconSent = false;
    _configLoaded    = false;
    _remotePercent   = null;

    // Fire-and-forget — never blocks SDK init
    _fetchConfig();

    // Refresh every 15 minutes
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(_refreshInterval, (_) => _fetchConfig());

    debugPrint('[Orion] SamplingManager: initialized '
        'cid=$cid pid=$pid localRate=${(sampleRate * 100).round()}%');
  }

  // ─── Main Decision ────────────────────────────────────────────────────────

  /// Returns true if this beacon should be sent.
  /// Call before every trackFlutterScreen() invocation.
  bool shouldSend() {
    // Rule 1 — first beacon always sends
    if (!_firstBeaconSent) {
      _firstBeaconSent = true;
      debugPrint('[Orion] SamplingManager: first beacon — always send');
      return true;
    }

    final percent = getEffectivePercent();

    // Rule 2 — 100% always sends
    if (percent >= 100) return true;

    // Rule 3 — 0% never sends
    if (percent <= 0) {
      debugPrint('[Orion] SamplingManager: beacon dropped (0%)');
      return false;
    }

    // Rule 4 — random sampling
    final roll   = _random.nextInt(100) + 1;  // 1–100 inclusive
    final send   = roll <= percent;
    debugPrint('[Orion] SamplingManager: roll=$roll percent=$percent → '
        '${send ? "SEND" : "DROP"}');
    return send;
  }

  // ─── Helpers ──────────────────────────────────────────────────────────────

  /// Effective sampling percentage (0–100).
  int getEffectivePercent() {
    if (_remotePercent != null) return _remotePercent!;
    return (_localSampleRate * 100).round();
  }

  bool get isConfigLoaded => _configLoaded;

  /// Force refresh from CDN (e.g. for testing).
  void refreshConfig() => _fetchConfig();

  /// Cancel timer on SDK dispose.
  void shutdown() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    debugPrint('[Orion] SamplingManager: shutdown');
  }

  // ─── CDN Fetch ────────────────────────────────────────────────────────────

  Future<void> _fetchConfig() async {
    try {
      debugPrint('[Orion] SamplingManager: fetching CDN config...');

      final response = await http.get(
        Uri.parse(_cdnUrl),
        headers: {'Cache-Control': 'no-cache'},
      ).timeout(_fetchTimeout);

      if (response.statusCode != 200) {
        debugPrint('[Orion] SamplingManager: CDN returned ${response.statusCode} — using fallback');
        return;
      }

      final Map<String, dynamic> json = jsonDecode(response.body);
      _remotePercent = _resolvePercent(json);
      _configLoaded  = true;

      debugPrint('[Orion] SamplingManager: config loaded — '
          'effective percent=$_remotePercent%');

    } on TimeoutException {
      debugPrint('[Orion] SamplingManager: CDN timeout — using fallback');
    } catch (e) {
      debugPrint('[Orion] SamplingManager: CDN error — $e — using fallback');
    }
  }

  // ─── Resolution Logic ─────────────────────────────────────────────────────

  /// Resolves cid + pid → sampling percent.
  /// Priority: c[cid].p[pid] → c[cid].d → d → 100 (default)
  int _resolvePercent(Map<String, dynamic> config) {
    // Step 1: product-level override c[cid].p[pid]
    if (_cid.isNotEmpty) {
      final cidEntry = config['c']?[_cid];
      if (cidEntry is Map) {
        // Check product-level pid override
        if (_pid.isNotEmpty) {
          final pidValue = cidEntry['p']?[_pid];
          if (pidValue is int) {
            debugPrint('[Orion] SamplingManager: resolved via c[$_cid].p[$_pid] = $pidValue');
            return pidValue.clamp(0, 100);
          }
        }

        // Step 2: company-level default c[cid].d
        final cidDefault = cidEntry['d'];
        if (cidDefault is int) {
          debugPrint('[Orion] SamplingManager: resolved via c[$_cid].d = $cidDefault');
          return cidDefault.clamp(0, 100);
        }
      }
    }

    // Step 3: global default d
    final globalDefault = config['d'];
    if (globalDefault is int) {
      debugPrint('[Orion] SamplingManager: resolved via global d = $globalDefault');
      return globalDefault.clamp(0, 100);
    }

    // Step 4: CDN had no usable value — default to 100 (send all)
    debugPrint('[Orion] SamplingManager: no matching config — defaulting to 100%');
    return 100;
  }
}
