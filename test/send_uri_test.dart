import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sleek_http_client/sleek_http_client.dart';
import 'package:test/test.dart';

void main() {
  group('sendUri', () {
    test('sends the URI as is: scheme, port and repeated query parameters, without authority or basePath', () async {
      late http.BaseRequest sent;
      final client = SleekHttpClient(
        client: MockClient((request) async {
          sent = request;
          return http.Response('<html></html>', 200);
        }),
        authorityGetter: () => 'api.example.com',
        basePath: '/v1',
      );

      final result = await client.sendUri<String>(
        HttpMethod.get,
        Uri.parse('http://tickets.example.org:8080/events/list?tag=a&tag=b&page=2'),
      );

      expect(result, '<html></html>');
      expect(sent.url.toString(), 'http://tickets.example.org:8080/events/list?tag=a&tag=b&page=2');
      expect(sent.url.queryParametersAll['tag'], ['a', 'b']);
      expect(sent.method, 'GET');
    });

    test('works without authorityGetter', () async {
      final client = SleekHttpClient(client: MockClient((request) async => http.Response('ok', 200)));

      expect(await client.sendUri<String>(HttpMethod.get, Uri.parse('https://example.org/x')), 'ok');
    });

    test('send builds its URI like buildUriFromPath and delegates to sendUri', () async {
      late http.BaseRequest sent;
      final client = SleekHttpClient(
        client: MockClient((request) async {
          sent = request;
          return http.Response('ok', 200);
        }),
        authorityGetter: () => 'api.example.com',
        basePath: '/v1',
      );

      await client.send<String>(HttpMethod.get, '/users', queryParameters: {'id': ['1', '2']});
      final viaSend = sent.url;
      await client.sendUri<String>(HttpMethod.get, client.buildUriFromPath('/users', {'id': ['1', '2']}));

      expect(viaSend.toString(), 'https://api.example.com/v1/users?id=1&id=2');
      expect(sent.url, viaSend);
    });

    test('applies headersGetter, the authorization header and per-call headers', () async {
      late http.BaseRequest sent;
      final client = SleekHttpClient(
        client: MockClient((request) async {
          sent = request;
          return http.Response('ok', 200);
        }),
        headersGetter: () => {'x-app': 'sleek'},
        authorizationHeaderGetter: () => 'Bearer token',
      );

      await client.sendUri<String>(
        HttpMethod.get,
        Uri.parse('https://example.org/x'),
        headers: {'x-call': '1'},
      );

      expect(sent.headers['x-app'], 'sleek');
      expect(sent.headers['x-call'], '1');
      expect(sent.headers['authorization'], 'Bearer token');
    });

    test('goes through the interceptors and exposes extra, which is never sent as a header', () async {
      final seen = <Object?>[];
      http.BaseRequest? sent;
      final client = SleekHttpClient(
        client: MockClient((request) async {
          sent = request;
          return http.Response('ok', 200);
        }),
        interceptors: [_ExtraReaderInterceptor('policy', seen.add)],
      );

      await client.sendUri<String>(
        HttpMethod.get,
        Uri.parse('https://example.org/x'),
        extra: {'policy': 'noCache'},
      );

      expect(seen, ['noCache']);
      expect(sent!.headers.values, isNot(contains('noCache')));
    });

    test('bodyJson is encoded with the JSON content-type, stringBody is sent as is', () async {
      final bodies = <String>[];
      final contentTypes = <String?>[];
      final client = SleekHttpClient(
        client: MockClient((request) async {
          bodies.add(request.body);
          contentTypes.add(request.headers[HttpHeaders.contentTypeHeader]);
          return http.Response('ok', 200);
        }),
      );
      final uri = Uri.parse('https://example.org/x');

      await client.sendUri<String>(HttpMethod.post, uri, bodyJson: {'a': 1});
      await client.sendUri<String>(HttpMethod.post, uri, stringBody: 'a=1');

      expect(bodies, [json.encode({'a': 1}), 'a=1']);
      expect(contentTypes.first, SleekHttpClient.contentTypeJson);
      expect(contentTypes.last, startsWith('text/plain'));
    });

    test('parses the response like send, including HTTP errors', () async {
      final client = SleekHttpClient(
        client: MockClient((request) async {
          if (request.url.path == '/ok') {
            return http.Response(json.encode({'id': 1}), 200, headers: {'content-type': 'application/json'});
          }
          return http.Response(json.encode({'error': 'nope'}), 404, headers: {'content-type': 'application/json'});
        }),
      );

      expect(await client.sendUri<JsonObject>(HttpMethod.get, Uri.parse('https://example.org/ok')), {'id': 1});
      await expectLater(
        client.sendUri<JsonObject>(HttpMethod.get, Uri.parse('https://example.org/missing')),
        throwsA(isA<HttpResponseException>().having((e) => e.response.statusCode, 'statusCode', 404)),
      );
    });

    test('abortAll aborts a sendUri call in flight', () async {
      final client = SleekHttpClient(
        client: MockClient.streaming((request, body) {
          final completer = Completer<http.StreamedResponse>();
          if (request case http.Abortable(:final abortTrigger?)) {
            unawaited(abortTrigger.whenComplete(() => completer.completeError(http.RequestAbortedException(request.url))));
          }
          return completer.future;
        }),
      );

      final expectation = expectLater(
        client.sendUri<String>(HttpMethod.get, Uri.parse('https://example.org/x')),
        throwsA(isA<RequestAbortedException>()),
      );
      await Future<void>.delayed(Duration.zero);
      client.abortAll();

      await expectation;
    });

    test('rejects a URI that is not an absolute http(s) URI with a host', () {
      final client = SleekHttpClient(client: MockClient((request) async => http.Response('ok', 200)));

      for (final invalid in ['www.example.org/x', '/relative/path', 'ftp://example.org/x', 'https:///no-host']) {
        expect(
          () => client.sendUri<String>(HttpMethod.get, Uri.parse(invalid)),
          throwsArgumentError,
          reason: invalid,
        );
      }
    });
  });
}

class _ExtraReaderInterceptor implements HttpInterceptor {
  _ExtraReaderInterceptor(this.key, this.onRead);

  final String key;
  final void Function(Object? value) onRead;

  @override
  Future<http.Response> intercept(http.BaseRequest request, HttpInterceptorChain chain) {
    onRead(request.extra[key]);
    return chain.proceed(request);
  }
}
