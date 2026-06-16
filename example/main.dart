// Run with:  dart run example/main.dart
//
// Requires an active internet connection.
// Uses https://jsonplaceholder.typicode.com as a real REST API backend.
//
// connectivity_plus is automatically stubbed out in non-Flutter environments
// via conditional imports — no isOnlineChecker override needed.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:sleek_http_client/sleek_http_client.dart';

// =============================================================================
// Entry point
// =============================================================================

Future<void> main() async {
  _banner('sleek_http_client — example & smoke test');
  _print('API → https://jsonplaceholder.typicode.com\n');

  await _scenario1CleanRequest();
  await _scenario2ExcludedPathNoRetry();
  await _scenario3RetryAfter401WithConcurrentRequests();

  _print('\nDone.');
}

// =============================================================================
// Scenarios
// =============================================================================

/// Scenario 1 — Clean request, no auth, no retry.
///
/// Flow:
///   GET /users/1
///     └─ no interception — real network only
///     └─ 200 → user name printed
Future<void> _scenario1CleanRequest() async {
  _header('Scenario 1 — clean request → 200 directly');

  final client = SleekHttpClient(
    authorityGetter: () => 'jsonplaceholder.typicode.com',
    logConfig: HttpClientLogConfig(logger: (msg) => _print('  $msg')),
  );

  try {
    final user = await client.send<JsonObject>(HttpMethod.get, '/users/1');
    _pass('Got user: "${user?['name']}" <${user?['email']}>');
  } on HttpResponseException catch (e) {
    _fail('Unexpected HTTP error: $e');
  }
}

/// Scenario 2 — 401 on an excluded path.
///
/// Flow:
///   GET /todos/1
///     └─ interceptor returns fake 401
///     └─ TokenRefreshHandler.shouldRetry → false (/todos is in excludedPaths)
///     └─ HttpResponseException(401) surfaced to caller immediately
///     └─ refresh callback is NEVER called
Future<void> _scenario2ExcludedPathNoRetry() async {
  _header('Scenario 2 — 401 on excluded path → error surfaced, no refresh');

  var refreshCallCount = 0;
  final interceptor = _Interceptor401Client(interceptPaths: {'/todos'});

  final tokenHandler = TokenRefreshHandler(
    () async {
      refreshCallCount++;
      _print('  🔄 Token refresh called (#$refreshCallCount)');
    },
    // /todos is excluded — simulates a login or refresh endpoint that must
    // never trigger a refresh loop when it returns 401.
    excludedPaths: ['/todos'],
  );

  final client = SleekHttpClient(
    client: interceptor,
    authorityGetter: () => 'jsonplaceholder.typicode.com',
    shouldRetry: tokenHandler.shouldRetry,
    onBeforeRetry: tokenHandler.onBeforeRetry,
    beforeSend: tokenHandler.beforeSend,
    logConfig: HttpClientLogConfig(logger: (msg) => _print('  $msg')),
  );

  try {
    await client.send<JsonObject>(HttpMethod.get, '/todos/1');
    _fail('Expected a 401 to be thrown, but request succeeded.');
  } on HttpResponseException catch (e) {
    _pass('Got expected error: HttpResponseException(${e.statusCode})');
    _assert(refreshCallCount == 0, 'refresh was never called', refreshCallCount);
  }
}

