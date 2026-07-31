# Orion Flutter SDK — iOS Implementation

Status of the iOS side of the Flutter plugin: what is implemented, what
differs from Android, what is knowingly missing, and how to validate it.

**Current SDK version:** 1.2.27
**Minimum iOS:** 13.0

---

## Files in `ios/Classes/`

| File | Purpose | Added |
|------|---------|-------|
| `OrionFlutterPlugin.swift` | Method-channel entry point, lifecycle, crash handler install | — |
| `SendData.swift` | Beacon transport, sampling gate, common fields | — |
| `FlutterSendData.swift` | Screen-beacon assembly, URL filtering | — |
| `AppMetrics.swift` | Static device/app metrics | — |
| `BatteryMetricsTracker.swift` | Battery session tracking | — |
| `MemoryMetricsTracker.swift` | Memory growth/peak sampling | — |
| `WakeLockTracker.swift` | Wake-lock duration + stuck detection | — |
| `SessionManager.swift` | Session id + timeout | — |
| `OrionLogger.swift` | Logging | — |
| `iOSHealthTracker.swift` | Thermal, low-power, memory pressure, hangs | 1.2.15 |
| `StartupTypeTracker.swift` | cold / warm / hot detection | 1.2.15 |
| `iOSSamplingManager.swift` | Native sampling (V2 schema) | 1.2.16 |
| **`OrionCrashStore.swift`** | **Crash persist + next-launch delivery** | **1.2.27** |

---

## Version history (iOS-affecting changes)

### 1.2.27 — reliable crash delivery + rage click scroll passthrough

`OrionFlutterPlugin.swift` (modified), `OrionCrashStore.swift` (new),
`FlutterSendData.swift` (modified — forwards `sy`/`msy`/`cy`; see Known Gaps).

The crash handler previously called `SendData().coronaGo(beacon)` and then
`Thread.sleep(forTimeInterval: 0.5)`. `coronaGo` dispatches to
`DispatchQueue.global().async` and then `URLSession.dataTask.resume()` —
two asynchronous hops. iOS terminates the process almost immediately after
an uncaught exception, so that POST frequently never completed and the crash
was silently lost. This was the primary reason iOS crashes appeared in
Firebase Crashlytics but not in Orion.

The handler now serializes the beacon and writes it to disk synchronously.
`OrionCrashStore.flushPendingCrash()` — called during plugin init after
`iOSSamplingManager.initialize()` — reads, sends, and deletes it on the next
launch. Handler chaining to Crashlytics/Sentry is unchanged.

New beacon field on these deliveries: `"crashDeliveredOnNextLaunch": true`.

### 1.2.26 — rage click scroll context (iOS passthrough fixed in 1.2.27)

Dart stamps rage clicks with `sy` / `msy` / `cy` when the page was scrolled.
iOS did not forward these fields in 1.2.26; fixed in 1.2.27 — see Known Gaps
below.

Cold-start phase breakdown also shipped in 1.2.26, **Android only**.

### 1.2.25 — `os` field fix (P0) + memory guard

- `AppMetrics.swift`: the `releaseName` field (which the aggregation maps to
  `os`) was reporting the **SDK version** instead of the device iOS version,
  breaking iOS-version slicing in dashboards. It must read
  `UIDevice.current.systemVersion`. `libVer` remains the SDK version and is
  set separately by `SendData.appendCommonFields`.
- `MemoryMetricsTracker.swift`: `growthPerHour` now requires ≥5 min session
  and ≥10 samples before extrapolating; otherwise emits `0`.

### 1.2.24 — `hangCount` cap

`iOSHealthTracker.swift`: capped at 200 per session.

### 1.2.16 — V2 sampling

`iOSSamplingManager.swift` migrated to `confOriSamplV2.json` (`s`, `sa`,
`crm`, `cv`), with `cf` snapshot on every beacon and a lenient
`shouldSendCrashAnr()` gate for crash beacons.

### 1.2.15 — iOS parity baseline

`iOSHealthTracker.swift`, `StartupTypeTracker.swift` added; `bgDurMin -0.0`
bug fixed.

---

## iOS-specific beacon fields

