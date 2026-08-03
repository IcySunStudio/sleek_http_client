import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../sleek_http_client.dart' show SleekHttpClient;
import '../types.dart';
import 'interceptor.dart';

/// Logs every request and response passing through the chain.
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

  @override
  Future<http.Response> intercept(http.BaseRequest request, HttpInterceptorChain chain) async {
    _logRequest(request);
    final response = await chain.proceed(request);
    _logResponse(response);
    return response;
  }

  void _logRequest(http.BaseRequest request) {
    String body = '';
    if (includeBody) {
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
    }

    logger(
      _buildMessage(
        symbol: '⬆️️',
        method: request.method,
        url: request.url.toString(),
        body: body,
        headers: logHeaders ? request.headers.toString() : null,
      ),
    );
  }

  void _logResponse(http.Response response) {
    final statusCode = response.statusCode != 200 ? '(${response.statusCode}) ' : '';

    String body = '';
    if (includeBody) {
      final isBodyJson = ContentType.parse(
        response.headers[HttpHeaders.contentTypeHeader] ?? '',
      ).mimeType == SleekHttpClient.contentTypeJsonMimeType;

      if (isBodyJson) {
        body = response.body.removeAllNewLines();
      } else {
        final sizeKb = ((response.contentLength ?? 0) / 1024).round();
        body = sizeKb <= 10 ? response.body.removeAllNewLines() : '$sizeKb kb';
      }
    }

    logger(
      _buildMessage(
        symbol: '⬇️',
        method: response.request?.method,
        url: response.request?.url.toString(),
        body: '$statusCode$body',
        headers: logHeaders ? response.headers.toString() : null,
      ),
    );
  }

  /// Builds a single log message, shared by both request and response logging.
  String _buildMessage({
    required String symbol,
    required String? method,
    required String? url,
    required String body,
    String? headers,
  }) {
    String message = '[SleekHttp] $symbol [$method $url] $body';
    if (headers != null) {
      message += '\n[SleekHttp] ${symbol}ℹ️ $headers'; // ignore: unnecessary_brace_in_string_interps
    }
    return message;
  }
}

