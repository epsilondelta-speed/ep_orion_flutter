package co.epsilondelta.orion_flutter

/**
 * OrionFlutterPlugin — thin wrapper exposing the Orion Flutter plugin
 * entry point to customer apps.
 *
 * The actual implementation lives in OrionFlutterPluginCore, which is
 * shipped via the co.epsilondelta:orion-flutter Maven AAR (see
 * android/build.gradle). This wrapper exists only to satisfy Flutter's
 * pluginClass discovery requirement (pubspec.yaml's `pluginClass:
 * OrionFlutterPlugin`) without producing a duplicate class.
 *
 * Resolves duplicate-class errors that previously required customers
 * to add a subprojects/afterEvaluate workaround in their build.gradle.
 */
class OrionFlutterPlugin : OrionFlutterPluginCore()