### `iosHealth` (every beacon; absent on Android)

```json
"iosHealth": {
  "thermalState":     "nominal",   // nominal | fair | serious | critical
  "thermalLevel":     0,           // 0=nominal 1=fair 2=serious 3=critical
  "lowPowerMode":     false,
  "memPressureCount": 0,           // didReceiveMemoryWarning count this session
  "hangCount":        0,           // main-thread hangs >500ms (capped at 200)
  "processorCount":   6
}
```

### `startupType`

```
"cold"   // first launch, or gap > 30s since last background
"warm"   // gap 5–30s
"hot"    // gap <= 5s
```

Android matched this algorithm in 1.2.26; the iOS implementation was the
reference and is unchanged.

### `crashDeliveredOnNextLaunch` (1.2.27, crash beacons only)

Present and `true` on crash beacons delivered by `OrionCrashStore`.

**Backend note:** `sesId` on these beacons belongs to the launch that
*delivered* the crash, not the launch that *crashed* — the crashed session's
id is unrecoverable after the process dies. Use `epoch` (captured at crash
time) for crash timing.

---

## Crash capture — scope and roadmap

### What iOS captures today

| Crash class | Example | Captured? |
|---|---|---|
| Objective-C exceptions | `NSInternalInconsistencyException`, `NSRangeException` | ✅ |
| Swift runtime traps | force-unwrap nil, `fatalError()` | ⚠️ Usually no (raises `SIGTRAP`/`SIGILL`) |
| Memory faults | `EXC_BAD_ACCESS` / `KERN_INVALID_ADDRESS` | ❌ |
| Aborts | `SIGABRT`, C++ `std::terminate` | ❌ |
| Watchdog terminations | `0x8badf00d` | ❌ |
| OOM / jetsam kills | — | ❌ (no platform API) |

The SDK installs `NSSetUncaughtExceptionHandler`, which by design sees only
Objective-C exceptions. Everything in the ❌ rows is delivered to the process
as a **POSIX signal** and requires separate `sigaction`-based handlers.

**Support note:** a crash present in Crashlytics but absent from Orion on iOS
is almost always a signal-class crash. That is expected behavior in this
version, not a delivery failure.

**Subtlety:** an ObjC exception that unwinds through C++ frames (common with
WebKit, e.g. `WebKit::CompletionHandlerCallChecker::~CompletionHandlerCallChecker()`)
often terminates via `std::terminate` → `SIGABRT` rather than the uncaught-
exception path, so it is also missed despite looking like an ObjC exception
in a Crashlytics report.

### Delivery model (1.2.27)

```
crash → handler builds beacon → OrionCrashStore.persist() writes JSON to disk
      → chains to Crashlytics/Sentry → process dies
                     ↓
next launch → flushPendingCrash() → coronaGo(beacon) → delete file
```

- Pending file: `Library/orion_pending_crash.json`
- Deleted after the send attempt **whether or not it succeeded** — a single
  lost report is preferable to an unbounded retry that re-sends on every
  future launch.
- Crash sampling gate applied at **send** time using the then-current config.

### Roadmap — signal-based capture

Closing the ❌ rows requires a signal-handler layer. Design constraints,
recorded here so they are not re-derived:

1. **Async-signal-safety.** Handlers may only call async-signal-safe
   functions — no `malloc`, no Swift `String` construction, no
   `JSONSerialization`, no logging. File descriptor, backtrace buffer,
   scratch buffers and the current screen name (fixed C buffer) must all be
   pre-allocated at install. The handler may use only `write()`, `time()`,
   `backtrace()`, `backtrace_symbols_fd()`, `sigaction()`, `raise()`.
2. **Chaining is mandatory.** Crashlytics and Sentry install their own
   signal handlers; each previous `sigaction` must be saved and invoked
   after Orion persists. Getting this wrong **silently disables the host
   app's existing crash reporting** — the highest-risk failure mode.
3. **Re-entrancy.** `sa_mask` must block the other handled signals, plus a
   single-flight guard so a fault inside the handler cannot recurse.
