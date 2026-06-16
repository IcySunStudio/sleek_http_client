import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'connectivity_check.dart'
    if (dart.library.ui) 'connectivity_check_flutter.dart';
import 'exceptions.dart';
import 'retry_handlers.dart';
import 'types.dart';

export 'exceptions.dart';
export 'retry_handlers.dart';
export 'types.dart';

/// A clean, feature-rich HTTP client for Dart.
///
/// Features:
/// - Automatic connectivity checking
/// - JWT / OAuth token refresh with de-duplication
/// - Multipart file upload with retry support
/// - Structured request / response logging
/// - Strongly typed response parsing
/// - Configurable timeout
class SleekHttpClient {
  SleekHttpClient({
    http.Client? client,
    required this.authorityGetter,
    this.basePath = '',
    this.headersGetter,
    this.authorizationHeaderGetter,
    this.shouldRetry,
    this.onBeforeRetry,
    this.timeOutDuration = const Duration(seconds: 30),
    this.errorBuilder,
    this.logConfig,
    Future<bool> Function()? isOnlineChecker,
  })  : _isOnlineChecker = isOnlineChecker,
        _client = client ?? http.Client(),
        assert(
          onBeforeRetry == null || shouldRetry != null,
          'onBeforeRetry is set but shouldRetry is null — '
          'onBeforeRetry will never be called. '
          'Provide a shouldRetry callback, or use TokenRefreshHandler.',
        );

  /// JSON MIME type constant.
  static const contentTypeJsonMimeType = 'application/json';

  /// Full JSON content-type header value.
  static const contentTypeJson = '$contentTypeJsonMimeType; charset=utf-8';

  /// Internal http client
  final http.Client _client;

  /// Optional override for the connectivity check (useful for tests and
  /// environments where connectivity_plus is unavailable, e.g. pure Dart CLI).
  final Future<bool> Function()? _isOnlineChecker;

  /// Returns the authority (host) used for every request, e.g. `api.example.com`.
  final String Function() authorityGetter;

  /// Optional path prefix added before every request path, e.g. `/v1`.
  final String basePath;

  /// Optional extra headers added to every request.
  final Map<String, String> Function()? headersGetter;

  /// Returns the current authorization header value (e.g. `Bearer <token>`).
  /// When `null`, no `Authorization` header is added.
  final String? Function()? authorizationHeaderGetter;

  /// Called after a failed request to decide whether to retry it.
  ///
  /// Return `true` to trigger [onBeforeRetry] (if any) and resend the request.
  /// Return `false` (or leave `null`) to surface the error as-is.
  ///
  /// See [TokenRefreshHandler.shouldRetry] for a ready-made 401-based implementation.
  final Future<bool> Function(HttpResponseException exception)? shouldRetry;

  /// Called before the request is retried, after [shouldRetry] returned `true`.
  ///
  /// Use this to refresh tokens, insert delays, or perform any side-effect
  /// needed before the retry. Must throw if the pre-retry action fails, in
  /// which case the original exception is re-thrown to the caller.
  ///
  /// See [TokenRefreshHandler.onBeforeRetry] for a de-duplicated token-refresh implementation.
  final Future<void> Function(HttpResponseException exception)? onBeforeRetry;

  /// How long to wait for a response before throwing a
  /// [ConnectivityException] with [ConnectivityExceptionType.timeout].
  final Duration timeOutDuration;

  /// Optional factory for custom error exceptions.
  ///
  /// When provided, every non-2xx response will be turned into the returned
  /// exception instead of the default [HttpResponseException].
  final HttpClientErrorBuilder? errorBuilder;

  /// Logging configuration. `null` disables logging.
  final HttpClientLogConfig? logConfig;

  // ---------------------------------------------------------------------------
  // Public helpers
  // ---------------------------------------------------------------------------

  /// Builds a `https` [Uri] from [path] and optional [queryParameters].
  ///
  /// [authority] overrides [authorityGetter] for this single call.
  Uri buildUriFromPath(
    String path, [
    JsonObject? queryParameters,
    String? authority,
  ]) => Uri.https(
    authority ?? authorityGetter(),
    '$basePath$path',
    queryParameters,
  );

