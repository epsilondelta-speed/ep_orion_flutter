/// OrionDioInterceptor — automatically tracks Dio HTTP requests per screen.
///
/// Sampling kill-switch: _trackRequest() returns immediately when
/// SamplingManager.instance.isTrackingEnabled is false so no data is
/// collected when the remote kill-switch is active.

import 'dart:io';
import 'package:dio/dio.dart';
import 'package:orion_flutter/orion_network_tracker.dart';
import 'package:orion_flutter/orion_logger.dart';
import 'orion_flutter.dart';
import 'orion_sampling_manager.dart';

class OrionDioInterceptor extends Interceptor {

  final bool verbose;

  OrionDioInterceptor({this.verbose = false});

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    try {
      if (OrionFlutter.isSupported && SamplingManager.instance.isTrackingEnabled) {
        options.extra['startTime'] = DateTime.now().millisecondsSinceEpoch;
        if (verbose) {
          orionPrint('🌐 [Orion] Request: ${options.method} ${options.uri}');
        }
      }
    } catch (e) {
      orionPrint('⚠️ [Orion] onRequest tracking error (ignored): $e');
    } finally {
      handler.next(options);
    }
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    try {
      if (OrionFlutter.isSupported) {
        final processingTimeStr = response.headers['x-response-time']?.first;
        final processingTime    = int.tryParse(processingTimeStr ?? '') ?? 0;

        _trackRequest(
          response.requestOptions,
          response.statusCode ?? -1,
          payload:     response.data,
          contentType: response.headers[HttpHeaders.contentTypeHeader]?.first,
          actualTime:  processingTime,
        );

        if (verbose) {
          orionPrint('✅ [Orion] Response: ${response.statusCode} '
              '${response.requestOptions.uri}');
        }
      }
    } catch (e) {
      orionPrint('⚠️ [Orion] onResponse tracking error (ignored): $e');
    } finally {
      handler.next(response);
    }
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    try {
      if (OrionFlutter.isSupported) {
        final statusCode = err.response?.statusCode ?? -1;
        orionPrint('🔴 [Orion] Error: [${err.requestOptions.method}] '
            '${err.requestOptions.uri} | Status: $statusCode | '
            '${err.type.name}: ${err.message}');

        _trackRequest(
          err.requestOptions,
          statusCode,
          error:       _formatErrorMessage(err),
          contentType: err.response?.headers[HttpHeaders.contentTypeHeader]?.first,
          actualTime:  0,
        );
      }
    } catch (e) {
      orionPrint('⚠️ [Orion] onError tracking error (ignored): $e');
    } finally {
      handler.next(err);
    }
  }

  // ── Private helpers ───────────────────────────────────────────────────────

  String _formatErrorMessage(DioException err) {
    try {
      final buffer = StringBuffer('[${err.type.name}] ');
      if (err.message != null && err.message!.isNotEmpty) {
        buffer.write(err.message);
      } else {
        switch (err.type) {
          case DioExceptionType.connectionTimeout:
            buffer.write('Connection timeout'); break;
          case DioExceptionType.sendTimeout:
            buffer.write('Send timeout'); break;
          case DioExceptionType.receiveTimeout:
            buffer.write('Receive timeout'); break;
          case DioExceptionType.badCertificate:
            buffer.write('Bad SSL certificate'); break;
          case DioExceptionType.badResponse:
            buffer.write('Bad response: ${err.response?.statusCode}'); break;
          case DioExceptionType.cancel:
            buffer.write('Request cancelled'); break;
          case DioExceptionType.connectionError:
            buffer.write('Connection error'); break;
          default:
            buffer.write('Unknown error'); break;
        }
      }
      return buffer.toString();
    } catch (e) {
      return 'Error formatting message: $e';
    }
  }

  void _trackRequest(
    RequestOptions options,
    int statusCode, {
    String? error,
    dynamic payload,
    String? contentType,
    int actualTime = 0,
  }) {
    try {
      // ✅ Sampling kill-switch: skip collection when tracking is disabled.
      if (!SamplingManager.instance.isTrackingEnabled) return;

      final startTime = options.extra['startTime'] as int?;
      final endTime   = DateTime.now().millisecondsSinceEpoch;

      if (startTime == null) {
        orionPrint('⚠️ [Orion] Missing startTime for ${options.uri}');
        return;
      }

      final duration    = endTime - startTime;
      final screen      = OrionNetworkTracker.currentScreenName ?? 'UnknownScreen';
      final payloadSize = _getPayloadSize(payload);

      // addRequest already filters SDK-internal URLs via OrionNetworkTracker.
      OrionNetworkTracker.addRequest(screen, {
        'method':       options.method,
        'url':          options.uri.toString(),
        'statusCode':   statusCode,
        'startTime':    startTime,
        'endTime':      endTime,
        'duration':     duration,
        'payloadSize':  payloadSize,
        'contentType':  contentType,
        'responseType': options.responseType.toString(),
        'errorMessage': error,
        'actualTime':   actualTime,
      });
    } catch (e) {
      orionPrint('⚠️ [Orion] _trackRequest error (ignored): $e');
    }
  }

  int? _getPayloadSize(dynamic data) {
    if (data == null) return null;
    try {
      if (data is List<int>) return data.length;
      if (data is String)    return data.length;
      if (data is Map || data is List) {
        final str = data.toString();
        return str.length > 100000 ? 100000 : str.length;
      }
    } catch (e) {
      orionPrint('⚠️ [Orion] Error calculating payload size (ignored): $e');
    }
    return null;
  }
}