4. **Reduced fidelity ("Option B").** Memory / disk / battery cannot be
   sampled in signal context, and sampling them on the next launch would be
   misleading — they are sent as `0`. Device/app identity fields remain
   accurate. This matches the standalone `ep-orion-ios` SDK, which already
   implements this design and is the intended source for the port.

**Signals to handle:** `SIGSEGV`, `SIGBUS`, `SIGABRT`, `SIGILL`, `SIGFPE`,
`SIGTRAP`.

This is staged as its own release because signal handling is the most
invasive thing an SDK can do to a host process; a defect can turn one crash
into a hang, a lost crash, or a broken Crashlytics integration.

---

## Known gaps vs Android

| Feature | Android | iOS | Status |
|---|---|---|---|
| Rage click scroll fields | ✅ `sy`/`msy`/`cy` | ✅ | **Fixed in 1.2.27** |
| Cold-start phase breakdown | ✅ 1.2.26 | ❌ | Planned; needs `sysctl` anchor + `+load` hook |
| Signal-class crash capture | ✅ (JVM handler covers all uncaught) | ❌ | Planned — see roadmap above |
| ANR detection | ✅ ApplicationExitInfo | ❌ | No iOS API; `hangCount` is the proxy |
| HTTP interception scope | All (OkHttp) | Dio only | `URLProtocol` fragile; accepted |
| `lastUserInteraction` | Activity lifecycle | `"unknown"` | Low value; skipped |

### Rage click scroll fields — fixed in 1.2.27

**The bug (1.2.26):** `FlutterSendData.swift` → `buildRageClicksArray()`
rebuilds each rage click from an explicit whitelist of
`x`/`y`/`count`/`durMs`/`ts`. The `sy`/`msy`/`cy` scroll-context fields added
in 1.2.26 were not in that list and were silently discarded, so the
scroll-aware heatmap feature did not work on iOS at all. Android forwarded
them correctly.

**The fix:** the three fields are now forwarded as a group, preserving the
Dart layer's all-three-or-none contract (emitted together, and only when the
page was actually scrolled):

```swift
if let sy  = (click["sy"]  as? NSNumber)?.intValue,
   let msy = (click["msy"] as? NSNumber)?.intValue,
   let cy  = (click["cy"]  as? NSNumber)?.intValue {
    obj["sy"] = sy; obj["msy"] = msy; obj["cy"] = cy
}
```

⚠️ **Note for future work:** `buildRageClicksArray()` is a whitelist. Any new
rage click field added on the Dart side must be added here too, or it will
be dropped on iOS the same way. The plugin's `handleTrackScreen` passes
`rageClicks` through untouched as `[[String: Any]]`, so this function is the
only place fields are lost.

### Verify the 1.2.25 `releaseName` fix is present

`AppMetrics.swift` must populate `releaseName` from
`UIDevice.current.systemVersion`, not from the SDK version. If the file
still contains a `sdkReleaseName` property initialised to
`OrionConfig.sdkVersion`, the 1.2.25 fix has not been applied to that copy
and iOS-version slicing will be wrong.

---

## Sample iOS screen beacon (1.2.27)

