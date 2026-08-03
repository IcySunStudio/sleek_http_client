import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'connectivity_check.dart'
    if (dart.library.ui) 'connectivity_check_flutter.dart';
import 'exceptions.dart';
import 'interceptors/interceptor.dart';
import 'interceptors/logging_interceptor.dart';
import 'types.dart';

export 'exceptions.dart';
export 'interceptors/interceptor.dart';
export 'interceptors/logging_interceptor.dart';
export 'interceptors/token_refresh_interceptor.dart';
export 'types.dart';

/// A clean, feature-rich HTTP client for Dart.
///
/// Features:
/// - Automatic connectivity checking
/// - Composable interceptor chain (retry, token refresh, logging, cache, ...)
/// - Multipart file upload with retry support
/// - Strongly typed response parsing
/// - Configurable timeout
class SleekHttpClient {
  SleekHttpClient({
    http.Client? client,
    required this.authorityGetter,
    this.basePath = '',
    this.headersGetter,
    this.authorizationHeaderGetter,
    this.interceptors = const [],
    this.timeOutDuration = const Duration(seconds: 30),
    this.errorBuilder,
    Future<bool> Function()? isOnlineChecker,
  })  : _isOnlineChecker = isOnlineChecker,
        _client = client ?? http.Client();

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

  /// The interceptor chain, applied to every request.
  ///
  /// Index 0 is the outermost interceptor (sees every retry / short-circuit
  /// decision made by interceptors after it); the last one is the innermost,
  /// closest to the actual network call.
  ///
  /// Ship-in-the-box interceptors:
  /// - [TokenRefreshInterceptor] for the standard JWT / OAuth token-refresh
  ///   pattern (401 retry with de-duplicated refresh).
  /// - [LoggingInterceptor] for structured request / response logging
  ///   (place it last so it only logs actual network calls).
  ///
  /// Implement [HttpInterceptor] directly for custom behavior (e.g. a disk-cache short-circuit).
  ///
  /// When [authorizationHeaderGetter] is set, [SleekHttpClient] automatically
  /// inserts an internal auth-header interceptor right before the first
  /// [LoggingInterceptor] found here (or at the innermost position if none),
  /// so a `logHeaders: true` log line reflects the actual `Authorization`
  /// header sent — see [_buildEffectiveInterceptors].
  final List<HttpInterceptor> interceptors;

  /// [interceptors], plus the internal auth-header interceptor inserted at
  /// the right spot. Computed once in the constructor and used for every
  /// request. See [_buildEffectiveInterceptors].
  late final List<HttpInterceptor> _effectiveInterceptors = _buildEffectiveInterceptors();

  /// How long to wait for a response before throwing a
  /// [ConnectivityException] with [ConnectivityExceptionType.timeout].
  final Duration timeOutDuration;

