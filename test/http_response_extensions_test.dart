import 'package:http/http.dart' as http;
import 'package:sleek_http_client/sleek_http_client.dart';
import 'package:test/test.dart';

void main() {
  group('JsonHttpResponse', () {
    test('isJson is true for an application/json content-type', () {
      final response = http.Response(
        '{}',
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

      expect(response.isJson, isTrue);
    });

    test('isJson is false for a non-JSON content-type', () {
      final response = http.Response(
        '<html></html>',
        200,
        headers: {'content-type': 'text/html; charset=utf-8'},
      );

      expect(response.isJson, isFalse);
    });

    test('isJson is false when there is no content-type header', () {
      final response = http.Response('', 200);

      expect(response.isJson, isFalse);
    });

    test('tryDecodeJson decodes a valid JSON object body', () {
      final response = http.Response('{"id": 1, "name": "Ada"}', 200);

      expect(response.tryDecodeJson<JsonObject>(), {'id': 1, 'name': 'Ada'});
    });

    test('tryDecodeJson decodes a valid JSON list body', () {
      final response = http.Response('[1, 2, 3]', 200);

      expect(response.tryDecodeJson<JsonList>(), [1, 2, 3]);
    });

    test('tryDecodeJson returns null on malformed JSON', () {
      final response = http.Response('not json', 200);

      expect(response.tryDecodeJson<JsonObject>(), isNull);
    });

    test('tryDecodeJson returns null on an unexpected JSON shape', () {
      final response = http.Response('[1, 2, 3]', 200);

      expect(response.tryDecodeJson<JsonObject>(), isNull);
    });

    test('decodeJson decodes a valid JSON object body', () {
      final response = http.Response('{"id": 1, "name": "Ada"}', 200);

      expect(response.decodeJson<JsonObject>(), {'id': 1, 'name': 'Ada'});
    });

    test('decodeJson decodes a valid JSON list body', () {
      final response = http.Response('[1, 2, 3]', 200);

      expect(response.decodeJson<JsonList>(), [1, 2, 3]);
    });

    test('decodeJson throws FormatException on malformed JSON', () {
      final response = http.Response('not json', 200);

      expect(() => response.decodeJson<JsonObject>(), throwsFormatException);
    });

    test('decodeJson throws TypeError on an unexpected JSON shape', () {
      final response = http.Response('[1, 2, 3]', 200);

      expect(() => response.decodeJson<JsonObject>(), throwsA(isA<TypeError>()));
    });

    test('decodeJson caches the decoded result per response instance', () {
      final response = http.Response('{"id": 1}', 200);

      // Same instance returned on every call: proves json.decode only ran
      // once and the second call reused the cached result instead of
      // producing a fresh Map.
      expect(
        identical(response.decodeJson<JsonObject>(), response.decodeJson<JsonObject>()),
        isTrue,
      );
    });

    test('decodeJson and tryDecodeJson share the same cache', () {
      final response = http.Response('{"id": 1}', 200);

      final fromDecodeJson = response.decodeJson<JsonObject>();
      final fromTryDecodeJson = response.tryDecodeJson<JsonObject>();

      expect(identical(fromDecodeJson, fromTryDecodeJson), isTrue);
    });

    test('tryDecodeJson does not cache a failed decode (each call may re-attempt)', () {
      final response = http.Response('not json', 200);

      // Both calls independently swallow the FormatException and return
      // null - nothing to assert about caching here beyond "it still works"
      // since a failed decode is deliberately not cached.
      expect(response.tryDecodeJson<JsonObject>(), isNull);
      expect(response.tryDecodeJson<JsonObject>(), isNull);
    });
  });
}

