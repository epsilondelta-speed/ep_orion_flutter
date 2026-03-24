/**
 * OrionFlutterPlugin — Main entry point for Orion hybrid Flutter SDK.
 *
 * Supported methods:
 * - initializeEdOrion(cid, pid)
 * - getRuntimeMetrics
 * - trackFlutterScreen(screen, ttid, ttfd, jankyFrames, frozenFrames, network[])
 * - trackFlutterError(exception, stack, library, context, screen, network[])
 *
 * NOTE:
 * - Do not manually initialize EdOrion from native code if using this plugin.
 * - For hybrid apps, you may still initialize native Orion if native activities need tracking.
 */
package co.epsilondelta.orion_flutter

import android.app.Application
import android.content.Context
import androidx.annotation.NonNull
import co.epsilondelta.orion_flutter.orion.EdOrion
import co.epsilondelta.orion_flutter.orion.util.FlutterSendData
import co.epsilondelta.orion_flutter.orion.util.OrionLogger
import co.epsilondelta.orion_flutter.orion.crash.FlutterCrashAnalyzer
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import org.json.JSONObject


class OrionFlutterPlugin : FlutterPlugin, MethodCallHandler {

    companion object {
        private const val TAG = "OrionFlutterPlugin"
        private const val CHANNEL_NAME = "orion_flutter"

        // Validation constants
        private const val MIN_CID_LENGTH = 4
        private const val MAX_CID_LENGTH = 50
        private const val MIN_PID_LENGTH = 1
        private const val MAX_PID_LENGTH = 50
    }

    private lateinit var channel: MethodChannel
    private var edOrionInstance: EdOrion? = null
    private var appContext: Context? = null
    private var application: Application? = null