  /// Returns headers that are suitable for an authorized request (base headers
  /// + authorization header).
  ///
  /// Useful when you need to authorize external requests (e.g. file downloads)
  /// that still require the current token.
  Map<String, String> buildAuthorizedHeaders() => {
    ..._buildBaseHeaders(),
    ..._buildAuthHeader(),
  };

  // ---------------------------------------------------------------------------
  // Sending requests
  // ---------------------------------------------------------------------------

  /// Builds and sends a standard HTTP request.
  ///
  /// [authority] overrides [authorityGetter] for this single call.
  /// [headers] are merged with the global [headersGetter] headers.
  Future<T?> send<T>(
    HttpMethod method,
    String path, {
    String? authority,
    Map<String, String>? headers,
    JsonObject? bodyJson,
    String? stringBody,
    JsonObject? queryParameters,
  }) {
    final request = http.Request(
      method.toString(),
      buildUriFromPath(path, queryParameters, authority),
    );

    request.headers.addAll(
      _buildBaseHeaders(extraHeaders: headers, jsonContent: bodyJson != null),
    );

    if (bodyJson != null) {
      request.body = json.encode(bodyJson);
    } else if (stringBody != null) {
      request.body = stringBody;
    }

    return _sendHandledRequest<T>(request);
  }

  /// Builds and sends a multipart request (file upload).
  ///
  /// Currently only supports files referenced by a local file-system path.
  Future<T?> sendMultipartRequest<T>(
    String path, {
    Map<String, String>? headers,
    Map<String, String>? fields,
    required List<MultipartRequestFileData> files,
  }) async {
    final request = _RetryableMultipartRequest(
      HttpMethod.post.toString(),
      buildUriFromPath(path),
      filesData: files,
    );

    request.headers.addAll(_buildBaseHeaders(extraHeaders: headers));

    if (fields != null) {
      request.fields.addAll(fields);
    }

    await request.buildFiles();

    return _sendHandledRequest<T>(request);
  }

  // ---------------------------------------------------------------------------
  // Static helpers
  // ---------------------------------------------------------------------------

  /// Returns `true` for any 2xx HTTP status code.
  static bool isStatusCodeSuccess(int httpStatusCode) => httpStatusCode >= 200 && httpStatusCode < 300;

  /// Throws a [ConnectivityException] with
  /// [ConnectivityExceptionType.noInternet] when the device is offline.
  Future<void> throwIfOffline() async {
    if (!await isOnline()) {
      logConfig?.logger('[SleekHttp] ❌ NO INTERNET');
      throw const ConnectivityException(ConnectivityExceptionType.noInternet);
    }
  }

  /// Returns `true` when the device has at least one active network interface.
  ///
  /// Resolution order:
  /// 1. The [isOnlineChecker] override passed to the constructor, if any.
  /// 2. The platform connectivity check via `connectivity_plus` (Flutter), or
  ///    always `true` in non-Flutter environments (pure-Dart CLI / tests).
  Future<bool> isOnline() => _isOnlineChecker?.call() ?? defaultIsOnline();

  // ---------------------------------------------------------------------------
  // Private – header building
  // ---------------------------------------------------------------------------

  Map<String, String> _buildBaseHeaders({
    Map<String, String>? extraHeaders,
    bool jsonContent = false,
  }) => {
    HttpHeaders.acceptHeader: contentTypeJsonMimeType,
    if (jsonContent) HttpHeaders.contentTypeHeader: contentTypeJson,
    ...?headersGetter?.call(),
    ...?extraHeaders,
  };

  Map<String, String> _buildAuthHeader() {
    final value = authorizationHeaderGetter?.call();
    return {if (value != null) HttpHeaders.authorizationHeader: value};
  }

  // ---------------------------------------------------------------------------
  // Private – request dispatch
  // ---------------------------------------------------------------------------

