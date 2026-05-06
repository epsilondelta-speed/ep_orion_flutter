# Orion Flutter SDK — iOS Feature Parity & New Features

## Files Changed / Added

### New Files (add to ios/Classes/)
| File | Purpose |
|------|---------|
| `iOSHealthTracker.swift` | Thermal state, low power mode, memory warnings, hang detection |
| `StartupTypeTracker.swift` | Cold / warm / hot startup detection — mirrors Android |
| `iOSSamplingManager.swift` | Native-side sampling for crash beacons |

### Updated Files (replace in ios/Classes/)
| File | What Changed |
|------|-------------|
| `OrionFlutterPlugin.swift` | Wires all new trackers, saves exit timestamp on background |
| `FlutterSendData.swift` | Adds iosHealth to every screen beacon |
| `AppMetrics.swift` | Adds iosHealth to static metrics |
| `BatteryMetricsTracker.swift` | Fixes bgDurMin -0.0 bug |
| `SendData.swift` | Adds iOSSamplingManager gate + startup type from tracker |

---

## New Beacon Fields

### `iosHealth` (added to ALL beacons — absent on Android)
```json
"iosHealth": {
  "thermalState":     "nominal",   // nominal | fair | serious | critical
  "thermalLevel":     0,           // 0=nominal 1=fair 2=serious 3=critical
  "lowPowerMode":     false,       // true when user enables Low Power Mode
  "memPressureCount": 0,           // didReceiveMemoryWarning count this session
  "hangCount":        0,           // main thread hangs >500ms this session
  "processorCount":   6            // active CPU cores
}
```

### `startupType` (now accurate — was always "hot")
```
"startupType": "cold"   // first launch or killed by OS (gap > 30s)
"startupType": "warm"   // relaunched after 5-30s gap
"startupType": "hot"    // resumed within 5s
```

---

## Feature Comparison After This Update

| Feature | Android | iOS Before | iOS After |
|---------|---------|-----------|-----------|
| Thermal state | ❌ | ❌ | ✅ iosHealth.thermalState |
| Low power mode | ❌ | ❌ | ✅ iosHealth.lowPowerMode |
| Memory pressure | onTrimMemory level | ❌ | ✅ iosHealth.memPressureCount |
| Hang detection | ANR via ExitInfo | ❌ | ✅ iosHealth.hangCount |
| Startup type | cold/warm/hot | always "hot" | ✅ cold/warm/hot |
| Native sampling | SamplingManager.kt | ❌ | ✅ iOSSamplingManager.swift |
| bgDurMin -0.0 bug | N/A | present | ✅ fixed |

---

## What is Still Different (acceptable)

| Feature | Android | iOS | Reason |
|---------|---------|-----|--------|
| ANR detection | ApplicationExitInfo | ❌ | No iOS API. Use hangCount as proxy |
| OkHttp interceptor | All HTTP | Dio only | URLProtocol fragile, not worth it |
| lastUserInteraction | Activity lifecycle string | "unknown" | Low value, skip |

---

## Beacon Structure (complete iOS beacon)
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
  "bgCount": 0,
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
    "jnkCls": [...],
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
    "totalMs": 3991,
    "count": 1,
    "bgMs": 0,
    "maxMs": 3991,
    "stuckCnt": 0,
    "stuckThreshMs": 60000,
    "activeCnt": 0,
    "locks": [...]
  },

  "rageClicks": [...],
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
  "userSessionId": "1a0e68ed...",
  "locale": "en_US",
  "isDeviceRooted": false,
  "screenResolution": "1206x2622",
  "DeviceDimensions": {
    "deviceWidth": 1206,
    "deviceHeight": 2622,
    "viewportWidth": 402,
    "viewportHeight": 874,
    "densityDpi": 480,
    "density": 3.0
  },
  "cid": "0002317",
  "pid": "0003",
  "appVer": "1.0.0",
  "appPkgName": "com.navfluttter3.navFluttter3",
  "sdkVer": 18,
  "releaseName": "1.0.8",
  "model": "iPhone 16 Pro",
  "brand": "Apple",
  "manufacture": "Apple",
  "netType": "wifi",
  "libVer": "1.0.8",
  "sesId": "c6dfc7c1-744f-40a5-b7ac-1aee930d7599",
  "platform": "ios",
  "startupType": "cold"
}
```
