/// OrionDioInterceptor
///
/// Automatically tracks HTTP requests/responses/errors per screen.
///
/// Usage:
/// ```dart
/// final dio = Dio();
/// dio.interceptors.add(OrionDioInterceptor());
/// ```
///
/// Features:
/// - Tracks request timing (start, end, duration)
/// - Captures response status codes and payload sizes
/// - Records errors with messages
/// - Associates requests with current screen
///
/// Requirements:
/// - Set current screen via OrionNetworkTracker.setCurrentScreen() or use OrionScreenTracker
/// - Works with both OrionScreenTracker (automatic) and OrionManualTracker (manual)
///
/// Compatibility:
/// - Dio 4.x: Uses DioError (deprecated but supported)
/// - Dio 5.x: Uses DioException (recommended)

import 'dart:io';
import 'package:dio/dio.dart';
import 'package:orion_flutter/orion_network_tracker.dart';
import 'package:orion_flutter/orion_logger.dart';
import 'orion_flutter.dart';

class OrionDioInterceptor extends Interceptor {

  /// Optional: Enable verbose logging
  final bool verbose;

  OrionDioInterceptor({
    this.verbose = false,
  });

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (!OrionFlutter.isSupported) {
      return handler.next(options);
    }

    // Record start time
    options.extra['startTime'] = DateTime.now().millisecondsSinceEpoch;

    if (verbose) {
      orionPrint("🌐 [Orion] Request: ${options.method} ${options.uri}");
    }

    super.onRequest(options, handler);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    if (OrionFlutter.isSupported) {
      // Extract server processing time header (if available)
      final processingTimeStr = response.headers['x-response-time']?.first;
      final processingTime = int.tryParse(processingTimeStr ?? '') ?? 0;

      _trackRequest(
        response.requestOptions,
        response.statusCode ?? -1,
        payload: response.data,
        contentType: response.headers[HttpHeaders.contentTypeHeader]?.first,
        actualTime: processingTime,
      );

      if (verbose) {
        orionPrint("✅ [Orion] Response: ${response.statusCode} ${response.requestOptions.uri}");
      }
    }

    super.onResponse(response, handler);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (OrionFlutter.isSupported) {
      final statusCode = err.response?.statusCode ?? -1;

      orionPrint(
          "🔴 [Orion] Error: [${err.requestOptions.method}] ${err.requestOptions.uri} | "
              "Status: $statusCode | ${err.type.name}: ${err.message}"
      );

      _trackRequest(
        err.requestOptions,
        statusCode,
        error: _formatErrorMessage(err),
        contentType: err.response?.headers[HttpHeaders.contentTypeHeader]?.first,
        actualTime: 0,
      );
    }

    super.onError(err, handler);
  }

  /// Format error message with type information
  String _formatErrorMessage(DioException err) {
    final buffer = StringBuffer();

    // Add error type
    buffer.write('[${err.type.name}] ');

    // Add message
    if (err.message != null && err.message!.isNotEmpty) {
      buffer.write(err.message);
    } else {
      // Provide default message based on type
      switch (err.type) {
        case DioExceptionType.connectionTimeout:
          buffer.write('Connection timeout');
          break;
        case DioExceptionType.sendTimeout:
          buffer.write('Send timeout');
          break;
        case DioExceptionType.receiveTimeout:
          buffer.write('Receive timeout');
          break;
        case DioExceptionType.badCertificate:
          buffer.write('Bad SSL certificate');
          break;
        case DioExceptionType.badResponse:
          buffer.write('Bad response: ${err.response?.statusCode}');
          break;
        case DioExceptionType.cancel:
          buffer.write('Request cancelled');
          break;
        case DioExceptionType.connectionError:
          buffer.write('Connection error');
          break;
        case DioExceptionType.unknown:
        default:
          buffer.write('Unknown error');
          break;
      }
    }

    return buffer.toString();
  }

  /// Track request in OrionNetworkTracker
  void _trackRequest(
      RequestOptions options,
      int statusCode, {
        String? error,
        dynamic payload,
        String? contentType,
        int actualTime = 0,
      }) {
    final startTime = options.extra['startTime'] as int?;
    final endTime = DateTime.now().millisecondsSinceEpoch;

    if (startTime == null) {
      orionPrint("⚠️ [Orion] Missing startTime for ${options.uri}");
      return;
    }

    final duration = endTime - startTime;
    final screen = OrionNetworkTracker.currentScreenName ?? "UnknownScreen";
    final payloadSize = _getPayloadSize(payload);

    OrionNetworkTracker.addRequest(screen, {
      "method": options.method,
      "url": options.uri.toString(),
      "statusCode": statusCode,
      "startTime": startTime,
      "endTime": endTime,
      "duration": duration,
      "payloadSize": payloadSize,
      "contentType": contentType,
      "responseType": options.responseType.toString(),
      "errorMessage": error,
      "actualTime": actualTime,
    });
  }

  /// Calculate payload size
  int? _getPayloadSize(dynamic data) {
    if (data == null) return null;

    try {
      if (data is List<int>) return data.length;
      if (data is String) return data.length;
      if (data is Map || data is List) {
        // Limit toString() to avoid memory issues with large payloads
        final str = data.toString();
        return str.length > 100000 ? 100000 : str.length;
      }
    } catch (e) {
      orionPrint("⚠️ [Orion] Error calculating payload size: $e");
    }

    return null;
  }
}