/// Scenario 3 — 401 triggers refresh; concurrent requests are paused by
/// [TokenRefreshHandler.beforeSend] and never hit the server with a stale token.
///
/// Flow:
///   GET /posts/1  (request A)
///     └─ interceptor returns fake 401
///     └─ shouldRetry → true → refresh starts (artificial 150 ms delay)
///
///   [while refresh is running]
///   GET /posts/2  (request B)  ─┐
///   GET /posts/3  (request C)  ─┴─ beforeSend pauses both until refresh done
///
///   refresh completes → A, B, C all succeed with the fresh token
///   interceptor injects exactly 1 × 401 (only A)
Future<void> _scenario3RetryAfter401WithConcurrentRequests() async {
  _header('Scenario 3 — 401 → refresh → retry + concurrent requests paused by beforeSend');

  var refreshCallCount = 0;
  var interceptorFireCount = 0;

  // Completer lets us know the moment the refresh callback has started,
  // so we can fire B and C while the refresh is still in progress.
  final refreshStarted = Completer<void>();

  final interceptor = _Interceptor401Client(
    interceptPaths: {'/posts'},
    onIntercept: () => interceptorFireCount++,
  );

  final tokenHandler = TokenRefreshHandler(
    () async {
      refreshCallCount++;
      _print('  🔄 Token refresh started (#$refreshCallCount)');
      refreshStarted.complete();
      // Simulate a slow network call to the refresh endpoint.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      _print('  ✔️  Token refresh done');
    },
    excludedPaths: ['/auth/refresh'],
  );

  final client = SleekHttpClient(
    client: interceptor,
    authorityGetter: () => 'jsonplaceholder.typicode.com',
    shouldRetry: tokenHandler.shouldRetry,
    onBeforeRetry: tokenHandler.onBeforeRetry,
    // Key: new requests started while the refresh is running will pause here
    // instead of being dispatched with the stale token.
    beforeSend: tokenHandler.beforeSend,
    logConfig: HttpClientLogConfig(logger: (msg) => _print('  $msg')),
  );

  // Request A — will hit the fake 401 and trigger the refresh.
  final futureA = client.send<JsonObject>(HttpMethod.get, '/posts/1');

  // Wait until the refresh callback has started, then fire B and C.
  // Without beforeSend they would be sent immediately with the stale token
  // and each get their own 401. With beforeSend they pause silently.
  await refreshStarted.future;
  _print('  [test] refresh is running — firing B and C now');
  final futureB = client.send<JsonObject>(HttpMethod.get, '/posts/2');
  final futureC = client.send<JsonObject>(HttpMethod.get, '/posts/3');
  // This line executes synchronously before any async work — B and C are now
  // queued but their beforeSend is blocking them from being dispatched yet.
  _print('  [test] B and C are paused by beforeSend, waiting for refresh…');

  final results = await Future.wait([futureA, futureB, futureC]);

  _pass('A: "${_truncate(results[0]?['title'])}"');
  _pass('B: "${_truncate(results[1]?['title'])}"');
  _pass('C: "${_truncate(results[2]?['title'])}"');
  _assert(refreshCallCount == 1, 'refresh was called exactly once', refreshCallCount);
  _assert(interceptorFireCount == 1, 'interceptor fired exactly once (only A got a 401)', interceptorFireCount);
}

// =============================================================================
// _Interceptor401Client
// =============================================================================

/// A thin [http.BaseClient] wrapper that returns a fake `401 Unauthorized`
/// response on the **first** request whose URL path contains one of
/// [interceptPaths].
///
/// All subsequent requests — including the automatic retry — are forwarded to
/// the real network via the inner [http.Client]. This simulates an expired
/// token without mocking the entire network stack.
class _Interceptor401Client extends http.BaseClient {
  _Interceptor401Client({
    required this.interceptPaths,
    this.onIntercept,
  }) : _inner = http.Client();

  /// URL path substrings that will be intercepted once.
  final Set<String> interceptPaths;

  /// Called each time a 401 is injected (useful for counting in tests).
  final void Function()? onIntercept;

  final http.Client _inner;

  // Tracks which paths have already been intercepted so the retry goes through.
  final Set<String> _alreadyIntercepted = {};

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final path = request.url.path;

    final matchedPath = interceptPaths
        .where((p) => path.contains(p) && !_alreadyIntercepted.contains(p))
        .firstOrNull;

    if (matchedPath != null) {
      _alreadyIntercepted.add(matchedPath);
      onIntercept?.call();
      _print('  [Interceptor] ⚡ Injecting 401 for $path');

      return Future.value(
        http.StreamedResponse(
          Stream.value(utf8.encode('{"error":"Unauthorized"}')),
          401,
          request: request,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      );
    }

    return _inner.send(request);
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }
}

// =============================================================================
// Output helpers
// =============================================================================

void _banner(String text) {
  final line = '═' * 60;
  _print(line);
  _print('  $text');
  _print(line);
}

void _header(String text) => _print('\n┌─ $text');

void _pass(String text) => _print('│  ✅  $text');
void _fail(String text) => _print('│  ❌  $text');

void _assert(bool condition, String description, Object actual) {
  if (condition) {
    _print('│  ✅  assert: $description');
  } else {
    _print('│  ❌  assert FAILED: $description (got: $actual)');
  }
}

void _print(String text) => print(text); // ignore: avoid_print

String _truncate(Object? value, [int max = 40]) {
  final s = value?.toString() ?? '';
  return s.length <= max ? s : '${s.substring(0, max)}…';
}

