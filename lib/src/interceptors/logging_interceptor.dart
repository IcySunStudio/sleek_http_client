import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../sleek_http_client.dart' show SleekHttpClient;
import '../types.dart';
import 'interceptor.dart';

/// How [LoggingInterceptor] lays out the request and response bodies.
enum LogLayout {
  /// Each body is logged on its own indented line, under the line describing the call:
  ///
  /// ```text
  /// 🌐 [api.example.com] 🟠 401 POST /reviews · 88 ms
  ///   ⬆️ {"note":4}
  ///   ⬇️ {"error":"token_expired"}
  /// ```
  ///
  /// Easiest to read, but a call spans several lines (a console filter on the
  /// first line hides the bodies).
  multiline,

  /// Everything on a single line. When the request has a body, both bodies are
  /// told apart with `⬆️` / `⬇️`:
  ///
  /// ```text
  /// 🌐 [api.example.com] 🟠 401 POST /reviews · 88 ms · ⬆️ {"note":4} ⬇️ {"error":"token_expired"}
  /// ```
  ///
  /// Keeps one line per call (easy to filter and grep), but long bodies are
  /// harder to read.
  compact,
}

/// Logs every request passing through the chain, as well as any exception
/// thrown further down the chain instead of a response (e.g. no internet,
/// timeout, DNS / connection failure). The exception is rethrown unchanged.
///
/// By default, one message is logged per call, once the response (or the
/// exception) is received, with the request / response bodies on their own
/// lines (see [LogLayout]):
///
/// ```text
/// 🌐 [api.example.com] 🟢 200 GET /films · 142 ms
///   ⬇️ {"films":[…]}
/// 🌐 [api.example.com] 🟠 401 POST /reviews · 88 ms
///   ⬆️ {"note":4}
///   ⬇️ {"error":"token_expired"}
/// 🌐 [api.example.com] ❌ GET /films · 30001 ms · ConnectivityException(timeout)
/// ```
///
/// - `🌐` is the [leading] marker, `[api.example.com]` the label (see [labelBuilder]).
/// - The status icon reflects the status code: 🟢 2xx, 🟡 3xx, 🟠 4xx, 🔴 5xx.
///   Non-2xx responses are still logged as regular responses (they only become
///   errors when parsed, after the chain), hence the dedicated icons.
/// - The URL does not include the host: see [labelBuilder].
/// - Use [LogLayout.compact] to log everything on a single line instead.
///
/// Set [logRequests] to also log each request as soon as it is sent. This is
/// useful to spot calls that never complete (e.g. no timeout set):
///
/// ```text
/// 🌐 [api.example.com] ⬆️ GET /films
/// 🌐 [api.example.com] 🟢 200 GET /films · 142 ms
///   ⬇️ {"films":[…]}
/// ```
///
/// Place it last in [SleekHttpClient.interceptors] (the innermost position,
/// closest to the actual network call) so that it only logs real network
/// calls — not short-circuits from interceptors placed before it (e.g. a
/// cache hit).
///
/// ```dart
/// SleekHttpClient(
///   interceptors: [
///     TokenRefreshInterceptor(...),
///     LoggingInterceptor(logger: print),
///   ],
/// );
/// ```
class LoggingInterceptor implements HttpInterceptor {
  LoggingInterceptor({
    required this.logger,
    this.logHeaders = false,
    this.includeBody = true,
    this.logRequests = false,
    this.layout = LogLayout.multiline,
    this.leading = '🌐',
    this.labelBuilder,
    this.maxBodyLength = 500,
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

  /// Whether to also log each request when it is sent, on top of the message
  /// logged once the response (or exception) is received.
  final bool logRequests;

  /// How the bodies are laid out: each on its own line ([LogLayout.multiline],
  /// the default) or everything on a single line ([LogLayout.compact]).
  final LogLayout layout;

  /// Marker put at the very start of every log line, to spot them among
  /// other logs. `null` removes it (and the space following it).
  final String? leading;

  /// Builds the label displayed between brackets on every log line, for the
  /// given request. Defaults to the request host (and port, if any) when
  /// `null`; a `null` or empty result removes the brackets.
  ///
  /// As the URL is logged without its host, use it to tell where a request
  /// goes, e.g. an environment name or a short name per API:
  ///
  /// ```dart
  /// LoggingInterceptor(
  ///   logger: print,
  ///   labelBuilder: (request) => '${environment.name} · ${request.url.host}',
  /// );
  /// ```
  final String? Function(http.BaseRequest request)? labelBuilder;

  /// Maximum length of each logged body (request and response): longer ones
  /// are cut and end with `…`. `null` disables truncation.
  final int? maxBodyLength;

  @override
  Future<http.Response> intercept(http.BaseRequest request, HttpInterceptorChain chain) async {
    final requestBody = _requestBody(request);
    if (logRequests) _logRequest(request, requestBody);

    final stopwatch = Stopwatch()..start();
    final http.Response response;
    try {
      response = await chain.proceed(request);
    } catch (e) {
      // e.g. no internet, timeout, DNS / connection failure: without this, the failed call would not be logged at all.
      _logError(request, e, stopwatch.elapsed);
      rethrow;
    }
    _logResponse(request, response, requestBody, stopwatch.elapsed);
    return response;
  }

  void _logRequest(http.BaseRequest request, String body) {
    final isMultiline = layout == LogLayout.multiline;

    logger(
      _buildMessage(
        request,
        icon: '⬆️',
        details: [if (!isMultiline) body],
        extraLines: [
          if (isMultiline && body.isNotEmpty) '⬆️ $body',
          if (logHeaders) '⬆️ headers: ${request.headers}',
        ],
      ),
    );
  }

  void _logResponse(http.BaseRequest request, http.Response response, String requestBody, Duration elapsed) {
    final responseBody = _responseBody(response);

    // The request body is shown here only if it was not already logged by [_logRequest].
    final shownRequestBody = logRequests ? '' : requestBody;

    final String inlineBody;
    final List<String> bodyLines;
    switch (layout) {
      case LogLayout.multiline:
        inlineBody = '';
        bodyLines = [
          if (shownRequestBody.isNotEmpty) '⬆️ $shownRequestBody',
          if (responseBody.isNotEmpty) '⬇️ $responseBody',
        ];
      case LogLayout.compact:
        // Markers are only needed to tell the two bodies apart.
        bodyLines = const [];
        inlineBody = shownRequestBody.isEmpty
            ? responseBody
            : ['⬆️ $shownRequestBody', if (responseBody.isNotEmpty) '⬇️ $responseBody'].join(' ');
    }

    logger(
      _buildMessage(
        request,
        icon: _statusIcon(response.statusCode),
        status: response.statusCode,
        details: ['${elapsed.inMilliseconds} ms', inlineBody],
        extraLines: [
          ...bodyLines,
          if (logHeaders && !logRequests) '⬆️ headers: ${request.headers}',
          if (logHeaders) '⬇️ headers: ${response.headers}',
        ],
      ),
    );
  }

  void _logError(http.BaseRequest request, Object error, Duration elapsed) {
    logger(
      _buildMessage(
        request,
        icon: '❌',
        details: ['${elapsed.inMilliseconds} ms', '$error'],
      ),
    );
  }

  /// Builds a single log message, shared by request, response and error logging:
  /// `leading [label] icon status METHOD /path · detail · detail`, followed by
  /// [extraLines] (e.g. headers), if any. Empty [details] are skipped.
  String _buildMessage(
    http.BaseRequest request, {
    required String icon,
    int? status,
    required List<String> details,
    List<String> extraLines = const [],
  }) {
    final label = labelBuilder != null ? labelBuilder!(request) : _hostOf(request.url);

    final buffer = StringBuffer();
    if (leading != null) buffer.write('$leading ');
    if (label != null && label.isNotEmpty) buffer.write('[$label] ');
    buffer.write('$icon ');
    if (status != null) buffer.write('$status ');
    buffer.write('${request.method} ${_pathOf(request.url)}');
    for (final detail in details.where((d) => d.isNotEmpty)) {
      buffer.write(' · $detail');
    }
    for (final line in extraLines) {
      buffer.write('\n  $line');
    }
    return buffer.toString();
  }

  /// Host and explicit port, if any (e.g. `localhost:8080`).
  static String _hostOf(Uri url) => url.hasPort ? '${url.host}:${url.port}' : url.host;

  /// Path and query, without the host.
  static String _pathOf(Uri url) {
    final path = url.path.isEmpty ? '/' : url.path;
    return url.hasQuery ? '$path?${url.query}' : path;
  }

  /// 🟢 2xx, 🟡 3xx, 🟠 4xx, 🔴 5xx.
  static String _statusIcon(int statusCode) => switch (statusCode) {
    >= 500 => '🔴',
    >= 400 => '🟠',
    >= 300 => '🟡',
    >= 200 => '🟢',
    _ => '⚪',
  };

  String _requestBody(http.BaseRequest request) {
    if (!includeBody) return '';

    final body = switch (request) {
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
    return _truncate(body.removeAllNewLines());
  }

  String _responseBody(http.Response response) {
    if (!includeBody) return '';

    final isBodyJson = ContentType.parse(
      response.headers[HttpHeaders.contentTypeHeader] ?? '',
    ).mimeType == SleekHttpClient.contentTypeJsonMimeType;

    if (isBodyJson) return _truncate(response.body.removeAllNewLines());

    final sizeKb = ((response.contentLength ?? 0) / 1024).round();
    return sizeKb <= 10 ? _truncate(response.body.removeAllNewLines()) : '$sizeKb kb';
  }

  String _truncate(String body) {
    final max = maxBodyLength;
    return max == null || body.length <= max ? body : '${body.substring(0, max)}…';
  }
}
