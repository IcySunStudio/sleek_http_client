import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sleek_http_client/sleek_http_client.dart';
import 'package:test/test.dart';

void main() {
  group('SleekHttpClient', () {
    test('send<JsonObject> parses a successful JSON response', () async {
      final mockClient = MockClient((request) async {
        expect(request.url.toString(), 'https://api.example.com/users/1');
        return http.Response(
          json.encode({'id': 1, 'name': 'Ada'}),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });

      final client = SleekHttpClient(
        client: mockClient,
        authorityGetter: () => 'api.example.com',
      );

      final result = await client.send<JsonObject>(HttpMethod.get, '/users/1');
      expect(result, {'id': 1, 'name': 'Ada'});
    });

    test('send<JsonObject>() throws NullResponseBodyException on a literal JSON null body', () async {
      final mockClient = MockClient((request) async {
        return http.Response('null', 200, headers: {'content-type': 'application/json; charset=utf-8'});
      });

      final client = SleekHttpClient(
        client: mockClient,
        authorityGetter: () => 'api.example.com',
      );

      expect(
        () => client.send<JsonObject>(HttpMethod.get, '/users/1'),
        throwsA(
          isA<NullResponseBodyException>().having((e) => e.expectedType, 'expectedType', JsonObject),
        ),
      );
    });

    test('send<JsonObject?>() resolves to null on a literal JSON null body', () async {
      final mockClient = MockClient((request) async {
        return http.Response('null', 200, headers: {'content-type': 'application/json; charset=utf-8'});
      });

      final client = SleekHttpClient(
        client: mockClient,
        authorityGetter: () => 'api.example.com',
      );

      final result = await client.send<JsonObject?>(HttpMethod.get, '/users/1');
      expect(result, isNull);
    });

    test('send<JsonObject>() throws FormatException on a malformed JSON body', () async {
      final mockClient = MockClient((request) async {
        return http.Response('not json', 200, headers: {'content-type': 'application/json; charset=utf-8'});
      });

      final client = SleekHttpClient(
        client: mockClient,
        authorityGetter: () => 'api.example.com',
      );

      expect(
        () => client.send<JsonObject>(HttpMethod.get, '/users/1'),
        throwsA(isA<FormatException>()),
      );
    });

    test('send<JsonObject>() throws TypeError on a wrong-shape JSON body (a list instead of an object)', () async {
      final mockClient = MockClient((request) async {
        return http.Response('[1,2,3]', 200, headers: {'content-type': 'application/json; charset=utf-8'});
      });

      final client = SleekHttpClient(
        client: mockClient,
        authorityGetter: () => 'api.example.com',
      );

      expect(
        () => client.send<JsonObject>(HttpMethod.get, '/users/1'),
        throwsA(isA<TypeError>()),
      );
    });

    test('throws HttpResponseException on a non-2xx response', () async {
      final mockClient = MockClient((request) async {
        return http.Response(
          json.encode({'error': 'nope'}),
          404,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });

      final client = SleekHttpClient(
        client: mockClient,
        authorityGetter: () => 'api.example.com',
      );

      expect(
        () => client.send<JsonObject>(HttpMethod.get, '/missing'),
        throwsA(isA<HttpResponseException>().having((e) => e.statusCode, 'statusCode', 404)),
      );
    });

    test('throws ConnectivityException when offline', () async {
      final mockClient = MockClient((request) async => http.Response('ok', 200));

      final client = SleekHttpClient(
        client: mockClient,
        authorityGetter: () => 'api.example.com',
        isOnlineChecker: () async => false,
      );

      expect(
        () => client.send<JsonObject>(HttpMethod.get, '/users/1'),
        throwsA(
          isA<ConnectivityException>().having((e) => e.type, 'type', ConnectivityExceptionType.noInternet),
        ),
      );
    });

    test('uses a custom errorBuilder for non-2xx responses', () async {
      final mockClient = MockClient((request) async => http.Response('nope', 500));

      final client = SleekHttpClient(
        client: mockClient,
        authorityGetter: () => 'api.example.com',
        errorBuilder: (response, json) => _CustomException(response),
      );

      expect(
        () => client.send<JsonObject>(HttpMethod.get, '/boom'),
        throwsA(isA<_CustomException>()),
      );
    });

    test('runs the full interceptor chain (token refresh + logging)', () async {
      var attempt = 0;
      var refreshCallCount = 0;
      final logs = <String>[];

      final mockClient = MockClient((request) async {
        attempt++;
        if (attempt == 1) return http.Response('unauthorized', 401);
        return http.Response(
          json.encode({'ok': true}),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });

      final client = SleekHttpClient(
        client: mockClient,
        authorityGetter: () => 'api.example.com',
        interceptors: [
          TokenRefreshInterceptor(
            () async => refreshCallCount++,
            excludedPaths: const [],
          ),
          LoggingInterceptor(logger: logs.add),
        ],
      );

      final result = await client.send<JsonObject>(HttpMethod.get, '/secure');

      expect(result, {'ok': true});
      expect(attempt, 2);
      expect(refreshCallCount, 1);
      // 2 attempts × (request + response) = 4 log lines.
      expect(logs, hasLength(4));
    });

    test('sends the freshest auth header on every attempt', () async {
      var token = 'stale-token';
      final seenHeaders = <String>[];

      final mockClient = MockClient((request) async {
        seenHeaders.add(request.headers['authorization'] ?? '');
        if (seenHeaders.length == 1) return http.Response('unauthorized', 401);
        return http.Response('ok', 200);
      });

      final client = SleekHttpClient(
        client: mockClient,
        authorityGetter: () => 'api.example.com',
        authorizationHeaderGetter: () => 'Bearer $token',
        interceptors: [
          TokenRefreshInterceptor(
            () async => token = 'fresh-token',
            excludedPaths: const [],
          ),
        ],
      );

      await client.send(HttpMethod.get, '/secure');

      expect(seenHeaders, ['Bearer stale-token', 'Bearer fresh-token']);
    });

    test(
      'LoggingInterceptor observes the actual Authorization header, even without reordering interceptors',
      () async {
        // authorizationHeaderGetter + a LoggingInterceptor placed innermost:
        // SleekHttpClient must auto-insert the auth-header attachment right
        // before LoggingInterceptor, so logHeaders:true reflects what was
        // actually sent — not the pre-attachment request.
        final mockClient = MockClient((request) async => http.Response('ok', 200));
        final logs = <String>[];

        final client = SleekHttpClient(
          client: mockClient,
          authorityGetter: () => 'api.example.com',
          authorizationHeaderGetter: () => 'Bearer secret-token',
          interceptors: [LoggingInterceptor(logger: logs.add, logHeaders: true)],
        );

        await client.send(HttpMethod.get, '/secure');

        final requestLog = logs.first;
        expect(requestLog, contains('Bearer secret-token'));
      },
    );

    test(
      'concurrent requests are paused during an in-flight refresh and gracefully resumed with the fresh token',
      () async {
        // A hits a real 401 (stale token) and triggers the refresh.
        // B and C are started *while the refresh is running*: they must be
        // paused by TokenRefreshInterceptor.intercept and only sent once the
        // refresh completes — with the fresh token directly, never hitting a
        // 401 of their own, and never triggering a second refresh call.
        var token = 'stale-token';
        var refreshCallCount = 0;
        var networkCallCount = 0;
        final refreshStarted = Completer<void>();
        final seenTokensAtNetworkTime = <String>[];

        final mockClient = MockClient((request) async {
          networkCallCount++;
          final authHeader = request.headers['authorization'] ?? '';
          seenTokensAtNetworkTime.add(authHeader);

          // Only the very first network call (request A, stale token) is
          // rejected — everything else (A's retry, B, C) must already carry
          // the fresh token thanks to the pause.
          if (networkCallCount == 1) {
            return http.Response('unauthorized', 401);
          }
          return http.Response(
            json.encode({'ok': true}),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        });

        final client = SleekHttpClient(
          client: mockClient,
          authorityGetter: () => 'api.example.com',
          authorizationHeaderGetter: () => 'Bearer $token',
          interceptors: [
            TokenRefreshInterceptor(
              () async {
                refreshCallCount++;
                refreshStarted.complete();
                await Future<void>.delayed(const Duration(milliseconds: 30));
                token = 'fresh-token';
              },
              excludedPaths: const [],
            ),
          ],
        );

        final futureA = client.send<JsonObject>(HttpMethod.get, '/a');

        // Wait until the refresh is actually running, then fire B and C.
        await refreshStarted.future;
        final futureB = client.send<JsonObject>(HttpMethod.get, '/b');
        final futureC = client.send<JsonObject>(HttpMethod.get, '/c');

        final results = await Future.wait([futureA, futureB, futureC]);

        expect(results, everyElement({'ok': true}));
        expect(refreshCallCount, 1, reason: 'the refresh is de-duplicated across A, B and C');
        expect(networkCallCount, 4, reason: "A's initial 401 + A's retry + B + C");
        // First call is A's stale-token attempt (the only 401); every
        // subsequent network call — A's retry, B, C — already carries the
        // fresh token, proving B and C were paused until the refresh finished.
        expect(seenTokensAtNetworkTime[0], 'Bearer stale-token');
        expect(seenTokensAtNetworkTime.skip(1), everyElement('Bearer fresh-token'));
      },
    );
  });
}

class _CustomException extends HttpResponseException {
  _CustomException(super.response);
}