  /// Optional factory for custom error exceptions.
  ///
  /// When provided, every non-2xx response will be turned into the returned
  /// exception instead of the default [HttpResponseException].
  final HttpClientErrorBuilder? errorBuilder;

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
  ///
  /// For [JsonObject] / [JsonList], `T` itself controls null-tolerance: use
  /// `send<JsonObject>(...)` to require a non-null body (throws
  /// [NullResponseBodyException] if the server returns JSON `null`), or
  /// `send<JsonObject?>(...)` if a `null` body is a legitimate outcome.
  Future<T> send<T>(
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
  Future<T> sendMultipartRequest<T>(
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

  Future<T> _sendHandledRequest<T>(http.BaseRequest request) async {
    final response = await runInterceptorChain(request, _effectiveInterceptors, _sendRequest);
    return _ResponseHandler(response).parseAs<T>(errorBuilder: errorBuilder);
  }

  /// Builds the interceptor list actually used to send requests: [interceptors]
  /// plus an internal [_AuthHeaderInterceptor], if [authorizationHeaderGetter]
  /// is set.
  ///
  /// The auth header is attached via an *interceptor* — instead of a single
  /// inline `request.headers.addAll(...)` line in [_sendRequest] — for two
  /// reasons:
  /// 1. **Freshness on retry**: as a chain link, it re-runs every time
  ///    `chain.proceed` reaches it, including on a retry triggered by e.g.
  ///    [TokenRefreshInterceptor] — so the retried request always carries the
  ///    latest value, not one baked in before the refresh happened.
  /// 2. **Orderability**: being an ordinary link makes its position in the
  ///    chain explicit and controllable. Placing it right before the first
  ///    [LoggingInterceptor] (rather than in the fixed, always-innermost
  ///    terminal step) lets that logger observe the real headers that were
  ///    sent — a plain inline attachment in the terminal step would always be
  ///    invisible to every interceptor, no matter where they're placed.
  List<HttpInterceptor> _buildEffectiveInterceptors() {
    if (authorizationHeaderGetter == null) return interceptors;

    final result = List<HttpInterceptor>.of(interceptors);
    final loggingIndex = result.indexWhere((i) => i is LoggingInterceptor);
    final authInterceptor = _AuthHeaderInterceptor(_buildAuthHeader);

    if (loggingIndex == -1) {
      result.add(authInterceptor);
    } else {
      result.insert(loggingIndex, authInterceptor);
    }
    return result;
  }

  /// The terminal link of the interceptor chain: checks connectivity and
  /// performs the actual network call with timeout.
  Future<http.Response> _sendRequest(http.BaseRequest request) async {
    await throwIfOffline();

    try {
      final streamed = await _client.send(request);
      return await http.Response.fromStream(streamed).timeout(timeOutDuration);
    } on TimeoutException {
      throw const ConnectivityException(ConnectivityExceptionType.timeout);
    }
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

/// Returns the reified [Type] for [X], including its nullability — e.g.
/// `_typeOf<int?>()` returns the `Type` object for `int?`, distinct from
/// `_typeOf<int>()`. Used to compare a generic `T` against the nullable
/// variant of a known type: unlike a generic type *argument* (e.g.
/// `bodyJson<T?>()`), a nullable type has no literal expression syntax on
/// its own (`int?` alone is parsed as the start of a conditional `?:`).
Type _typeOf<X>() => X;

/// Attaches headers built from [_headerGetter] to every request, evaluated
/// fresh every time `chain.proceed` reaches this link (see
/// [SleekHttpClient._buildEffectiveInterceptors] for why this is an
/// interceptor rather than an inline header attachment).
///
/// Private and not exported: it only exists to be auto-inserted by
/// [SleekHttpClient] itself, not to be used directly.
class _AuthHeaderInterceptor implements HttpInterceptor {
  _AuthHeaderInterceptor(this._headerGetter);

  final Map<String, String> Function() _headerGetter;

  @override
  Future<http.Response> intercept(http.BaseRequest request, HttpInterceptorChain chain) {
    request.headers.addAll(_headerGetter());
    return chain.proceed(request);
  }
}

class _ResponseHandler {
  _ResponseHandler(this.response)
      : isSuccess = SleekHttpClient.isStatusCodeSuccess(response.statusCode),
        isBodyJson = ContentType.parse(
          response.headers[HttpHeaders.contentTypeHeader] ?? '',
        ).mimeType == SleekHttpClient.contentTypeJsonMimeType;

  final http.Response response;

  final bool isSuccess;
  final bool isBodyJson;

  late final String bodyString = response.body;

  T bodyJson<T>() => json.decode(bodyString) as T;

  /// Best-effort JSON decoding: swallows any decoding failure to `null`.
  ///
  /// Only used for the error-body case (see [parseAs]): the response is
  /// already known to be an HTTP error, and it may not carry a JSON body at
  /// all (plain text, HTML error page, empty body, ...) — a secondary parsing
  /// failure here must not mask the real [HttpResponseException].
  T? bodyJsonOrNull<T>() {
    try {
      return bodyJson<T?>();
    } catch (_) {
      return null;
    }
  }

  T parseAs<T>({HttpClientErrorBuilder? errorBuilder}) {
    if (isSuccess) {
      if (T == String) return bodyString as T;
      if (T == JsonObject || T == JsonList || T == _typeOf<JsonObject?>() || T == _typeOf<JsonList?>()) {
        // Malformed JSON (`FormatException`) or an unexpected shape, e.g. a list where an object was expected (`TypeError`), is a server
        // contract violation and is deliberately left to propagate here, rather than being silently swallowed to `null`.
        final decoded = bodyJson<T?>();
        if (decoded == null && null is! T) {
          // T is a non-nullable request (e.g. `send<JsonObject>()`), but the server returned a literal JSON `null`
          // — surface this distinctly instead of a confusing cast failure.
          throw NullResponseBodyException(T);
        }
        return decoded as T;
      }
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

/// Extension allowing a [http.BaseRequest] to be cloned for retry, used by
/// interceptors such as [TokenRefreshInterceptor].
extension CopyableBaseRequest on http.BaseRequest {
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
