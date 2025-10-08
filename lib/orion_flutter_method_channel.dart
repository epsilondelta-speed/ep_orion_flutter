import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'orion_flutter_platform_interface.dart';

class MethodChannelOrionFlutter extends OrionFlutterPlatform {
  static const MethodChannel _channel = MethodChannel('orion_flutter');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await _channel.invokeMethod<String>('getPlatformVersion');
    return version;
  }

  @override
  Future<String?> getRuntimeMetrics() async {
    final metrics = await _channel.invokeMethod<String>('getRuntimeMetrics');
    return metrics;
  }
}