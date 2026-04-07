/**
 * OrionFlutterPlugin — Main entry point for Orion hybrid Flutter SDK.
 *
 * Supported methods:
 * - initializeEdOrion(cid, pid)
 * - getRuntimeMetrics
 * - trackFlutterScreen(..., rageClicks, rageClickCount)
 * - trackFlutterError(...)
 * - onFlutterScreenStart/Stop, onAppForeground/Background
 * - Wake lock tracking methods
 *
 * Thread-safety fix: dartWakeLocks changed from mutableMapOf() to
 * ConcurrentHashMap. onMethodCall() runs on the Flutter platform thread,
 * but onDetachedFromEngine() can be dispatched from a different thread by
 * the Flutter engine during teardown. ConcurrentHashMap makes concurrent
 * access to this shared map safe without additional locking.
 */
package co.epsilondelta.orion_flutter

import android.app.Application
import android.content.Context
import android.os.PowerManager
import android.util.Log
import androidx.annotation.NonNull
import co.epsilondelta.orion_flutter.orion.EdOrion
import co.epsilondelta.orion_flutter.orion.metrics.BatteryMetricsTracker
import co.epsilondelta.orion_flutter.orion.metrics.MemoryMetricsTracker
import co.epsilondelta.orion_flutter.orion.metrics.WakeLockTracker
import co.epsilondelta.orion_flutter.orion.metrics.OrionWakeLock
import co.epsilondelta.orion_flutter.orion.util.FlutterSendData
import co.epsilondelta.orion_flutter.orion.util.OrionLogger
import co.epsilondelta.orion_flutter.orion.crash.FlutterCrashAnalyzer
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap

class OrionFlutterPlugin : FlutterPlugin, MethodCallHandler {

    private lateinit var channel: MethodChannel
    private var edOrionInstance: EdOrion? = null
    private var appContext: Context? = null
    private var application: Application? = null

    private var flutterBatterySessionStarted = false
    private var currentFlutterScreen: String? = null

    // ✅ Thread-safety fix: ConcurrentHashMap instead of mutableMapOf().
    // onMethodCall() and onDetachedFromEngine() can run on different threads.
    private val dartWakeLocks = ConcurrentHashMap<String, OrionWakeLock>()

