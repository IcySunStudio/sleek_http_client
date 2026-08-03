import 'package:http/http.dart' as http;
import 'package:sleek_http_client/sleek_http_client.dart';
import 'package:test/test.dart';

void main() {
  group('LoggingInterceptor', () {
    test('logs both the outgoing request and the incoming response', () async {
      final messages = <String>[];
      final interceptor = LoggingInterceptor(logger: messages.add);

      await runInterceptorChain(
        http.Request('GET', Uri.parse('https://example.com/users/1'))..body = '',
        [interceptor],
        (request) async => http.Response('{"id":1}', 200, request: request, headers: {
          'content-type': 'application/json; charset=utf-8',
        }),
      );

      expect(messages, hasLength(2));
      expect(messages[0], contains('⬆️'));
      expect(messages[0], contains('GET'));
      expect(messages[0], contains('https://example.com/users/1'));
      expect(messages[1], contains('⬇️'));
      expect(messages[1], contains('{"id":1}'));
    });

    test('includes the status code for non-200 responses', () async {
      final messages = <String>[];
      final interceptor = LoggingInterceptor(logger: messages.add);

      await runInterceptorChain(
        http.Request('GET', Uri.parse('https://example.com/users/1')),
        [interceptor],
        (request) async => http.Response('nope', 404, request: request),
      );

      expect(messages[1], contains('(404)'));
    });

    test('omits the body when includeBody is false', () async {
      final messages = <String>[];
      final interceptor = LoggingInterceptor(logger: messages.add, includeBody: false);

      await runInterceptorChain(
        http.Request('GET', Uri.parse('https://example.com/users/1')),
        [interceptor],
        (request) async => http.Response('{"secret":"value"}', 200, request: request, headers: {
          'content-type': 'application/json; charset=utf-8',
        }),
      );

      expect(messages.any((m) => m.contains('secret')), isFalse);
    });

    test('includes headers when logHeaders is true', () async {
      final messages = <String>[];
      final interceptor = LoggingInterceptor(logger: messages.add, logHeaders: true);

      final request = http.Request('GET', Uri.parse('https://example.com/users/1'));
      request.headers['x-test'] = 'abc';

      await runInterceptorChain(
        request,
        [interceptor],
        (req) async => http.Response('ok', 200, request: req),
      );

      expect(messages[0], contains('x-test'));
    });
  });
}

