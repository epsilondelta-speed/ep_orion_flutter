/// Empty-beacon guard, shared by the manual and automatic screen trackers.
///
/// Deliberately free of Flutter and dart:io types so it can be unit-tested on a
/// desktop host — `OrionFlutter.isSupported` is `Platform.isAndroid ||
/// Platform.isIOS`, so every path that reaches this decision short-circuits
/// under `flutter test`. Same reasoning as `claimInitSlot()` on the Kotlin side.
///
/// 1.2.36. A host can finalize a screen microseconds after starting it — the
/// customer pattern that surfaced this finalizes the GLOBAL
/// `OrionNetworkTracker.currentScreenName` from a page's `dispose()`, which by
/// then points at the screen just pushed rather than the one being destroyed.
/// The tracker exists but has captured nothing, so the SDK emitted a row of
/// `ttid: -1`, `totFrm: 0`, empty network: data-shaped noise that pollutes
/// per-screen averages downstream.
library;

/// True when a finalized screen collected nothing at all and its beacon would
/// carry no measurement.
///
/// This is a statement of fact, not a guess at the caller's intent. All four
/// conditions must hold, and each is load-bearing:
///
///   * [ttid] `-1` — the first-frame callback never fired, so the screen was
///     never drawn.
///   * [totalFrames] `0` — nothing rendered while it was tracked.
///   * [networkCount] `0` — it issued no requests. A screen that never drew a
///     frame but did fire requests is still worth sending, which is why this
///     cannot be inferred from [ttid] alone.
///   * [rageClickCount] `0` — no interaction signal. Rage clicks on an
///     unrendered screen would be bizarre, but they are a genuine UX signal and
///     must not be discarded.
///
/// Suppression removes the noise; it does not recover the measurement. By the
/// time this returns true the real TTID/TTFD for that screen is already lost. A
/// host that sees screens go missing should fix its finalize call rather than
/// rely on this.
bool shouldSuppressEmptyBeacon({
  required int ttid,
  required int totalFrames,
  required int networkCount,
  required int rageClickCount,
}) =>
    ttid == -1 &&
    totalFrames == 0 &&
    networkCount == 0 &&
    rageClickCount == 0;
