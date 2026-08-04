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
  static final Expando<Object?> _decoded = Expando();

  /// Whether this response's `Content-Type` header indicates a JSON body.
  bool get isJson => ContentType.parse(
        headers[HttpHeaders.contentTypeHeader] ?? '',
      ).mimeType == SleekHttpClient.contentTypeJsonMimeType;

  /// Decodes the body as JSON, throwing on malformed JSON / an unexpected
  /// shape (e.g. a list where an object was expected) instead of swallowing
  /// the error. Use this when a decode failure is a genuine, actionable bug
  /// (e.g. a server contract violation on a success response) that must not
  /// be silently turned into `null`. See [tryDecodeJson] for a best-effort
  /// variant.
  ///
  /// The decoded result is cached per response instance, so [decodeJson] and
  /// [tryDecodeJson] share the same cache: subsequent calls (from any
  /// interceptor, or SleekHttpClient's own parsing) reuse the cached result
  /// instead of re-running json.decode.
  T decodeJson<T>() {
    final cached = _decoded[this];
    if (cached != null) return cached as T;

    final result = json.decode(body);
    _decoded[this] = result;
    return result as T;
  }

  /// Decodes the body as JSON, returning `null` if decoding fails (malformed
  /// JSON, unexpected shape, etc.) instead of throwing. See [decodeJson] for
  /// the shared caching behavior.
  ///
  /// Failed decodes are not cached (they resolve to `null`, which is cheap
  /// to recompute), so a failing call may re-attempt decoding on each
  /// invocation.
  T? tryDecodeJson<T>() {
    try {
      return decodeJson<T?>();
    } catch (_) {
      return null;
    }
  }
}

