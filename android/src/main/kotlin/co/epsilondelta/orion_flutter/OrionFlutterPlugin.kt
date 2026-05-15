package co.epsilondelta.orion_flutter

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * OrionFlutterPlugin — customer-facing plugin entry point.
 *
 * Directly implements FlutterPlugin and delegates all work to an internal
 * OrionFlutterPluginCore instance from the Maven AAR. This explicit-impl
 * pattern is required because Flutter's plugin discovery does not follow
 * Kotlin inheritance — it looks for FlutterPlugin in the class declaration
 * line of the file at the pluginClass path. Subclassing alone gets the
 * plugin silently skipped from GeneratedPluginRegistrant.
 *
 * The class is purely a thin proxy. The actual implementation (method
 * handlers, channel setup, lifecycle, trackers) all live in
 * OrionFlutterPluginCore inside co.epsilondelta:orion-flutter Maven AAR.
 */
class OrionFlutterPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private val core = OrionFlutterPluginCore()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        core.onAttachedToEngine(binding)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        core.onDetachedFromEngine(binding)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        core.onMethodCall(call, result)
    }
}
