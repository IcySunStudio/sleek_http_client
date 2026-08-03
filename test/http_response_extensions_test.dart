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
  });
}

