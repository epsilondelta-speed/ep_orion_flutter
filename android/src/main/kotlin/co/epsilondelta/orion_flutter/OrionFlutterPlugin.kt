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
import android.util.Log
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

    private lateinit var channel: MethodChannel
    private var edOrionInstance: EdOrion? = null
    private var appContext: Context? = null
    private var application: Application? = null

    override fun onAttachedToEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "orion_flutter")
        channel.setMethodCallHandler(this)

        appContext = binding.applicationContext

        // ✅ Store application only if cast is safe
        if (appContext is Application) {
            application = appContext as Application
        } else {
            OrionLogger.debug( "⚠️ Unable to cast context to Application")
        }
        OrionLogger.debug( "Plugin attached")

    }

    override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
        when (call.method) {

            // 👉 This plugin exposes Orion SDK functions to Flutter.
            // Clients should NOT manually call EdOrion.Builder() in this file.
            // Instead, they should call `OrionFlutter.initializeEdOrion()` from Dart.
            // The plugin will initialize EdOrion instance here, only once.

            "initializeEdOrion" -> {
                try {
                    val cid = call.argument<String>("cid") ?: return result.error("MISSING_CID", "cid is required", null)
                    val pid = call.argument<String>("pid") ?: return result.error("MISSING_PID", "pid is required", null)


                    val app = application

                    if (app == null) {
                        result.error("INIT_ERROR", "Application context is null for OrionDartPlugin", null)
                        return
                    }

                    if (edOrionInstance == null) {
                    edOrionInstance = EdOrion.Builder(app)
                        .setConfig(cid, pid)
                        .setLogEnable(true)
                        .enableAnrMonitoring(true)
                        .build()
                    edOrionInstance?.startListening()
                    }

                    OrionLogger.debug( "Orion initialized via Dart")
                        result.success("orion_initialized")
                } catch (e: Exception) {
                    OrionLogger.debug( "⚠️ binding.applicationContext is not an Application")
                    result.error("ORION_INIT_ERROR", e.message, null)
                }

            }

            "getPlatformVersion" -> {
                result.success("Android ${android.os.Build.VERSION.RELEASE}")
            }

            "getRuntimeMetrics" -> {
                OrionLogger.debug( "Returning Orion runtime metrics")
                val metrics = edOrionInstance?.getRuntimeMetrics()?.toString() ?: "Not available"
                result.success(metrics)
            }


            "trackFlutterScreen" -> {
                try {
                    val screenName = call.argument<String>("screen") ?: "Unknown"
                    val ttid = call.argument<Int>("ttid") ?: -1
                    val ttfd = call.argument<Int>("ttfd") ?: -1
                    val jankyFrames = call.argument<Int>("jankyFrames") ?: 0
                    val frozenFrames = call.argument<Int>("frozenFrames") ?: 0
                    val networkRequests = call.argument<List<Map<String, Any>>>("network") ?: emptyList()
                    val runtimeMetricsJson = edOrionInstance?.getRuntimeMetrics()

                    OrionLogger.debug( "Received screen = $screenName")
                    //OrionLogger.debug( "runtimeMetricsJson payload = $runtimeMetricsJson")
                    FlutterSendData().sendFlutterScreenMetrics(
                        screenName = screenName,
                        ttid = ttid,
                        ttfd = ttfd,
                        jankyFrames = jankyFrames,
                        frozenFrames = frozenFrames,
                        networkRequests = networkRequests,
                        runtimeMetrics = runtimeMetricsJson?.toString()
                    )

                    result.success("screen_tracked")
                } catch (e: Exception) {
                    Log.e("OrionDartPlugin", "Error tracking flutter screen: ${e.message}", e)
                    result.error("FLUTTER_SCREEN_TRACK", e.message, null)
                }
            }

            "trackFlutterError" -> {
                try {
                    val exception = call.argument<String>("exception") ?: "Unknown exception"
                    val stack = call.argument<String>("stack") ?: "No stack trace"
                    val library = call.argument<String>("library") ?: ""
                    val contextStr = call.argument<String>("context") ?: ""
                    val screenName = call.argument<String>("screen") ?: "UnknownScreen"
                    val networkRaw = call.argument<ArrayList<HashMap<String, Any>>>("network")

                    // 🔧 Prepare error payload
                    val errorJson = JSONObject().apply {
                        put("source", "flutter")
                        put("exception", exception)
                        put("stack", stack)
                        put("library", library)
                        put("context", contextStr)
                        put("timestamp", System.currentTimeMillis())
                    }

                    //Log.e("OrionFlutterPlugin", "🔥 Flutter error captured: $errorJson")

                    // 🚀 Send full error object with screen + network
                    FlutterCrashAnalyzer.sendFlutterCrash(errorJson, screenName, networkRaw)

                    result.success("flutter_error_tracked")
                } catch (e: Exception) {
                    Log.e("OrionDartPlugin", "Failed to track Flutter error: ${e.message}", e)
                    result.error("FLUTTER_ERROR_TRACKING", e.message, null)
                }
            }

            else -> result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }
}