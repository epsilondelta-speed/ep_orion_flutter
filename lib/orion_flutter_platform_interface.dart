import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'orion_flutter_method_channel.dart';

abstract class OrionFlutterPlatform extends PlatformInterface {
  OrionFlutterPlatform() : super(token: _token);

  static final Object _token = Object();

  static OrionFlutterPlatform _instance = MethodChannelOrionFlutter();

  static OrionFlutterPlatform get instance => _instance;

  static set instance(OrionFlutterPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion();
  Future<String?> getRuntimeMetrics();
}