    override fun onAttachedToEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)

        appContext = binding.applicationContext

        // Store application only if cast is safe
        if (appContext is Application) {
            application = appContext as Application
        } else {
            OrionLogger.warn("$TAG: Unable to cast context to Application")
        }

        OrionLogger.debug("$TAG: Plugin attached")
    }

    override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
        when (call.method) {

            "initializeEdOrion" -> handleInitialize(call, result)
            "getPlatformVersion" -> handleGetPlatformVersion(result)
            "getRuntimeMetrics" -> handleGetRuntimeMetrics(result)
            "trackFlutterScreen" -> handleTrackFlutterScreen(call, result)
            "trackFlutterError" -> handleTrackFlutterError(call, result)
            else -> result.notImplemented()
        }
    }

    /**
     * Handle SDK initialization with input validation.
     */
    private fun handleInitialize(call: MethodCall, result: Result) {
        try {
            // ✅ Validate CID
            val cid = call.argument<String>("cid")
            val cidValidation = validateCid(cid)
            if (cidValidation != null) {
                result.error("INVALID_CID", cidValidation, null)
                return
            }

            // ✅ Validate PID
            val pid = call.argument<String>("pid")
            val pidValidation = validatePid(pid)
            if (pidValidation != null) {
                result.error("INVALID_PID", pidValidation, null)
                return
            }

            // Check application context
            val app = application
            if (app == null) {
                result.error("INIT_ERROR", "Application context is null", null)
                return
            }

            // Initialize only once
            if (edOrionInstance == null) {
                edOrionInstance = EdOrion.Builder(app)
                    .setConfig(cid!!, pid!!)
                    .setLogEnable(BuildConfig.DEBUG)
                    .enableAnrMonitoring(true)
                    .build()
                edOrionInstance?.startListening()

                OrionLogger.debug("$TAG: Orion initialized with cid=$cid")
            } else {
                OrionLogger.debug("$TAG: Orion already initialized, skipping")
            }

            result.success("orion_initialized")

        } catch (e: Exception) {
            OrionLogger.error("$TAG: Initialization error: ${e.message}")
            result.error("ORION_INIT_ERROR", e.message, null)
        }
    }

    /**
     * Validate Company ID (CID).
     * @return Error message if invalid, null if valid
     */
    private fun validateCid(cid: String?): String? {
        return when {
            cid == null -> "cid is required"
            cid.isBlank() -> "cid cannot be empty or blank"
            cid.length < MIN_CID_LENGTH -> "cid must be at least $MIN_CID_LENGTH characters"
            cid.length > MAX_CID_LENGTH -> "cid cannot exceed $MAX_CID_LENGTH characters"
            !cid.matches(Regex("^[a-zA-Z0-9_-]+$")) -> "cid contains invalid characters (only alphanumeric, underscore, hyphen allowed)"
            else -> null
        }
    }

    /**
     * Validate Product ID (PID).
     * @return Error message if invalid, null if valid
     */
    private fun validatePid(pid: String?): String? {
        return when {
            pid == null -> "pid is required"
            pid.isBlank() -> "pid cannot be empty or blank"
            pid.length < MIN_PID_LENGTH -> "pid must be at least $MIN_PID_LENGTH character"
            pid.length > MAX_PID_LENGTH -> "pid cannot exceed $MAX_PID_LENGTH characters"
            !pid.matches(Regex("^[a-zA-Z0-9_-]+$")) -> "pid contains invalid characters (only alphanumeric, underscore, hyphen allowed)"
            else -> null
        }
    }

    /**
     * Handle platform version request.
     */
    private fun handleGetPlatformVersion(result: Result) {
        result.success("Android ${android.os.Build.VERSION.RELEASE}")
    }

    /**
     * Handle runtime metrics request.
     */
    private fun handleGetRuntimeMetrics(result: Result) {
        try {
            val metrics = edOrionInstance?.getRuntimeMetrics()?.toString() ?: "{}"
            result.success(metrics)
        } catch (e: Exception) {
            OrionLogger.error("$TAG: Error getting runtime metrics: ${e.message}")
            result.success("{}")  // Return empty JSON instead of error
        }
    }

    /**
     * Handle Flutter screen tracking.
     */
    private fun handleTrackFlutterScreen(call: MethodCall, result: Result) {
        try {
            val screenName = call.argument<String>("screen")?.takeIf { it.isNotBlank() } ?: "Unknown"
            val ttid = call.argument<Int>("ttid") ?: -1
            val ttfd = call.argument<Int>("ttfd") ?: -1
            val jankyFrames = call.argument<Int>("jankyFrames") ?: 0
            val frozenFrames = call.argument<Int>("frozenFrames") ?: 0
            val networkRequests = call.argument<List<Map<String, Any>>>("network") ?: emptyList()
            val frameMetrics = call.argument<Map<String, Any>>("frameMetrics")

            // Get runtime metrics safely
            val runtimeMetricsJson = try {
                edOrionInstance?.getRuntimeMetrics()
            } catch (e: Exception) {
                null
            }

            OrionLogger.debug("$TAG: Tracking screen: $screenName")

            FlutterSendData().sendFlutterScreenMetrics(
                screenName = screenName,
                ttid = ttid,
                ttfd = ttfd,
                jankyFrames = jankyFrames,
                frozenFrames = frozenFrames,
                networkRequests = networkRequests,
                frameMetrics = frameMetrics,
                runtimeMetrics = runtimeMetricsJson?.toString()
            )

            result.success("screen_tracked")

        } catch (e: Exception) {
            OrionLogger.error("$TAG: Error tracking screen: ${e.message}")
            result.error("FLUTTER_SCREEN_TRACK", e.message, null)
        }
    }

    /**
     * Handle Flutter error tracking.
     */
    private fun handleTrackFlutterError(call: MethodCall, result: Result) {
        try {
            val exception = call.argument<String>("exception")?.takeIf { it.isNotBlank() }
                ?: "Unknown exception"
            val stack = call.argument<String>("stack")?.takeIf { it.isNotBlank() }
                ?: "No stack trace"
            val library = call.argument<String>("library") ?: ""
            val contextStr = call.argument<String>("context") ?: ""
            val screenName = call.argument<String>("screen")?.takeIf { it.isNotBlank() }
                ?: "UnknownScreen"
            val networkRaw = call.argument<ArrayList<HashMap<String, Any>>>("network")

            // Prepare error payload
            val errorJson = JSONObject().apply {
                put("source", "flutter")
                put("exception", exception)
                put("stack", stack)
                put("library", library)
                put("context", contextStr)
                put("timestamp", System.currentTimeMillis())
            }

            OrionLogger.debug("$TAG: Tracking Flutter error on screen: $screenName")

            // Send error report
            FlutterCrashAnalyzer.sendFlutterCrash(errorJson, screenName, networkRaw)

            result.success("flutter_error_tracked")

        } catch (e: Exception) {
            OrionLogger.error("$TAG: Error tracking Flutter error: ${e.message}")
            result.error("FLUTTER_ERROR_TRACKING", e.message, null)
        }
    }

    override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        OrionLogger.debug("$TAG: Plugin detached")
    }
}