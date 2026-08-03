import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'sleek_http_client.dart';

/// Convenience helpers for working with JSON response bodies directly on a
/// [http.Response], independent of [SleekHttpClient.send].
///
/// Useful when a [http.Response] was obtained by some other means (e.g. a
/// plain `package:http` call, or a response handed to you by another API)
/// but you still want the same JSON conveniences [SleekHttpClient] uses
/// internally.
extension JsonHttpResponse on http.Response {
  /// Whether this response's `Content-Type` header indicates a JSON body.
  bool get isJson => ContentType.parse(
        headers[HttpHeaders.contentTypeHeader] ?? '',
      ).mimeType == SleekHttpClient.contentTypeJsonMimeType;

  /// Decodes the body as JSON, returning `null` if decoding fails (malformed
  /// JSON, unexpected shape, etc.) instead of throwing.
  T? tryDecodeJson<T>() {
    try {
      return json.decode(body) as T;
    } catch (_) {
      return null;
    }
  }
}