    override fun onAttachedToEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        try {
            channel = MethodChannel(binding.binaryMessenger, "orion_flutter")
            channel.setMethodCallHandler(this)
            appContext = binding.applicationContext

            if (appContext is Application) {
                application = appContext as Application
            } else {
                OrionLogger.debug("⚠️ Unable to cast context to Application")
            }
            OrionLogger.debug("Plugin attached")
        } catch (e: Exception) {
            OrionLogger.error("OrionFlutterPlugin: onAttachedToEngine error: ${e.message}")
        }
    }

    override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
        when (call.method) {

            // ── Initialisation ────────────────────────────────────────────

            "initializeEdOrion" -> {
                try {
                    val cid = call.argument<String>("cid")
                        ?: return result.error("MISSING_CID", "cid is required", null)
                    val pid = call.argument<String>("pid")
                        ?: return result.error("MISSING_PID", "pid is required", null)

                    val app = application
                    if (app == null) {
                        result.error("INIT_ERROR", "Application context is null", null)
                        return
                    }

                    if (edOrionInstance == null) {
                        edOrionInstance = EdOrion.Builder(app)
                            .setConfig(cid, pid)
                            .setLogEnable(true)
                            .enableAnrMonitoring(true)
                            .build()
                        edOrionInstance?.startListening()
                        MemoryMetricsTracker.initialize()
                    }

                    OrionLogger.debug("Orion initialized via Dart")
                    result.success("orion_initialized")
                } catch (e: Exception) {
                    OrionLogger.error("OrionFlutterPlugin: initializeEdOrion error: ${e.message}")
                    result.error("ORION_INIT_ERROR", e.message, null)
                }
            }

            "getPlatformVersion" -> {
                result.success("Android ${android.os.Build.VERSION.RELEASE}")
            }

            "getRuntimeMetrics" -> {
                try {
                    OrionLogger.debug("Returning Orion runtime metrics")
                    val metrics = edOrionInstance?.getRuntimeMetrics()?.toString() ?: "Not available"
                    result.success(metrics)
                } catch (e: Exception) {
                    result.error("RUNTIME_METRICS_ERROR", e.message, null)
                }
            }

            // ── Battery / Lifecycle ───────────────────────────────────────

            "onFlutterScreenStart" -> {
                try {
                    val screenName = call.argument<String>("screen") ?: "Unknown"
                    currentFlutterScreen = screenName

                    val ctx = appContext
                    if (ctx != null && !flutterBatterySessionStarted) {
                        OrionLogger.debug("🔋 Starting battery session for Flutter screen: $screenName")
                        BatteryMetricsTracker.onAppForegrounded(ctx)
                        flutterBatterySessionStarted = true
                    }
                    result.success("flutter_screen_start_tracked")
                } catch (e: Exception) {
                    result.error("FLUTTER_SCREEN_START_ERROR", e.message, null)
                }
            }

            "onFlutterScreenStop" -> {
                try {
                    val screenName = call.argument<String>("screen") ?: "Unknown"
                    OrionLogger.debug("🔋 Flutter screen stopped: $screenName")
                    if (currentFlutterScreen == screenName) currentFlutterScreen = null
                    result.success("flutter_screen_stop_tracked")
                } catch (e: Exception) {
                    result.error("FLUTTER_SCREEN_STOP_ERROR", e.message, null)
                }
            }

            "onAppForeground" -> {
                try {
                    val ctx = appContext
                    if (ctx != null) {
                        OrionLogger.debug("🔋 App moved to foreground (from Flutter)")
                        BatteryMetricsTracker.onAppForegrounded(ctx)
                        WakeLockTracker.onAppForeground()
                        flutterBatterySessionStarted = true
                    }
                    result.success("app_foreground_tracked")
                } catch (e: Exception) {
                    result.error("APP_FOREGROUND_ERROR", e.message, null)
                }
            }

            "onAppBackground" -> {
                try {
                    val ctx = appContext
                    if (ctx != null && flutterBatterySessionStarted) {
                        OrionLogger.debug("🔋 App moved to background (from Flutter)")
                        BatteryMetricsTracker.onAppBackgrounded(ctx)
                        WakeLockTracker.onAppBackground()
                    }
                    result.success("app_background_tracked")
                } catch (e: Exception) {
                    result.error("APP_BACKGROUND_ERROR", e.message, null)
                }
            }

            // ── Screen Tracking ───────────────────────────────────────────

            "trackFlutterScreen" -> {
                try {
                    val screenName      = call.argument<String>("screen") ?: "Unknown"
                    val ttid            = call.argument<Int>("ttid")          ?: -1
                    val ttfd            = call.argument<Int>("ttfd")          ?: -1
                    val ttfdManual      = call.argument<Boolean>("ttfdManual") ?: false
                    val jankyFrames     = call.argument<Int>("jankyFrames")   ?: 0
                    val frozenFrames    = call.argument<Int>("frozenFrames")  ?: 0
                    val networkRequests = call.argument<List<Map<String, Any>>>("network") ?: emptyList()
                    val runtimeMetricsJson = edOrionInstance?.getRuntimeMetrics()
                    val frameMetrics    = call.argument<Map<String, Any>>("frameMetrics")
                    val wentBg          = call.argument<Boolean>("wentBg") ?: false
                    val bgCount         = call.argument<Int>("bgCount")    ?: 0
                    val rageClicks      = call.argument<List<Map<String, Any>>>("rageClicks") ?: emptyList()
                    val rageClickCount  = call.argument<Int>("rageClickCount") ?: 0

                    OrionLogger.debug("Received screen = $screenName, rageClicks = $rageClickCount")

                    FlutterSendData().sendFlutterScreenMetrics(
                        screenName      = screenName,
                        ttid            = ttid,
                        ttfd            = ttfd,
                        ttfdManual      = ttfdManual,
                        jankyFrames     = jankyFrames,
                        frozenFrames    = frozenFrames,
                        networkRequests = networkRequests,
                        frameMetrics    = frameMetrics,
                        runtimeMetrics  = runtimeMetricsJson?.toString(),
                        wentBg          = wentBg,
                        bgCount         = bgCount,
                        rageClicks      = rageClicks,
                        rageClickCount  = rageClickCount
                    )
                    result.success("screen_tracked")
                } catch (e: Exception) {
                    Log.e("OrionFlutterPlugin", "Error tracking flutter screen: ${e.message}", e)
                    result.error("FLUTTER_SCREEN_TRACK", e.message, null)
                }
            }

            "trackFlutterError" -> {
                try {
                    val exception  = call.argument<String>("exception") ?: "Unknown exception"
                    val stack      = call.argument<String>("stack")     ?: "No stack trace"
                    val library    = call.argument<String>("library")   ?: ""
                    val contextStr = call.argument<String>("context")   ?: ""
                    val screenName = call.argument<String>("screen")    ?: "UnknownScreen"
                    val networkRaw = call.argument<ArrayList<HashMap<String, Any>>>("network")

                    val errorJson = JSONObject().apply {
                        put("source",    "flutter")
                        put("exception", exception)
                        put("stack",     stack)
                        put("library",   library)
                        put("context",   contextStr)
                        put("timestamp", System.currentTimeMillis())
                    }

                    FlutterCrashAnalyzer.sendFlutterCrash(errorJson, screenName, networkRaw)
                    result.success("flutter_error_tracked")
                } catch (e: Exception) {
                    Log.e("OrionFlutterPlugin", "Failed to track Flutter error: ${e.message}", e)
                    result.error("FLUTTER_ERROR_TRACKING", e.message, null)
                }
            }

            // ── Wake Lock Methods ─────────────────────────────────────────

            "wakeLockAcquire" -> {
                try {
                    val tag = call.argument<String>("tag")
                        ?: return result.error("MISSING_TAG", "tag is required", null)
                    val type      = call.argument<Int>("type")      ?: PowerManager.PARTIAL_WAKE_LOCK
                    val timeoutMs = call.argument<Int>("timeoutMs")?.toLong()
                    val ctx       = appContext
                        ?: return result.error("NO_CONTEXT", "Context not available", null)

                    try {
                        // ✅ Use getOrPut on ConcurrentHashMap — safe since onMethodCall
                        //    is dispatched on a single platform thread.
                        val wakeLock = dartWakeLocks.getOrPut(tag) {
                            val pm           = ctx.getSystemService(Context.POWER_SERVICE) as PowerManager
                            val nativeWakeLock = pm.newWakeLock(type, tag)
                            OrionWakeLock(nativeWakeLock, tag, type)
                        }

                        if (timeoutMs != null) wakeLock.acquire(timeoutMs) else wakeLock.acquire()

                        OrionLogger.debug("🔒 [Dart] Acquired wake lock '$tag'")
                        result.success(true)
                    } catch (se: SecurityException) {
                        OrionLogger.debug("⚠️ WAKE_LOCK permission not granted for '$tag'")
                        WakeLockTracker.trackAcquire(tag, type, timeoutMs)
                        result.success(false)
                    }
                } catch (e: Exception) {
                    Log.e("OrionFlutterPlugin", "Error acquiring wake lock: ${e.message}", e)
                    result.error("WAKE_LOCK_ACQUIRE_ERROR", e.message, null)
                }
            }

            "wakeLockRelease" -> {
                try {
                    val tag = call.argument<String>("tag")
                        ?: return result.error("MISSING_TAG", "tag is required", null)

                    val wakeLock = dartWakeLocks.remove(tag)
                    if (wakeLock != null) {
                        wakeLock.release()
                        OrionLogger.debug("🔓 [Dart] Released wake lock '$tag'")
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                } catch (e: Exception) {
                    result.error("WAKE_LOCK_RELEASE_ERROR", e.message, null)
                }
            }

            "wakeLockTrackAcquire" -> {
                try {
                    val tag = call.argument<String>("tag")
                        ?: return result.error("MISSING_TAG", "tag is required", null)
                    val type      = call.argument<Int>("type")      ?: WakeLockTracker.TYPE_PARTIAL
                    val timeoutMs = call.argument<Int>("timeoutMs")?.toLong()
                    WakeLockTracker.trackAcquire(tag, type, timeoutMs)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("WAKE_LOCK_TRACK_ACQUIRE_ERROR", e.message, null)
                }
            }

            "wakeLockTrackRelease" -> {
                try {
                    val tag = call.argument<String>("tag")
                        ?: return result.error("MISSING_TAG", "tag is required", null)
                    WakeLockTracker.trackRelease(tag)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("WAKE_LOCK_TRACK_RELEASE_ERROR", e.message, null)
                }
            }

            "wakeLockSetStuckThreshold" -> {
                try {
                    val thresholdMs = call.argument<Int>("thresholdMs")?.toLong()
                        ?: return result.error("MISSING_THRESHOLD", "thresholdMs is required", null)
                    WakeLockTracker.setStuckThreshold(thresholdMs)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("WAKE_LOCK_SET_THRESHOLD_ERROR", e.message, null)
                }
            }

            "wakeLockGetActiveCount" -> {
                try {
                    result.success(WakeLockTracker.getActiveCount())
                } catch (e: Exception) {
                    result.error("WAKE_LOCK_GET_ACTIVE_COUNT_ERROR", e.message, null)
                }
            }

            "wakeLockIsHeld" -> {
                try {
                    val tag = call.argument<String>("tag")
                        ?: return result.error("MISSING_TAG", "tag is required", null)
                    result.success(WakeLockTracker.isHeld(tag))
                } catch (e: Exception) {
                    result.error("WAKE_LOCK_IS_HELD_ERROR", e.message, null)
                }
            }

            "wakeLockGetActiveTags" -> {
                try {
                    result.success(WakeLockTracker.getActiveTags())
                } catch (e: Exception) {
                    result.error("WAKE_LOCK_GET_ACTIVE_TAGS_ERROR", e.message, null)
                }
            }

            "wakeLockLogState" -> {
                try {
                    WakeLockTracker.logState()
                    result.success(true)
                } catch (e: Exception) {
                    result.error("WAKE_LOCK_LOG_STATE_ERROR", e.message, null)
                }
            }

            else -> result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        try {
            channel.setMethodCallHandler(null)
        } catch (e: Exception) {
            OrionLogger.error("OrionFlutterPlugin: error clearing method handler: ${e.message}")
        }

        try {
            val ctx = appContext
            if (ctx != null && flutterBatterySessionStarted) {
                OrionLogger.debug("🔋 Plugin detaching — marking app as backgrounded")
                BatteryMetricsTracker.onAppBackgrounded(ctx)
            }
        } catch (e: Exception) {
            OrionLogger.error("OrionFlutterPlugin: error backgrounding battery on detach: ${e.message}")
        }

        // Release any wake locks the Dart side left open.
        dartWakeLocks.forEach { (tag, wakeLock) ->
            try {
                if (wakeLock.isHeld()) {
                    OrionLogger.debug("🔓 Plugin detaching — releasing wake lock '$tag'")
                    wakeLock.release()
                }
            } catch (e: Exception) {
                OrionLogger.debug("⚠️ Error releasing wake lock '$tag' on detach: ${e.message}")
            }
        }

        try {
            dartWakeLocks.clear()
        } catch (e: Exception) {
            OrionLogger.error("OrionFlutterPlugin: error clearing wake locks on detach: ${e.message}")
        }

        flutterBatterySessionStarted = false
        currentFlutterScreen         = null
    }
}