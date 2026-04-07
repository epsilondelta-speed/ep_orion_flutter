import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// SamplingManager — Remote sampling configuration for Orion Flutter SDK.
///
/// Resolution priority (first match wins):
///   1. c[cid].p[pid]  → product-level override (most specific)
///   2. c[cid].d       → company-level default
///   3. d              → global default
///   4. localSampleRate → fallback if CDN unreachable
///
/// isTrackingEnabled vs shouldSend:
///   isTrackingEnabled — returns false ONLY when effectivePercent == 0.
///     Use to skip *collecting* data (network requests, frame tracking, etc.)
///     so we don't waste CPU/memory when the kill-switch is active.
///   shouldSend — probabilistic gate applied just before sending a beacon.
///     Use in trackFlutterScreen() etc.
///   Crash/error beacons should NEVER consult either gate.
class SamplingManager {

  // ── Singleton ─────────────────────────────────────────────────────────────
  static final SamplingManager instance = SamplingManager._();
  SamplingManager._();

  // ── Constants ─────────────────────────────────────────────────────────────
  static const String _cdnUrl =
      'https://cdn.epsilondelta.co/orion/confOriSampl.json';
  static const Duration _refreshInterval = Duration(minutes: 15);
  static const Duration _fetchTimeout    = Duration(seconds: 10);

  // ── State ─────────────────────────────────────────────────────────────────
  String  _cid             = '';
  String  _pid             = '';
  double  _localSampleRate = 1.0;
  int?    _remotePercent;
  bool    _configLoaded    = false;
  bool    _firstBeaconSent = false;
  Timer?  _refreshTimer;

  final Random _random = Random();

  // ── Init ──────────────────────────────────────────────────────────────────

  void initialize(String cid, String pid, {double sampleRate = 1.0}) {
    try {
      _cid             = cid;
      _pid             = pid;
      _localSampleRate = sampleRate.clamp(0.0, 1.0);
      _firstBeaconSent = false;
      _configLoaded    = false;
      _remotePercent   = null;

      _fetchConfig();

      _refreshTimer?.cancel();
      _refreshTimer = Timer.periodic(_refreshInterval, (_) => _fetchConfig());

      debugPrint('[Orion] SamplingManager: initialized '
          'cid=$cid pid=$pid localRate=${(sampleRate * 100).round()}%');
    } catch (e) {
      debugPrint('[Orion] SamplingManager: initialize error — $e');
    }
  }

  // ── Gates ─────────────────────────────────────────────────────────────────

  /// Whether telemetry *collection* should run.
  ///
  /// Returns false only when effectivePercent == 0 (kill-switch active).
  /// Use at collection sites: network tracker, frame tracker, rage click tracker.
  /// Crash/error beacons MUST NOT consult this — they always collect and send.
  bool get isTrackingEnabled {
    try {
      return getEffectivePercent() > 0;
    } catch (e) {
      return true; // fail-open
    }
  }

  /// Whether the current beacon should be transmitted.
  ///
  /// Applies percentage-based random sampling.
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

      final roll  = _random.nextInt(100) + 1; // 1–100 inclusive
      final send  = roll <= percent;
      debugPrint('[Orion] SamplingManager: roll=$roll percent=$percent → '
          '${send ? "SEND" : "DROP"}');
      return send;
    } catch (e) {
      debugPrint('[Orion] SamplingManager: shouldSend error — $e');
      return true; // fail-open
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  int getEffectivePercent() {
    if (_remotePercent != null) return _remotePercent!;
    return (_localSampleRate * 100).round();
  }

  bool get isConfigLoaded => _configLoaded;

  void refreshConfig() {
    try { _fetchConfig(); } catch (_) {}
  }

  void shutdown() {
    try {
      _refreshTimer?.cancel();
      _refreshTimer = null;
      debugPrint('[Orion] SamplingManager: shutdown');
    } catch (_) {}
  }

  // ── CDN Fetch ─────────────────────────────────────────────────────────────

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

      final Map<String, dynamic> json = jsonDecode(response.body) as Map<String, dynamic>;
      _remotePercent = _resolvePercent(json);
      _configLoaded  = true;

      debugPrint('[Orion] SamplingManager: config loaded — effective percent=$_remotePercent%');
    } on TimeoutException {
      debugPrint('[Orion] SamplingManager: CDN timeout — using fallback');
    } catch (e) {
      debugPrint('[Orion] SamplingManager: CDN error — $e — using fallback');
    }
  }

  // ── Resolution Logic ──────────────────────────────────────────────────────

  int _resolvePercent(Map<String, dynamic> config) {
    if (_cid.isNotEmpty) {
      final cidEntry = config['c']?[_cid];
      if (cidEntry is Map) {
        if (_pid.isNotEmpty) {
          final pidValue = cidEntry['p']?[_pid];
          if (pidValue is int) {
            debugPrint('[Orion] SamplingManager: resolved via c[$_cid].p[$_pid] = $pidValue');
            return pidValue.clamp(0, 100);
          }
        }
        final cidDefault = cidEntry['d'];
        if (cidDefault is int) {
          debugPrint('[Orion] SamplingManager: resolved via c[$_cid].d = $cidDefault');
          return cidDefault.clamp(0, 100);
        }
      }
    }
    final globalDefault = config['d'];
    if (globalDefault is int) {
      debugPrint('[Orion] SamplingManager: resolved via global d = $globalDefault');
      return globalDefault.clamp(0, 100);
    }
    debugPrint('[Orion] SamplingManager: no matching config — defaulting to 100%');
    return 100;
  }
}