```json
{
  "flutter": 1,
  "platform": "ios",
  "screen": "DioImagePage",
  "activityName": "DioImagePage",
  "ttid": 198,
  "ttfd": 488,
  "ttfdManual": false,
  "jankyFrames": 158,
  "frozenFrames": 0,
  "wentBg": false,
  "startupType": "cold",

  "network": [{
    "url": "https://picsum.photos/500/300",
    "method": "GET",
    "statusCode": 200,
    "duration": 435,
    "startTime": 1774272120612,
    "endTime": 1774272121047,
    "payloadSize": 29642,
    "contentType": "image/jpeg"
  }],

  "frameMetrics": {
    "totFrm": 234,
    "jnkFrm": 158,
    "frzFrm": 0,
    "avgDur": "18.09",
    "worstDur": "315.00",
    "jnkPct": "67.52",
    "jnkCls": [],
    "frzFrms": [],
    "ttfdSrc": "stable_frames"
  },

  "mem": {
    "startMB": 382.44,
    "curMB": 498.91,
    "peakMB": 517.28,
    "growthMB": 116.45,
    "growthPerHour": 0,
    "samples": 3
  },

  "wl": {
    "totalMs": 3991, "count": 1, "bgMs": 0, "maxMs": 3991,
    "stuckCnt": 0, "stuckThreshMs": 60000, "activeCnt": 0
  },

  "rageClicks": [
    { "x": 207, "y": 501, "count": 3, "durMs": 517, "ts": 1774272338791,
      "sy": 1240, "msy": 3600, "cy": 1741 }
  ],
  "rageClickCount": 1,

  "sesBatSt": 80,
  "sesBatCur": 80,
  "sesBatDrain": 0,
  "totalSesDurMin": "4.0",
  "fgDurMin": "4.0",
  "bgDurMin": "0.0",
  "drainPerFgHour": "0.0",
  "drainPerTotalHour": "0.0",
  "fgPct": "100.0",
  "sesTimedOut": false,
  "batIsCharging": false,

  "iosHealth": {
    "thermalState": "nominal",
    "thermalLevel": 0,
    "lowPowerMode": false,
    "memPressureCount": 0,
    "hangCount": 0,
    "processorCount": 6
  },

  "memoryUsage": 1,
  "batteryPercentage": 80,
  "diskSpaceUsage": 98,
  "locale": "en_US",
  "isDeviceRooted": false,
  "screenResolution": "1206x2622",
  "DeviceDimensions": {
    "deviceWidth": 1206, "deviceHeight": 2622,
    "viewportWidth": 402, "viewportHeight": 874,
    "densityDpi": 480, "density": 3.0
  },
  "cid": "0002317",
  "pid": "0003",
  "appVer": "1.0.0",
  "appPkgName": "com.navfluttter3.navFluttter3",
  "sdkVer": 18,
  "releaseName": "17.5.1",
  "model": "iPhone 16 Pro",
  "brand": "Apple",
  "manufacture": "Apple",
  "netType": "wifi",
  "libVer": "1.2.27",
  "sesId": "c6dfc7c1-744f-40a5-b7ac-1aee930d7599",
  "cf": { "s": 100, "sa": false, "crm": 15, "cv": "1.0" }
}
```

Note `releaseName` = iOS version (`"17.5.1"`) and `libVer` = SDK version
(`"1.2.27"`). These must differ; if they match, the 1.2.25 fix is missing.
The `rageClicks` entry above shows the **scrolled** form. `sy`/`msy`/`cy`
appear together only when the page was actually scrolled; an unscrolled tap
carries none of them (1.2.27+ on iOS; 1.2.26+ on Android).

---

## QA — iOS crash capture

Run before shipping any change to crash handling. Detail and the shared
test-case numbering live in DEVELOPER_GUIDE.md → "QA — Crash Capture Test
Plan"; the iOS-specific requirements are:

- **Use a profile or release build.** Debug builds attach a debugger that
  intercepts exceptions and signals, so crash handlers do not behave
  normally. This is the most common cause of a "failed" crash test on
  code that is actually correct.
- **Install Firebase Crashlytics alongside Orion** in the test app — test
  C4 (coexistence) is the release blocker.

| Case | Test | Expected |
|---|---|---|
| C1 | Raise `NSException`, relaunch | Beacon with `crashType` = exception name, `crashDeliveredOnNextLaunch: true` |
| C2 | Relaunch again | **No** duplicate beacon (file deleted) |
| C3 | Clean launch, no prior crash | No beacon, no errors |
| C4 | Crash with Crashlytics installed | Appears in **both** dashboards — chaining intact |
| C5 | `s = 0` in CDN config, crash, relaunch | No beacon; file still deleted |
| C6 | Write garbage to the pending file, launch | Warning logged, no beacon, file deleted, no hang |
| C7 | Trigger `EXC_BAD_ACCESS`, relaunch | **No** Orion beacon (documents the known gap; becomes a positive test when signal capture ships) |

Trigger snippets:

```swift
// C1 — ObjC exception
NSException(name: .genericException, reason: "orion qa", userInfo: nil).raise()

// C7 — EXC_BAD_ACCESS (expected NOT to be captured in 1.2.27)
let p = UnsafeMutablePointer<Int>(bitPattern: 0xdeadbeef)!
p.pointee = 1
```