  Future<T?> _sendHandledRequest<T>(
    http.BaseRequest request, {
    bool retryEnabled = true,
  }) async {
    // Attach auth header here so it uses the most recent token on every retry.
    request.headers.addAll(_buildAuthHeader());

    try {
      return await _sendRequest<T>(request);
    } catch (e) {
      if (e is TimeoutException) {
        throw const ConnectivityException(ConnectivityExceptionType.timeout);
      }

      // Check retry is possible
      if (e is HttpResponseException && retryEnabled && shouldRetry != null) {
        // Check if we should retry
        if (await shouldRetry!(e)) {
          // Call pre-retry task before retrying. May throw.
          await onBeforeRetry?.call(e);

          // Retry the request with a fresh copy
          return _sendHandledRequest<T>(
            await request.copyAsNew(),
            retryEnabled: false,
          );
        }
      }

      rethrow;
    }
  }

  Future<T?> _sendRequest<T>(http.BaseRequest request) async {
    _log(request: request);
    await throwIfOffline();

    final response = await (() async {
      final streamed = await _client.send(request);
      return http.Response.fromStream(streamed);
    }()).timeout(timeOutDuration);

    final handler = _ResponseHandler(response);
    _log(responseHandler: handler);
    return handler.parseAs<T>(errorBuilder: errorBuilder);
  }


  // ---------------------------------------------------------------------------
  // Private – logging
  // ---------------------------------------------------------------------------

  void _log({
    http.BaseRequest? request,
    _ResponseHandler? responseHandler,
  }) {
    final cfg = logConfig;
    if (cfg == null || (request == null && responseHandler == null)) return;

    request = request ?? responseHandler!.response.request;
    final method = request?.method;
    final url = request?.url.toString();

    String symbol;
    String statusCode = '';
    String body = '';
    String? headers;

    if (responseHandler != null) {
      final r = responseHandler.response;
      symbol = '⬇️';
      statusCode = r.statusCode != 200 ? '(${r.statusCode}) ' : '';
      if (cfg.includeBody) {
        if (responseHandler.isBodyJson) {
          body = responseHandler.bodyString.removeAllNewLines();
        } else {
          final sizeKb = ((r.contentLength ?? 0) / 1024).round();
          body = sizeKb <= 10 ? responseHandler.bodyString.removeAllNewLines() : '$sizeKb kb';
        }
      }
      if (cfg.logHeaders) headers = r.headers.toString();
    } else {
      symbol = '⬆️️';
      body = switch (request) {
        http.Request() => request.body,
        http.MultipartRequest() => 'Multipart${json.encode({
          'fields': request.fields,
          'files': request.files.map((f) => {
            'field': f.field,
            'filename': f.filename,
            'length': f.length,
            'contentType': f.contentType.toString(),
          }).toList(),
        })}',
        _ => '',
      };
      if (cfg.logHeaders) headers = request?.headers.toString();
    }

    String message = '[SleekHttp] $symbol [$method $url] $statusCode$body';
    if (headers != null) {
      message += '\n[SleekHttp] ${symbol}ℹ️ $headers'; // ignore: unnecessary_brace_in_string_interps
    }
    cfg.logger(message);
  }
}

// =============================================================================
// Supporting types
// =============================================================================

/// HTTP verb.
enum HttpMethod {
  get,
  post,
  put,
  patch,
  delete;

  @override
  String toString() => name.toUpperCase();
}

/// Configuration for request/response logging.
class HttpClientLogConfig {
  const HttpClientLogConfig({
    required this.logger,
    this.logHeaders = false,
    this.includeBody = true,
  });

  /// Function that receives each log message.
  ///
  /// Typically set to `print` in debug builds; disable in release builds to
  /// avoid leaking sensitive data.
  final void Function(String message) logger;

  /// Whether to include raw request/response headers.
  final bool logHeaders;

  /// Whether to include the request/response body.
  final bool includeBody;
}

