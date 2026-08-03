import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:sleek_http_client/sleek_http_client.dart';
import 'package:test/test.dart';

void main() {
  group('TokenRefreshInterceptor', () {
    test('does not refresh nor retry on a 401 for an excluded path', () async {
      var refreshCallCount = 0;
      final interceptor = TokenRefreshInterceptor(
        () async => refreshCallCount++,
        excludedPaths: ['/auth/refresh'],
      );

      final response = await runInterceptorChain(
        http.Request('GET', Uri.parse('https://example.com/auth/refresh')),
        [interceptor],
        (request) async => http.Response('unauthorized', 401, request: request),
      );

      expect(response.statusCode, 401);
      expect(refreshCallCount, 0);
    });

    test('refreshes once and retries on a 401 for a non-excluded path', () async {
      var refreshCallCount = 0;
      var attempt = 0;

      final interceptor = TokenRefreshInterceptor(
        () async => refreshCallCount++,
        excludedPaths: ['/auth/refresh'],
      );

      final response = await runInterceptorChain(
        http.Request('GET', Uri.parse('https://example.com/users/me')),
        [interceptor],
        (request) async {
          attempt++;
          return attempt == 1
              ? http.Response('unauthorized', 401, request: request)
              : http.Response('ok', 200, request: request);
        },
      );

      expect(response.statusCode, 200);
      expect(response.body, 'ok');
      expect(refreshCallCount, 1);
      expect(attempt, 2);
    });

    test('de-duplicates concurrent refreshes triggered by concurrent 401s', () async {
      var refreshCallCount = 0;
      var totalCalls = 0;
      final refreshStarted = Completer<void>();

      final interceptor = TokenRefreshInterceptor(
        () async {
          refreshCallCount++;
          refreshStarted.complete();
          await Future<void>.delayed(const Duration(milliseconds: 50));
        },
        excludedPaths: const [],
      );

      // Only the very first network call across A and B returns a 401 —
      // simulates a single stale token shared by both requests. Thanks to the
      // pre-send pause, B's actual network call happens only after the
      // refresh completes, so it is sent with the fresh token directly.
      Future<http.Response> run(String path) {
        return runInterceptorChain(
          http.Request('GET', Uri.parse('https://example.com$path')),
          [interceptor],
          (request) async {
            totalCalls++;
            return totalCalls == 1
                ? http.Response('unauthorized', 401, request: request)
                : http.Response('ok', 200, request: request);
          },
        );
      }

      final futureA = run('/a');
      await refreshStarted.future;
      final futureB = run('/b');

      final results = await Future.wait([futureA, futureB]);

      expect(results[0].statusCode, 200);
      expect(results[1].statusCode, 200);
      expect(refreshCallCount, 1);
    });

    test('surfaces the error when the retry also fails', () async {
      final interceptor = TokenRefreshInterceptor(
        () async {},
        excludedPaths: const [],
      );

      final response = await runInterceptorChain(
        http.Request('GET', Uri.parse('https://example.com/users/me')),
        [interceptor],
        (request) async => http.Response('still unauthorized', 401, request: request),
      );

      expect(response.statusCode, 401);
    });

    test('a 401 retried a second time is not retried again (single retry, no loop)', () async {
      var refreshCallCount = 0;
      var attempt = 0;

      final interceptor = TokenRefreshInterceptor(
        () async => refreshCallCount++,
        excludedPaths: const [],
      );

      final response = await runInterceptorChain(
        http.Request('GET', Uri.parse('https://example.com/users/me')),
        [interceptor],
        (request) async {
          attempt++;
          // Always 401, even after the retry — old behavior only ever retried once.
          return http.Response('unauthorized', 401, request: request);
        },
      );

      expect(response.statusCode, 401);
      expect(refreshCallCount, 1, reason: 'refresh is attempted once, not once per failed attempt');
      expect(attempt, 2, reason: 'exactly one retry: the initial attempt + one retry, no more');
    });

    test('propagates the error thrown by the refresh callback instead of retrying', () async {
      var attempt = 0;
      final interceptor = TokenRefreshInterceptor(
        () async => throw StateError('refresh failed'),
        excludedPaths: const [],
      );

      Future<http.Response> call() => runInterceptorChain(
        http.Request('GET', Uri.parse('https://example.com/users/me')),
        [interceptor],
        (request) async {
          attempt++;
          return http.Response('unauthorized', 401, request: request);
        },
      );

      await expectLater(call(), throwsA(isA<StateError>()));
      expect(attempt, 1, reason: 'the retry never happens since the refresh itself threw');
    });

    test('retry decision is based on the raw status code, independent of any error parsing', () async {
      // Mirrors the old behavior where shouldRetry only ever inspected
      // HttpResponseException.statusCode (itself just response.statusCode),
      // regardless of a custom errorBuilder used later for parsing.
      var refreshCallCount = 0;
      var attempt = 0;

      final interceptor = TokenRefreshInterceptor(
        () async => refreshCallCount++,
        excludedPaths: const [],
      );

      final response = await runInterceptorChain(
        http.Request('GET', Uri.parse('https://example.com/users/me')),
        [interceptor],
        (request) async {
          attempt++;
          return attempt == 1
              ? http.Response('{"error":"expired"}', 401, request: request)
              : http.Response('{"ok":true}', 200, request: request);
        },
      );

      expect(response.statusCode, 200);
      expect(refreshCallCount, 1);
    });
  });
}


