import 'dart:io';
import 'package:flutter/foundation.dart';
import 'orion_network_tracker.dart';

/// OrionHttpOverrides — Global HTTP interceptor for Orion SDK.
///
/// Intercepts ALL dart:io HTTP requests — including:
/// - cached_network_image (flutter_cache_manager)
/// - http package
/// - Any non-Dio HTTP client
///
/// Usage — add ONE line to main() before runApp:
/// ```dart
/// void main() {
///   HttpOverrides.global = OrionHttpOverrides();
///   OrionFlutter.initializeEdOrion(cid: '...', pid: '...');
///   runApp(MyApp());
/// }
/// ```
///
/// Works alongside OrionDioInterceptor — Dio requests are tracked by
/// OrionDioInterceptor, all other HTTP is tracked here.
/// No duplicate tracking — Dio bypasses dart:io HttpClient.
class OrionHttpOverrides extends HttpOverrides {

  /// Optional: previous overrides to chain (preserves existing overrides)
  final HttpOverrides? _previous;

  /// Max URL length to store — caps long image URLs
  static const int _maxUrlLength = 200;

  OrionHttpOverrides({HttpOverrides? previous}) : _previous = previous;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    // Chain with previous overrides if any existed
    final client = _previous != null
        ? _previous!.createHttpClient(context)
        : super.createHttpClient(context);

    return _OrionHttpClient(client);
  }

  /// Install globally — call once in main() before runApp.
  /// Safely chains with any existing HttpOverrides.
  static void install() {
    final existing = HttpOverrides.current;
    HttpOverrides.global = OrionHttpOverrides(previous: existing);
    debugPrint('[Orion] HttpOverrides: installed — tracking all HTTP requests');
  }
}

// ─── Wrapped HttpClient ────────────────────────────────────────────────────

class _OrionHttpClient implements HttpClient {
  final HttpClient _inner;

  _OrionHttpClient(this._inner);

  // ─── Intercept all open methods ──────────────────────────────────────────

  @override
  Future<HttpClientRequest> open(
      String method, String host, int port, String path) async {
    final url = _buildUrl(host, port, path);
    return _OrionHttpClientRequest(
      await _inner.open(method, host, port, path),
      method: method,
      url: url,
    );
  }

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    return _OrionHttpClientRequest(
      await _inner.openUrl(method, url),
      method: method,
      url: _capUrl(url.toString()),
    );
  }

  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      open('GET', host, port, path);

  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);

  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      open('POST', host, port, path);

  @override
  Future<HttpClientRequest> postUrl(Uri url) => openUrl('POST', url);

  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      open('PUT', host, port, path);

  @override
  Future<HttpClientRequest> putUrl(Uri url) => openUrl('PUT', url);

  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      open('DELETE', host, port, path);

  @override
  Future<HttpClientRequest> deleteUrl(Uri url) => openUrl('DELETE', url);

  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      open('PATCH', host, port, path);

  @override
  Future<HttpClientRequest> patchUrl(Uri url) => openUrl('PATCH', url);

  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      open('HEAD', host, port, path);

  @override
  Future<HttpClientRequest> headUrl(Uri url) => openUrl('HEAD', url);

  // ─── Delegate all other properties ───────────────────────────────────────

  @override
  bool get autoUncompress => _inner.autoUncompress;
  @override
  set autoUncompress(bool v) => _inner.autoUncompress = v;

  @override
  Duration? get connectionTimeout => _inner.connectionTimeout;
  @override
  set connectionTimeout(Duration? v) => _inner.connectionTimeout = v;

  @override
  Duration get idleTimeout => _inner.idleTimeout;
  @override
  set idleTimeout(Duration v) => _inner.idleTimeout = v;

  @override
  int? get maxConnectionsPerHost => _inner.maxConnectionsPerHost;
  @override
  set maxConnectionsPerHost(int? v) => _inner.maxConnectionsPerHost = v;

  @override
  String? get userAgent => _inner.userAgent;
  @override
  set userAgent(String? v) => _inner.userAgent = v;

  @override
  void addCredentials(
          Uri url, String realm, HttpClientCredentials credentials) =>
      _inner.addCredentials(url, realm, credentials);

  @override
  void addProxyCredentials(
          String host, int port, String realm, HttpClientCredentials credentials) =>
      _inner.addProxyCredentials(host, port, realm, credentials);

  @override
  set authenticate(
          Future<bool> Function(Uri url, String scheme, String? realm)? f) =>
      _inner.authenticate = f;

  @override
  set authenticateProxy(
          Future<bool> Function(
                  String host, int port, String scheme, String? realm)?
              f) =>
      _inner.authenticateProxy = f;

  @override
  set badCertificateCallback(
          bool Function(X509Certificate cert, String host, int port)?
              callback) =>
      _inner.badCertificateCallback = callback;

  @override
  set findProxy(String Function(Uri url)? f) => _inner.findProxy = f;

  @override
  void close({bool force = false}) => _inner.close(force: force);

  @override
  set connectionFactory(
    Future<ConnectionTask<Socket>> Function(
            Uri url, String? proxyHost, int? proxyPort)?
        f,
  ) =>
      _inner.connectionFactory = f;

  @override
  set keyLog(Function(String line)? callback) => _inner.keyLog = callback;

  // ─── Helpers ──────────────────────────────────────────────────────────────

  String _buildUrl(String host, int port, String path) {
    final portStr = (port == 80 || port == 443) ? '' : ':$port';
    final scheme = port == 443 ? 'https' : 'http';
    return _capUrl('$scheme://$host$portStr$path');
  }

  String _capUrl(String url) {
    if (url.length <= _maxUrlLength) return url;
    try {
      final uri = Uri.tryParse(url);
      if (uri == null) return url.substring(0, _maxUrlLength);
      final base = '${uri.scheme}://${uri.host}${uri.path}';
      final query = uri.query;
      if (query.isEmpty) return base;
      final cappedQuery =
          query.length > 50 ? query.substring(0, 50) : query;
      return '$base?$cappedQuery';
    } catch (_) {
      return url.substring(0, _maxUrlLength);
    }
  }
}

