import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'orion_network_tracker.dart';

/// OrionHttpOverrides — Global HTTP interceptor for Orion SDK.
/// Intercepts ALL dart:io HTTP requests including cached_network_image.
///
/// Usage — add ONE line to main() before runApp:
/// ```dart
/// void main() {
///   HttpOverrides.global = OrionHttpOverrides();
///   OrionFlutter.initializeEdOrion(cid: '...', pid: '...');
///   runApp(MyApp());
/// }
/// ```
class OrionHttpOverrides extends HttpOverrides {

  final HttpOverrides? _previous;

  OrionHttpOverrides({HttpOverrides? previous}) : _previous = previous;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = _previous != null
        ? _previous!.createHttpClient(context)
        : super.createHttpClient(context);
    return _OrionHttpClient(client);
  }

  /// Install globally — safely chains with any existing HttpOverrides.
  static void install() {
    final existing = HttpOverrides.current;
    HttpOverrides.global = OrionHttpOverrides(previous: existing);
    debugPrint('[Orion] HttpOverrides: installed');
  }
}

// ─── Top-level helpers ───────────────────────────────────────────────────────

const int _kMaxUrlLength = 200;

String _capUrl(String url) {
  if (url.length <= _kMaxUrlLength) return url;
  try {
    final uri = Uri.tryParse(url);
    if (uri == null) return url.substring(0, _kMaxUrlLength);
    final base = '${uri.scheme}://${uri.host}${uri.path}';
    final query = uri.query;
    if (query.isEmpty) return base;
    return '$base?${query.length > 50 ? query.substring(0, 50) : query}';
  } catch (_) {
    return url.substring(0, _kMaxUrlLength);
  }
}

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

// ─── Wrapped HttpClient ──────────────────────────────────────────────────────

class _OrionHttpClient implements HttpClient {
  final HttpClient _inner;
  _OrionHttpClient(this._inner);

  String _buildUrl(String host, int port, String path) {
    final scheme  = port == 443 ? 'https' : 'http';
    final portStr = (port == 80 || port == 443) ? '' : ':$port';
    return _capUrl('$scheme://$host$portStr$path');
  }

  @override
  Future<HttpClientRequest> open(
      String method, String host, int port, String path) async {
    final req = await _inner.open(method, host, port, path);
    return _OrionHttpClientRequest(
        req, httpMethod: method, trackedUrl: _buildUrl(host, port, path));
  }

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    final req = await _inner.openUrl(method, url);
    return _OrionHttpClientRequest(
        req, httpMethod: method, trackedUrl: _capUrl(url.toString()));
  }

  @override Future<HttpClientRequest> get(String host, int port, String path) =>
      open('GET', host, port, path);
  @override Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);
  @override Future<HttpClientRequest> post(String host, int port, String path) =>
      open('POST', host, port, path);
  @override Future<HttpClientRequest> postUrl(Uri url) => openUrl('POST', url);
  @override Future<HttpClientRequest> put(String host, int port, String path) =>
      open('PUT', host, port, path);
  @override Future<HttpClientRequest> putUrl(Uri url) => openUrl('PUT', url);
  @override Future<HttpClientRequest> delete(String host, int port, String path) =>
      open('DELETE', host, port, path);
  @override Future<HttpClientRequest> deleteUrl(Uri url) =>
      openUrl('DELETE', url);
  @override Future<HttpClientRequest> patch(String host, int port, String path) =>
      open('PATCH', host, port, path);
  @override Future<HttpClientRequest> patchUrl(Uri url) =>
      openUrl('PATCH', url);
  @override Future<HttpClientRequest> head(String host, int port, String path) =>
      open('HEAD', host, port, path);
  @override Future<HttpClientRequest> headUrl(Uri url) =>
      openUrl('HEAD', url);

  @override bool get autoUncompress => _inner.autoUncompress;
  @override set autoUncompress(bool v) => _inner.autoUncompress = v;
  @override Duration? get connectionTimeout => _inner.connectionTimeout;
  @override set connectionTimeout(Duration? v) =>
      _inner.connectionTimeout = v;
  @override Duration get idleTimeout => _inner.idleTimeout;
  @override set idleTimeout(Duration v) => _inner.idleTimeout = v;
  @override int? get maxConnectionsPerHost => _inner.maxConnectionsPerHost;
  @override set maxConnectionsPerHost(int? v) =>
      _inner.maxConnectionsPerHost = v;
  @override String? get userAgent => _inner.userAgent;
  @override set userAgent(String? v) => _inner.userAgent = v;
  @override void addCredentials(
      Uri url, String realm, HttpClientCredentials c) =>
      _inner.addCredentials(url, realm, c);
  @override void addProxyCredentials(
      String host, int port, String realm, HttpClientCredentials c) =>
      _inner.addProxyCredentials(host, port, realm, c);
  @override set authenticate(
      Future<bool> Function(Uri url, String scheme, String? realm)? f) =>
      _inner.authenticate = f;
  @override set authenticateProxy(
      Future<bool> Function(
          String host, int port, String scheme, String? realm)?
      f) =>
      _inner.authenticateProxy = f;
  @override set badCertificateCallback(
      bool Function(X509Certificate cert, String host, int port)? cb) =>
      _inner.badCertificateCallback = cb;
  @override set findProxy(String Function(Uri url)? f) =>
      _inner.findProxy = f;
  @override set connectionFactory(
      Future<ConnectionTask<Socket>> Function(
          Uri url, String? proxyHost, int? proxyPort)?
      f) =>
      _inner.connectionFactory = f;
  @override set keyLog(Function(String line)? callback) =>
      _inner.keyLog = callback;
  @override void close({bool force = false}) => _inner.close(force: force);
}

