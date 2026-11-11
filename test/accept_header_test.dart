import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sleek_http_client/sleek_http_client.dart';
import 'package:test/test.dart';

const _json = 'application/json';

void main() {
  group('default Accept header', () {
    test('is application/json for the JSON types and the undefined types', () async {
      final accepts = <String?>[];
      final client = _client(accepts, response: http.Response('{}', 200, headers: {'content-type': _json}));

      await client.send<JsonObject>(HttpMethod.get, '/x');
      await client.send<JsonObject?>(HttpMethod.get, '/x');
      await client.sendUri<JsonObject>(HttpMethod.get, Uri.parse('https://example.org/x'));
      await client.send<void>(HttpMethod.get, '/x');
      await client.send<Null>(HttpMethod.get, '/x');
      await client.send<Object?>(HttpMethod.get, '/x');
      await client.send<dynamic>(HttpMethod.get, '/x');
      await client.send(HttpMethod.get, '/x');

      expect(accepts, everyElement(_json));
      expect(accepts, hasLength(8));
    });

    test('is application/json for JsonList and JsonList?', () async {
      final accepts = <String?>[];
      final client = _client(accepts, response: http.Response('[]', 200, headers: {'content-type': _json}));

      await client.send<JsonList>(HttpMethod.get, '/x');
      await client.send<JsonList?>(HttpMethod.get, '/x');

      expect(accepts, [_json, _json]);
    });

    test('is absent for String and BytesBody', () async {
      final accepts = <String?>[];
      final client = _client(accepts);

      await client.send<String>(HttpMethod.get, '/x');
      await client.sendUri<String>(HttpMethod.get, Uri.parse('https://example.org/x'));
      await client.send<BytesBody>(HttpMethod.get, '/x');
      await client.sendUri<BytesBody>(HttpMethod.get, Uri.parse('https://example.org/x'));

      expect(accepts, [null, null, null, null]);
    });

    test('is also deduced by sendMultipartRequest', () async {
      final dir = await Directory.systemTemp.createTemp('sleek_accept_test');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}${Platform.pathSeparator}f.txt')..writeAsStringSync('hello');
      final files = [MultipartRequestFileData(fieldName: 'file', path: file.path)];
      final accepts = <String?>[];
      final client = _client(accepts);

      await client.sendMultipartRequest<String>('/upload', files: files);
      await client.sendMultipartRequest<void>('/upload', files: files);

      expect(accepts, [null, _json]);
    });

    test('can be replaced by headersGetter and by the per-call headers, whatever the case', () async {
      final accepts = <String?>[];
      final withGetter = _client(
        accepts,
        response: http.Response('{}', 200, headers: {'content-type': _json}),
        headersGetter: () => {'Accept': 'text/html'},
      );

      await withGetter.send<String>(HttpMethod.get, '/x');
      await withGetter.send<JsonObject?>(HttpMethod.get, '/x');
      await withGetter.send<JsonObject?>(HttpMethod.get, '/x', headers: {'accept': 'text/csv'});

      expect(accepts, ['text/html', 'text/html', 'text/csv']);
    });

    test('a per-call header sets Accept on a String call', () async {
      final accepts = <String?>[];
      final client = _client(accepts);

      await client.send<String>(HttpMethod.get, '/x', headers: {'Accept': 'text/html'});
      await client.sendUri<String>(HttpMethod.get, Uri.parse('https://example.org/x'), headers: {'Accept': 'text/html'});

      expect(accepts, ['text/html', 'text/html']);
    });

    test('a JSON error body is still parsed for send<String>', () async {
      final client = SleekHttpClient(
        client: MockClient(
          (request) async => http.Response(json.encode({'error': 'nope'}), 422, headers: {'content-type': _json}),
        ),
        authorityGetter: () => 'api.example.com',
      );

      await expectLater(
        client.send<String>(HttpMethod.post, '/x'),
        throwsA(isA<HttpResponseException>().having((e) => e.jsonBody, 'jsonBody', {'error': 'nope'})),
      );
    });

    test('buildAuthorizedHeaders() still includes Accept: application/json', () {
      final client = SleekHttpClient(
        client: MockClient((request) async => http.Response('ok', 200)),
        authorizationHeaderGetter: () => 'Bearer token',
      );

      expect(client.buildAuthorizedHeaders(), {'accept': _json, 'authorization': 'Bearer token'});
    });
  });
}

/// A client whose requests' `Accept` header is appended to [accepts].
SleekHttpClient _client(
  List<String?> accepts, {
  http.Response? response,
  Map<String, String> Function()? headersGetter,
}) => SleekHttpClient(
  client: MockClient((request) async {
    accepts.add(request.headers['accept']);
    return response ?? http.Response('ok', 200);
  }),
  authorityGetter: () => 'api.example.com',
  headersGetter: headersGetter,
);
