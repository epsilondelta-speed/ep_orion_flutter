## 1.2.23

**Critical fix.** Resolves `MissingPluginException` affecting v1.2.19 through
v1.2.22. The customer-facing plugin module was being silently dropped from
Flutter's `GeneratedPluginRegistrant` due to two packaging issues (missing
`AndroidManifest.xml`, wrapper class inheritance not detected by Flutter's
plugin tool). All customers on v1.2.19–v1.2.22 should upgrade. Same API,
no code changes required.


## 1.2.22

**Features**

-  beacon URL override config
-  Runtime kill switch added
- Bug fixes

**Bug fixes**

- **`cf` field now attached to every beacon type.** Previously the V2 sampling
  configuration snapshot was only attached to beacons going through
  `SendData.appendCommonFields`. Flutter screen beacons (FlutterSendData),
  native crash beacons (AppCrashAnalyzer), and Flutter crash beacons
  (FlutterCrashAnalyzer) all bypassed this and reached the backend with empty
  `cf`, breaking per-beacon sampling-decision attribution in the dashboard.
  Now explicitly injected at the start of each send path.



## 1.2.21

**Hotfix — fixes BuildConfig duplicate-class error**

- ep_orion_flutter's android/build.gradle now sets `buildFeatures { buildConfig false }`.
  Without this, AGP generates an empty BuildConfig.class for the
  customer-facing plugin module, which conflicts with the Maven AAR's
  BuildConfig.class (containing ORION_SDK_VERSION) — causing "Duplicate
  class co.epsilondelta.orion_flutter.BuildConfig" on customer release
  builds running checkDuplicateClasses.

  Customers don't need to do anything beyond bumping their pubspec.yaml
  ref to v1.2.21. The Maven AAR's BuildConfig still provides
  ORION_SDK_VERSION as before.

  **Customer action:** if you are upgrading from 1.2.20 (recommended)
  just bump the ref. If you are upgrading from <=1.2.18, also remove
  any subprojects/afterEvaluate workaround you may have added.

## 1.2.20

**Hotfix — re-publish of 1.2.19**

- Republishes 1.2.19's architectural change (OrionFlutterPlugin → OrionFlutterPluginCore
  rename) with a complete AAR. The 1.2.19 release shipped with an empty
  OrionFlutterPluginCore.kt source file due to a local file-corruption
  issue between verification and release-script execution, causing the
  AAR to be missing the OrionFlutterPluginCore class entirely.

  **Customer action:** Use 1.2.20 instead of 1.2.19. Same notes as 1.2.19
  apply: customers who previously added a `subprojects/afterEvaluate`
  workaround MUST remove it when upgrading.
-

## 1.2.19

**Architectural Change — duplicate class issue for BB**

- Refactored the Android plugin entry point to eliminate the duplicate-class
  error that occurred on customer release builds running
  `checkDuplicateClasses`. The compiled SDK class is now named
  `OrionFlutterPluginCore`; the customer-facing plugin provides a thin
  `OrionFlutterPlugin` wrapper that extends it. Since the two classes have
  distinct names, they coexist on the customer's classpath without conflict.

  **Customer action:** Customers who previously added a
  `subprojects/afterEvaluate` workaround (excluding `OrionFlutterPlugin.kt`
  from compilation) MUST REMOVE that workaround when upgrading to 1.2.19.
  Leaving it in place will strip the wrapper class and cause runtime
  registration failure.

- (Carried forward from 1.2.18) Consumer ProGuard rules bundled with the AAR.

## 1.2.18

**Fixes**

- Added consumer ProGuard rules (`consumer-rules.pro`) shipped with the SDK.
  Customer release builds with R8/ProGuard minification will now succeed
  without requiring any consumer-side ProGuard configuration. Fixes
  "Compilation failed to complete: OrionFlutterPlugin.class" during R8
  transformation reported in customer integrations.

## 1.2.17

### No code changes

This is a build-config-only release. SDK source code, behavior, beacon schema,
and iOS implementation are identical to 1.2.16. The fix is purely in how the
customer's app resolves the SDK's transitive dependencies at runtime.

## 1.2.16

### iOS V2 sampling parity

- iOSSamplingManager migrated to V2 schema (`confOriSamplV2.json`).


## 1.2.15

### Added
- confOriSamplV2 sampling configuration schema (s, sa, crm, cv fields)
- cf field attached to every beacon (resolved sampling state snapshot)
- EdOrion.disable() / EdOrion.enable() runtime kill switch

### Fixed (Android)
- Main-thread crash beacons no longer dropped due to NetworkOnMainThreadException
- Phase-tracked diagnostic logger in AppCrashAnalyzer
- Four-layer crash handler defense in EdOrion
- @Volatile currentActivity for safe cross-thread reads from crash handler
- BatteryMetricsTracker switched to BroadcastReceiver-based design (no per-call IPC)
- SessionManager uses in-memory cache + throttled disk writes
- WakeLockTracker caps tracked tags at 50 with LRU eviction
- ANRMonitor uses lazy lineSequence (saves ~80KB GC per ANR)
- Native-side analytics URL filtering in FlutterSendData

### Fixed (iOS)
- releaseName now matches libVer (was hardcoded to 1.0.8)
- WakeLockTracker reports correct maxMs for currently-held locks