// ─── Wrapped HttpClientRequest ───────────────────────────────────────────────

class _OrionHttpClientRequest implements HttpClientRequest {
  final HttpClientRequest _inner;
  final String httpMethod;
  final String trackedUrl;
  final int _startTime;

  _OrionHttpClientRequest(
      this._inner, {
        required this.httpMethod,
        required this.trackedUrl,
      }) : _startTime = DateTime.now().millisecondsSinceEpoch;

  @override
  Future<HttpClientResponse> close() async {
    try {
      final response = await _inner.close();
      _track(response.statusCode, contentLength: response.contentLength);
      return response;
    } catch (e) {
      _trackError(e.toString());
      rethrow;
    }
  }

  void _track(int statusCode, {int contentLength = -1}) {
    final endTime = DateTime.now().millisecondsSinceEpoch;
    final screen  = OrionNetworkTracker.currentScreenName ?? 'UnknownScreen';
    OrionNetworkTracker.addRequest(screen, {
      'method':      httpMethod,
      'url':         trackedUrl,
      'statusCode':  statusCode,
      'startTime':   _startTime,
      'endTime':     endTime,
      'duration':    endTime - _startTime,
      'payloadSize': contentLength > 0 ? contentLength : null,
      'contentType': _inferContentType(trackedUrl),
    });
  }

  void _trackError(String error) {
    final endTime = DateTime.now().millisecondsSinceEpoch;
    final screen  = OrionNetworkTracker.currentScreenName ?? 'UnknownScreen';
    OrionNetworkTracker.addRequest(screen, {
      'method':       httpMethod,
      'url':          trackedUrl,
      'statusCode':   -1,
      'startTime':    _startTime,
      'endTime':      endTime,
      'duration':     endTime - _startTime,
      'errorMessage': error,
      'contentType':  _inferContentType(trackedUrl),
    });
  }

  // Delegate all HttpClientRequest members
  @override String get method => _inner.method;
  @override Uri get uri => _inner.uri;
  @override HttpHeaders get headers => _inner.headers;
  @override List<Cookie> get cookies => _inner.cookies;
  @override HttpConnectionInfo? get connectionInfo => _inner.connectionInfo;
  @override Future<HttpClientResponse> get done => _inner.done;
  @override bool get bufferOutput => _inner.bufferOutput;
  @override set bufferOutput(bool v) => _inner.bufferOutput = v;
  @override int get contentLength => _inner.contentLength;
  @override set contentLength(int v) => _inner.contentLength = v;
  @override Encoding get encoding => _inner.encoding;
  @override set encoding(Encoding v) => _inner.encoding = v;
  @override bool get followRedirects => _inner.followRedirects;
  @override set followRedirects(bool v) => _inner.followRedirects = v;
  @override int get maxRedirects => _inner.maxRedirects;
  @override set maxRedirects(int v) => _inner.maxRedirects = v;
  @override bool get persistentConnection => _inner.persistentConnection;
  @override set persistentConnection(bool v) =>
      _inner.persistentConnection = v;
  @override void abort([Object? exception, StackTrace? stackTrace]) =>
      _inner.abort(exception, stackTrace);
  @override void add(List<int> data) => _inner.add(data);
  @override void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);
  @override Future addStream(Stream<List<int>> stream) =>
      _inner.addStream(stream);
  @override Future flush() => _inner.flush();
  @override Future write(Object? object) async => _inner.write(object);
  @override Future writeln([Object? object = '']) async =>
      _inner.writeln(object);
  @override Future writeAll(Iterable objects,
      [String separator = '']) async =>
      _inner.writeAll(objects, separator);
  @override Future writeCharCode(int charCode) async =>
      _inner.writeCharCode(charCode);
}