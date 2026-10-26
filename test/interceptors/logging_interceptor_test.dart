import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sleek_http_client/sleek_http_client.dart';
import 'package:test/test.dart';

const _jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

/// Runs a request through a [LoggingInterceptor] and returns the logged messages.
Future<List<String>> _run(
  LoggingInterceptor Function(void Function(String) logger) interceptorBuilder,
  http.BaseRequest request,
  http.Response Function(http.BaseRequest request) respond,
) async {
  final messages = <String>[];
  await runInterceptorChain(request, [interceptorBuilder(messages.add)], (req) async => respond(req));
  return messages;
}

http.Request _get([String url = 'https://example.com/users/1']) => http.Request('GET', Uri.parse(url));

http.Request _post(String body, [String url = 'https://example.com/reviews']) =>
    http.Request('POST', Uri.parse(url))..body = body;

void main() {
  group('LoggingInterceptor', () {
    group('default (one line per call)', () {
      test('logs a single line with leading, host label, status icon, method, path, duration and body', () async {
        final messages = await _run(
          (logger) => LoggingInterceptor(logger: logger),
          _get(),
          (request) => http.Response('{"id":1}', 200, request: request, headers: _jsonHeaders),
        );

        expect(messages, hasLength(1));
        expect(messages.single, startsWith('🌐 [example.com] 🟢 200 GET /users/1 · '));
        expect(messages.single, matches(RegExp(r'· \d+ ms · \{"id":1\}$')));
        expect(messages.single, isNot(contains('https://')), reason: 'the host is not part of the logged url');
      });

      test('always includes the status code, even for 200', () async {
        final messages = await _run(
          (logger) => LoggingInterceptor(logger: logger),
          _get(),
          (request) => http.Response('ok', 200, request: request),
        );

        expect(messages.single, contains(' 200 '));
      });

      test('uses an icon matching the status code class', () async {
        const expectedIcons = {200: '🟢', 204: '🟢', 301: '🟡', 404: '🟠', 504: '🔴'};

        for (final MapEntry(key: statusCode, value: icon) in expectedIcons.entries) {
          final messages = await _run(
            (logger) => LoggingInterceptor(logger: logger),
            _get(),
            (request) => http.Response('', statusCode, request: request),
          );

          expect(messages.single, contains('$icon $statusCode GET'), reason: 'status $statusCode');
        }
      });

      test('keeps the query string in the logged path, and uses "/" for an empty path', () async {
        final withQuery = await _run(
          (logger) => LoggingInterceptor(logger: logger),
          _get('https://example.com/recherche?query=Paris&type=theater'),
          (request) => http.Response('', 200, request: request),
        );
        expect(withQuery.single, contains(' GET /recherche?query=Paris&type=theater · '));

        final emptyPath = await _run(
          (logger) => LoggingInterceptor(logger: logger),
          _get('https://example.com'),
          (request) => http.Response('', 200, request: request),
        );
        expect(emptyPath.single, contains(' GET / · '));
      });

      test('shows the port in the default label', () async {
        final messages = await _run(
          (logger) => LoggingInterceptor(logger: logger),
          _get('http://localhost:8080/ping'),
          (request) => http.Response('', 200, request: request),
        );

        expect(messages.single, contains('[localhost:8080]'));
      });

      test('merges request and response bodies with an arrow', () async {
        final messages = await _run(
          (logger) => LoggingInterceptor(logger: logger),
          _post('{"note":4}'),
          (request) => http.Response('{"error":"token_expired"}', 401, request: request, headers: _jsonHeaders),
        );

        expect(messages.single, contains('🟠 401 POST /reviews · '));
        expect(messages.single, endsWith('{"note":4} → {"error":"token_expired"}'));
      });

      test('ends with a lone arrow when the request has a body but the response is empty', () async {
        final messages = await _run(
          (logger) => LoggingInterceptor(logger: logger),
          _post('{"note":4}'),
          (request) => http.Response('', 204, request: request),
        );

        expect(messages.single, endsWith('{"note":4} →'));
      });

      test('shows no arrow when the request has no body', () async {
        final messages = await _run(
          (logger) => LoggingInterceptor(logger: logger),
          _get(),
          (request) => http.Response('{"id":1}', 200, request: request, headers: _jsonHeaders),
        );

        expect(messages.single, isNot(contains('→')));
      });

      test('omits the bodies when includeBody is false', () async {
        final messages = await _run(
          (logger) => LoggingInterceptor(logger: logger, includeBody: false),
          _post('{"secret":"request"}'),
          (request) => http.Response('{"secret":"value"}', 200, request: request, headers: _jsonHeaders),
        );

        expect(messages.any((m) => m.contains('secret')), isFalse);
        expect(messages.single, isNot(contains('→')));
      });

      test('removes newlines from the bodies', () async {
        final messages = await _run(
          (logger) => LoggingInterceptor(logger: logger),
          _get(),
          (request) => http.Response('{\n"id":1\n}', 200, request: request, headers: _jsonHeaders),
        );

        expect(messages.single, isNot(contains('\n')));
        expect(messages.single, endsWith('{"id":1}'));
      });

      test('includes request and response headers on their own lines when logHeaders is true', () async {
        final request = _get()..headers['x-test'] = 'abc';

        final messages = await _run(
          (logger) => LoggingInterceptor(logger: logger, logHeaders: true),
          request,
          (req) => http.Response('ok', 200, request: req, headers: {'x-reply': 'def'}),
        );

        expect(messages, hasLength(1));
        final lines = messages.single.split('\n');
        expect(lines, hasLength(3));
        expect(lines[1], contains('request headers'));
        expect(lines[1], contains('x-test'));
        expect(lines[2], contains('response headers'));
        expect(lines[2], contains('x-reply'));
      });
    });

    group('logRequests', () {
      test('logs the request when sent, then the response', () async {
        final messages = await _run(
          (logger) => LoggingInterceptor(logger: logger, logRequests: true),
          _get(),
          (request) => http.Response('{"id":1}', 200, request: request, headers: _jsonHeaders),
        );

        expect(messages, hasLength(2));
        expect(messages[0], '🌐 [example.com] ⬆️ GET /users/1');
        expect(messages[1], startsWith('🌐 [example.com] 🟢 200 GET /users/1 · '));
        expect(messages[1], endsWith('{"id":1}'));
      });

      test('shows the request body on the request line only', () async {
        final messages = await _run(
          (logger) => LoggingInterceptor(logger: logger, logRequests: true),
          _post('{"note":4}'),
          (request) => http.Response('{"id":12}', 201, request: request, headers: _jsonHeaders),
        );

        expect(messages[0], '🌐 [example.com] ⬆️ POST /reviews · {"note":4}');
        expect(messages[1], isNot(contains('{"note":4}')));
        expect(messages[1], isNot(contains('→')));
        expect(messages[1], endsWith('{"id":12}'));
      });

      test('logs request headers with the request and response headers with the response', () async {
        final request = _get()..headers['x-test'] = 'abc';

        final messages = await _run(
          (logger) => LoggingInterceptor(logger: logger, logHeaders: true, logRequests: true),
          request,
          (req) => http.Response('ok', 200, request: req, headers: {'x-reply': 'def'}),
        );

        expect(messages[0], contains('x-test'));
        expect(messages[0], isNot(contains('x-reply')));
        expect(messages[1], contains('x-reply'));
        expect(messages[1], isNot(contains('x-test')));
      });
    });

    group('leading', () {
      test('can be customized', () async {
        final messages = await _run(
          (logger) => LoggingInterceptor(logger: logger, leading: '📡'),
          _get(),
          (request) => http.Response('', 200, request: request),
        );

        expect(messages.single, startsWith('📡 [example.com] '));
      });

      test('null removes it, along with the following space', () async {
        final messages = await _run(
          (logger) => LoggingInterceptor(logger: logger, leading: null),
          _get(),
          (request) => http.Response('', 200, request: request),
        );

        expect(messages.single, startsWith('[example.com] 🟢'));
      });
    });

    group('labelBuilder', () {
      test('replaces the label, and receives the request', () async {
        final messages = await _run(
          (logger) => LoggingInterceptor(
            logger: logger,
            labelBuilder: (request) => 'staging · ${request.url.host}',
          ),
          _get(),
          (request) => http.Response('', 200, request: request),
        );

        expect(messages.single, startsWith('🌐 [staging · example.com] 🟢 200 GET /users/1 · '));
      });

      test('removes the brackets when it returns null or an empty string', () async {
        for (final label in [null, '']) {
          final messages = await _run(
            (logger) => LoggingInterceptor(logger: logger, labelBuilder: (_) => label),
            _get(),
            (request) => http.Response('', 200, request: request),
          );

          expect(messages.single, startsWith('🌐 🟢 200 GET /users/1 · '), reason: 'label: $label');
        }
      });
    });

    group('maxBodyLength', () {
      test('cuts longer bodies and ends them with an ellipsis', () async {
        final messages = await _run(
          (logger) => LoggingInterceptor(logger: logger, maxBodyLength: 5),
          _post('1234567890'),
          (request) => http.Response('abcdefghij', 200, request: request),
        );

        expect(messages.single, endsWith('12345… → abcde…'));
      });

      test('keeps bodies up to the limit, and 500 characters by default', () async {
        final atLimit = 'a' * 500;
        final overLimit = 'a' * 501;

        final defaultAtLimit = await _run(
          (logger) => LoggingInterceptor(logger: logger),
          _get(),
          (request) => http.Response(atLimit, 200, request: request),
        );
        expect(defaultAtLimit.single, endsWith(' · $atLimit'));

        final defaultOverLimit = await _run(
          (logger) => LoggingInterceptor(logger: logger),
          _get(),
          (request) => http.Response(overLimit, 200, request: request),
        );
        expect(defaultOverLimit.single, endsWith(' · $atLimit…'));
      });

      test('null disables truncation', () async {
        final body = 'a' * 2000;

        final messages = await _run(
          (logger) => LoggingInterceptor(logger: logger, maxBodyLength: null),
          _get(),
          (request) => http.Response(body, 200, request: request),
        );

        expect(messages.single, endsWith(' · $body'));
      });
    });

    group('exceptions', () {
      test('logs an exception thrown down the chain on a single ❌ line, then rethrows it unchanged', () async {
        final messages = <String>[];
        final interceptor = LoggingInterceptor(logger: messages.add);
        const error = ConnectivityException(ConnectivityExceptionType.timeout);

        await expectLater(
          runInterceptorChain(_get(), [interceptor], (request) async => throw error),
          throwsA(same(error)),
        );

        expect(messages, hasLength(1));
        expect(messages.single, startsWith('🌐 [example.com] ❌ GET /users/1 · '));
        expect(messages.single, matches(RegExp(r'· \d+ ms · ConnectivityException\(timeout\)$')));
      });

      test('logs the request first, then the ❌ line, when logRequests is true', () async {
        final messages = <String>[];
        final interceptor = LoggingInterceptor(logger: messages.add, logRequests: true);
        const error = ConnectivityException(ConnectivityExceptionType.timeout);

        await expectLater(
          runInterceptorChain(_get(), [interceptor], (request) async => throw error),
          throwsA(same(error)),
        );

        expect(messages, hasLength(2));
        expect(messages[0], contains('⬆️'));
        expect(messages[1], contains('❌'));
        expect(messages[1], contains('ConnectivityException(timeout)'));
      });

      test('logs a ConnectivityException when offline, end-to-end through SleekHttpClient', () async {
        final messages = <String>[];

        final client = SleekHttpClient(
          client: MockClient((request) async => http.Response('ok', 200)),
          authorityGetter: () => 'api.example.com',
          isOnlineChecker: () async => false,
          interceptors: [LoggingInterceptor(logger: messages.add)],
        );

        await expectLater(client.send<String>(HttpMethod.get, '/users/1'), throwsA(isA<ConnectivityException>()));

        expect(messages, hasLength(1));
        expect(messages.single, contains('[api.example.com] ❌ GET /users/1'));
        expect(messages.single, contains('ConnectivityException(noInternet)'));
      });
    });
  });
}

