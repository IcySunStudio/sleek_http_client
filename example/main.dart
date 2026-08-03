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
  await _scenario4CacheInterceptorShortCircuit();

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
    interceptors: [LoggingInterceptor(logger: (msg) => _print('  $msg'))],
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
///     └─ TokenRefreshInterceptor → excluded path → no retry
///     └─ HttpResponseException(401) surfaced to caller immediately
///     └─ refresh callback is NEVER called
Future<void> _scenario2ExcludedPathNoRetry() async {
  _header('Scenario 2 — 401 on excluded path → error surfaced, no refresh');

  var refreshCallCount = 0;
  final interceptor = _Interceptor401Client(interceptPaths: {'/todos'});

  final tokenRefreshInterceptor = TokenRefreshInterceptor(
    () async {
      refreshCallCount++;
      _print('  🔄 Token refresh called (#$refreshCallCount)');
    },
    // /todos is excluded — simulates a login or refresh endpoint that must never trigger a refresh loop when it returns 401.
    excludedPaths: ['/todos'],
  );

  final client = SleekHttpClient(
    client: interceptor,
    authorityGetter: () => 'jsonplaceholder.typicode.com',
    interceptors: [
      tokenRefreshInterceptor,
      LoggingInterceptor(logger: (msg) => _print('  $msg')),
    ],
  );

  try {
    await client.send<JsonObject>(HttpMethod.get, '/todos/1');
    _fail('Expected a 401 to be thrown, but request succeeded.');
  } on HttpResponseException catch (e) {
    _pass('Got expected error: HttpResponseException(${e.statusCode})');
    _assert(refreshCallCount == 0, 'refresh was never called', refreshCallCount);
  }
}

/// Scenario 3 — 401 triggers refresh; concurrent requests are paused inside
/// [TokenRefreshInterceptor] and never hit the server with a stale token.
///
/// Flow:
///   GET /posts/1  (request A)
///     └─ interceptor returns fake 401
///     └─ refresh starts (artificial 500 ms delay)
///
///   [while refresh is running]
///   GET /posts/2  (request B)  ─┐
///   GET /posts/3  (request C)  ─┴─ pause both until refresh done
///
///   refresh completes → A, B, C all succeed with the fresh token
///   interceptor injects exactly 1 × 401 (only A)
Future<void> _scenario3RetryAfter401WithConcurrentRequests() async {
  _header('Scenario 3 — 401 → refresh → retry + concurrent requests paused');

  var refreshCallCount = 0;
  var interceptorFireCount = 0;

  // Completer lets us know the moment the refresh callback has started,
  // so we can fire B and C while the refresh is still in progress.
  final refreshStarted = Completer<void>();

  final interceptor = _Interceptor401Client(
    interceptPaths: {'/posts'},
    onIntercept: () => interceptorFireCount++,
  );

  final tokenRefreshInterceptor = TokenRefreshInterceptor(
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
    // Key: new requests started while the refresh is running will pause here
    // instead of being dispatched with the stale token.
    interceptors: [
      tokenRefreshInterceptor,
      LoggingInterceptor(logger: (msg) => _print('  $msg')),
    ],
  );

  // Request A — will hit the fake 401 and trigger the refresh.
  final futureA = client.send<JsonObject>(HttpMethod.get, '/posts/1');

  // Wait until the refresh callback has started, then fire B and C.
  // Without the pause they would be sent immediately with the stale token
  // and each get their own 401. With the pause they wait silently.
  await refreshStarted.future;
  _print('  [test] refresh is running — firing B and C now');
  final futureB = client.send<JsonObject>(HttpMethod.get, '/posts/2');
  final futureC = client.send<JsonObject>(HttpMethod.get, '/posts/3');
  // This line executes synchronously before any async work — B and C are now
  // queued but paused inside the interceptor, waiting for the refresh.
  _print('  [test] B and C are paused, waiting for refresh…');

  final results = await Future.wait([futureA, futureB, futureC]);

  _pass('A: "${_truncate(results[0]?['title'])}"');
  _pass('B: "${_truncate(results[1]?['title'])}"');
  _pass('C: "${_truncate(results[2]?['title'])}"');
  _assert(refreshCallCount == 1, 'refresh was called exactly once', refreshCallCount);
  _assert(interceptorFireCount == 1, 'interceptor fired exactly once (only A got a 401)', interceptorFireCount);
}

/// Scenario 4 — A minimal in-memory [_InMemoryCacheInterceptor] short-circuits
/// the network entirely on a cache hit.
///
/// This illustrates the pattern a real disk-based cache interceptor (e.g.
/// backed by `flutter_cache_manager`) would follow — it is intentionally kept
/// out of `sleek_http_client` itself (no extra dependency), but the
/// [HttpInterceptor] API is expressive enough to support it.
///
/// Flow:
///   GET /users/2  (call 1) → cache miss → real network call → cached
///   GET /users/2  (call 2) → cache HIT  → short-circuited, no network call
Future<void> _scenario4CacheInterceptorShortCircuit() async {
  _header('Scenario 4 — CacheInterceptor short-circuits on cache hit');

  var networkCallCount = 0;
  final interceptor = _CountingClient(onSend: () => networkCallCount++);

  final client = SleekHttpClient(
    client: interceptor,
    authorityGetter: () => 'jsonplaceholder.typicode.com',
    interceptors: [
      _InMemoryCacheInterceptor(),
      LoggingInterceptor(logger: (msg) => _print('  $msg')),
    ],
  );

  final first = await client.send<JsonObject>(HttpMethod.get, '/users/2');
  final second = await client.send<JsonObject>(HttpMethod.get, '/users/2');

  _pass('First call:  "${first?['name']}" (from network)');
  _pass('Second call: "${second?['name']}" (from cache)');
  _assert(networkCallCount == 1, 'exactly one real network call was made', networkCallCount);
}

// =============================================================================
// _InMemoryCacheInterceptor — minimal example, no external dependency
// =============================================================================

/// A minimal example [HttpInterceptor] that caches GET responses in memory,
/// keyed by request URL.
///
/// A production-grade version would persist entries to disk (e.g. via
/// `flutter_cache_manager`) and handle cache expiry / invalidation — this
/// simplified version only demonstrates the short-circuit pattern.
class _InMemoryCacheInterceptor implements HttpInterceptor {
  final Map<String, http.Response> _cache = {};

  @override
  Future<http.Response> intercept(http.BaseRequest request, HttpInterceptorChain chain) async {
    if (request.method != 'GET') return chain.proceed(request);

    final key = request.url.toString();
    final cached = _cache[key];
    if (cached != null) {
      _print('  [Cache] ⚡ HIT — reading from cache for $key');
      return cached;
    }

    _print('  [Cache] ❌ MISS — fetching from network for $key');
    final response = await chain.proceed(request);
    if (SleekHttpClient.isStatusCodeSuccess(response.statusCode)) {
      _print('  [Cache] 💾 Writing response to cache for $key');
      _cache[key] = response;
    }
    return response;
  }
}

/// A thin [http.BaseClient] wrapper that counts every real network call.
class _CountingClient extends http.BaseClient {
  _CountingClient({required this.onSend}) : _inner = http.Client();

  final void Function() onSend;
  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    onSend();
    return _inner.send(request);
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }
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

