import 'package:flutter/foundation.dart';

/// Simple logger for Orion plugin.
/// Automatically tags all logs with [OrionFlutter]
void orionPrint(String? message) {
  if (kDebugMode && message != null) {
    print("OrionFlutter: $message");
  }
}