/// Metadata for a single file to include in a multipart upload.
class MultipartRequestFileData {
  MultipartRequestFileData({
    required this.fieldName,
    required this.path,
    String? contentType,
    this.filename,
  }) : contentType = contentType != null ? http.MediaType.parse(contentType) : null;

  /// The form-field name.
  final String fieldName;

  /// Absolute or relative path to the file on disk.
  final String path;

  /// Optional MIME type override.
  final http.MediaType? contentType;

  /// Optional filename to send in the `Content-Disposition` header.
  final String? filename;
}

/// Response body as raw bytes (returned when `T == BytesBody`).
class BytesBody {
  const BytesBody._(this.mimeType, this.bytes);

  final String mimeType;
  final Uint8List bytes;
}

// =============================================================================
// Internal helpers
// =============================================================================

class _ResponseHandler {
  _ResponseHandler(this.response)
      : isSuccess = SleekHttpClient.isStatusCodeSuccess(response.statusCode),
        isBodyJson = ContentType.parse(
          response.headers[HttpHeaders.contentTypeHeader] ?? '',
        ).mimeType == SleekHttpClient.contentTypeJsonMimeType;

  final http.Response response;

  final bool isSuccess;
  final bool isBodyJson;

  String? _bodyString;

  String get bodyString => _bodyString ??= response.body;

  T bodyJson<T>() => json.decode(bodyString) as T;

  T? bodyJsonOrNull<T>() {
    try {
      return bodyJson<T?>();
    } catch (_) {
      return null;
    }
  }

  T? parseAs<T>({HttpClientErrorBuilder? errorBuilder}) {
    if (isSuccess) {
      if (T == String) return bodyString as T;
      if (T == JsonObject || T == JsonList) return bodyJsonOrNull<T>();
      if (T == BytesBody) {
        return BytesBody._(
          response.headers[HttpHeaders.contentTypeHeader] ?? 'application/octet-stream',
          response.bodyBytes,
        ) as T;
      }
      if (isTypeUndefined<T>()) return null as T;
      throw UnimplementedError('$T is not a supported response type');
    } else {
      JsonObject? parsed;
      if (isBodyJson) parsed = bodyJsonOrNull<JsonObject>();
      throw errorBuilder?.call(response, parsed) ?? HttpResponseException(response, parsed);
    }
  }
}

/// A [http.MultipartRequest] that can be cloned for automatic retry.
///
/// The standard [http.MultipartRequest] cannot be re-sent because its file
/// streams are consumed after the first send. This subclass stores the original
/// file metadata and re-builds the streams from disk on every retry.
class _RetryableMultipartRequest extends http.MultipartRequest {
  _RetryableMultipartRequest(
    super.method,
    super.url, {
    required this.filesData,
  });

  final List<MultipartRequestFileData> filesData;

  Future<void> buildFiles() async {
    files.clear();
    for (final f in filesData) {
      files.add(
        await http.MultipartFile.fromPath(
          f.fieldName,
          f.path,
          contentType: f.contentType,
          filename: f.filename,
        ),
      );
    }
  }
}

extension _CopyableBaseRequest on http.BaseRequest {
  /// Creates a fresh copy of this request so it can be re-sent.
  Future<http.BaseRequest> copyAsNew() async {
    final source = this;
    http.BaseRequest copy;

    if (source is http.Request) {
      copy = http.Request(source.method, source.url)
        ..encoding = source.encoding
        ..bodyBytes = source.bodyBytes;
    } else if (source is _RetryableMultipartRequest) {
      final mc = _RetryableMultipartRequest(
        source.method,
        source.url,
        filesData: source.filesData,
      )..fields.addAll(source.fields);
      await mc.buildFiles();
      copy = mc;
    } else {
      throw UnimplementedError(
        'Copying ${source.runtimeType} is not implemented',
      );
    }

    copy
      ..persistentConnection = source.persistentConnection
      ..followRedirects = source.followRedirects
      ..maxRedirects = source.maxRedirects
      ..headers.addAll(source.headers);

    return copy;
  }
}
