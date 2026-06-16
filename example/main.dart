// Run with:  dart run example/main.dart
//
// Requires an active internet connection.
// Uses https://jsonplaceholder.typicode.com as a real REST API backend.
//
// connectivity_plus is automatically stubbed out in non-Flutter environments
// via conditional imports — no isOnlineChecker override needed.

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:sleek_http_client/sleek_http_client.dart';

// =============================================================================
// Entry point
// =============================================================================

Future<void> main() async {
  _banner('sleek_http_client — example & smoke test');
  _print('API → https://jsonplaceholder.typicode.com\n');

  await _scenario1RetryAfter401();
  await _scenario2ExcludedPathNoRetry();
  await _scenario3CleanRequest();

  _print('\nDone.');
}

// =============================================================================
// Scenarios
// =============================================================================

/// Scenario 1 — Normal protected endpoint.
///
/// Flow:
///   GET /posts/1
///     └─ interceptor returns fake 401
///     └─ TokenRefreshHandler.shouldRetry → true (not excluded)
///     └─ TokenRefreshHandler.onBeforeRetry → refresh callback runs
///     └─ retry: GET /posts/1 (real network) → 200
///     └─ post title printed
Future<void> _scenario1RetryAfter401() async {
  _header('Scenario 1 — 401 → refresh → retry → 200');

  var refreshCallCount = 0;

  // The interceptor fires once on /posts, then lets the retry through.
  final interceptor = _Interceptor401Client(interceptPaths: {'/posts'});

  final tokenHandler = TokenRefreshHandler(
    () async {
      refreshCallCount++;
      _print('  🔄 Token refresh called (#$refreshCallCount)');
      // Real app: call /auth/refresh here and store the new tokens.
    },
    // /auth/refresh would normally be here; nothing real to exclude in this demo.
    excludedPaths: ['/auth/refresh'],
  );

  final client = SleekHttpClient(
    client: interceptor,
    authorityGetter: () => 'jsonplaceholder.typicode.com',
    shouldRetry: tokenHandler.shouldRetry,
    onBeforeRetry: tokenHandler.onBeforeRetry,
    logConfig: HttpClientLogConfig(logger: (msg) => _print('  $msg')),
  );

  try {
    final post = await client.send<JsonObject>(HttpMethod.get, '/posts/1');
    _pass('Got post: "${post?['title']}"');
    _assert(refreshCallCount == 1, 'refresh was called exactly once', refreshCallCount);
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

/// Scenario 3 — Clean request, no interception.
///
/// Flow:
///   GET /users/1
///     └─ no interception — real network only
///     └─ 200 → user name printed
Future<void> _scenario3CleanRequest() async {
  _header('Scenario 3 — clean request → 200 directly');

  final client = SleekHttpClient(
    // No custom http.Client → uses the default http.Client (real network).
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
  _Interceptor401Client({required this.interceptPaths}) : _inner = http.Client();

  /// URL path substrings that will be intercepted once.
  final Set<String> interceptPaths;

  final http.Client _inner;

  // Tracks which paths have already been intercepted so the retry goes through.
  final Set<String> _alreadyIntercepted = {};

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final path = request.url.path;

    // Find a matching path that hasn't been intercepted yet.
    final matchedPath = interceptPaths
        .where((p) => path.contains(p) && !_alreadyIntercepted.contains(p))
        .firstOrNull;

    if (matchedPath != null) {
      // Mark it so the retry (or any later call) goes through for real.
      _alreadyIntercepted.add(matchedPath);

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

    // Not intercepted (or already fired once) → real network.
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

void _header(String text) {
  _print('\n┌─ $text');
}

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