// ─── Wrapped HttpClientRequest ─────────────────────────────────────────────

class _OrionHttpClientRequest implements HttpClientRequest {
  final HttpClientRequest _inner;
  final String method;
  final String url;
  final int _startTime;

  _OrionHttpClientRequest(
    this._inner, {
    required this.method,
    required this.url,
  }) : _startTime = DateTime.now().millisecondsSinceEpoch;

  @override
  Future<HttpClientResponse> close() async {
    try {
      final response = await _inner.close();
      _track(response.statusCode,
          contentLength: response.contentLength);
      return response;
    } catch (e) {
      _trackError(e.toString());
      rethrow;
    }
  }

  void _track(int statusCode, {int contentLength = -1}) {
    final endTime   = DateTime.now().millisecondsSinceEpoch;
    final duration  = endTime - _startTime;
    final screen    = OrionNetworkTracker.currentScreenName ?? 'UnknownScreen';

    OrionNetworkTracker.addRequest(screen, {
      'method':      method,
      'url':         url,
      'statusCode':  statusCode,
      'startTime':   _startTime,
      'endTime':     endTime,
      'duration':    duration,
      'payloadSize': contentLength > 0 ? contentLength : null,
      'contentType': _inferContentType(url),
    });
  }

  void _trackError(String error) {
    final endTime  = DateTime.now().millisecondsSinceEpoch;
    final screen   = OrionNetworkTracker.currentScreenName ?? 'UnknownScreen';

    OrionNetworkTracker.addRequest(screen, {
      'method':       method,
      'url':          url,
      'statusCode':   -1,
      'startTime':    _startTime,
      'endTime':      endTime,
      'duration':     endTime - _startTime,
      'errorMessage': error,
      'contentType':  _inferContentType(url),
    });
  }

  /// Infer content type from URL extension — useful for image requests
  String _inferContentType(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('.jpg') || lower.contains('.jpeg')) return 'image/jpeg';
    if (lower.contains('.png'))  return 'image/png';
    if (lower.contains('.webp')) return 'image/webp';
    if (lower.contains('.gif'))  return 'image/gif';
    if (lower.contains('.svg'))  return 'image/svg';
    if (lower.contains('.json')) return 'application/json';
    return 'other';
  }

  // ─── Delegate all other members ──────────────────────────────────────────

  @override
  void abort([Object? exception, StackTrace? stackTrace]) =>
      _inner.abort(exception, stackTrace);

  @override
  void add(List<int> data) => _inner.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);

  @override
  Future addStream(Stream<List<int>> stream) => _inner.addStream(stream);

  @override
  HttpConnectionInfo? get connectionInfo => _inner.connectionInfo;

  @override
  List<Cookie> get cookies => _inner.cookies;

  @override
  Future<HttpClientResponse> get done => _inner.done;

  @override
  Future flush() => _inner.flush();

  @override
  HttpHeaders get headers => _inner.headers;

  @override
  String get method => _inner.method;

  @override
  Uri get uri => _inner.uri;

  @override
  bool get bufferOutput => _inner.bufferOutput;
  @override
  set bufferOutput(bool v) => _inner.bufferOutput = v;

  @override
  int get contentLength => _inner.contentLength;
  @override
  set contentLength(int v) => _inner.contentLength = v;

  @override
  Encoding get encoding => _inner.encoding;
  @override
  set encoding(Encoding v) => _inner.encoding = v;

  @override
  bool get followRedirects => _inner.followRedirects;
  @override
  set followRedirects(bool v) => _inner.followRedirects = v;

  @override
  int get maxRedirects => _inner.maxRedirects;
  @override
  set maxRedirects(int v) => _inner.maxRedirects = v;

  @override
  bool get persistentConnection => _inner.persistentConnection;
  @override
  set persistentConnection(bool v) => _inner.persistentConnection = v;

  @override
  Future<HttpClientResponse> get response => _inner.response;

  @override
  Future write(Object? object) => _inner.write(object);

  @override
  Future writeln([Object? object = '']) => _inner.writeln(object);

  @override
  Future writeAll(Iterable objects, [String separator = '']) =>
      _inner.writeAll(objects, separator);

  @override
  Future writeCharCode(int charCode) => _inner.writeCharCode(charCode);
}
