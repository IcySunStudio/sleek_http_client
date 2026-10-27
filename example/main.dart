// Run with:  dart run example/main.dart
//
// Requires an active internet connection (except scenario 5, which runs
// against an in-memory mocked backend).
// Uses https://jsonplaceholder.typicode.com as a real REST API backend.
//
// connectivity_plus is automatically stubbed out in non-Flutter environments
// via conditional imports — no isOnlineChecker override needed.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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
  await _scenario5LoggingShowcase();

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
    interceptors: [LoggingInterceptor(logger: _printIndented)],
  );

  try {
    final user = await client.send<JsonObject>(HttpMethod.get, '/users/1');
    _pass('Got user: "${user['name']}" <${user['email']}>');
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
      LoggingInterceptor(logger: _printIndented),
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
    authorizationHeaderGetter: () => 'Bearer #$refreshCallCount',
    // Key: new requests started while the refresh is running will pause here
    // instead of being dispatched with the stale token.
    interceptors: [
      tokenRefreshInterceptor,
      LoggingInterceptor(
        logger: _printIndented,
        logHeaders: true,
        logRequests: true,   // Also log each request when sent, to see B and C start while A is being retried
      ),
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

  _pass('A: "${_truncate(results[0]['title'])}"');
  _pass('B: "${_truncate(results[1]['title'])}"');
  _pass('C: "${_truncate(results[2]['title'])}"');
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
      LoggingInterceptor(logger: _printIndented),
    ],
  );

  final first = await client.send<JsonObject>(HttpMethod.get, '/users/2');
  final second = await client.send<JsonObject>(HttpMethod.get, '/users/2');

  _pass('First call:  "${first['name']}" (from network)');
  _pass('Second call: "${second['name']}" (from cache)');
  _assert(networkCallCount == 1, 'exactly one real network call was made', networkCallCount);
}

/// Scenario 5 — Tour of [LoggingInterceptor] output, with every kind of call.
///
/// Runs against an in-memory mocked backend (no internet needed), so every
/// status code class, body shape and failure can be shown. The same calls are
/// logged three times, to compare the options:
///   1. default layout ([LogLayout.multiline]: each body on its own line)
///   2. [LogLayout.compact] (everything on a single line)
///   3. `logRequests` + `logHeaders` + a custom `leading` and `labelBuilder`
///
/// Calls: GET with query (200), GET with a 504, POST with a 401 then a 201,
/// PUT, DELETE (204), a large non-JSON body, a redirect (301), a multipart
/// upload, and a timeout.
Future<void> _scenario5LoggingShowcase() async {
  _header('Scenario 5 — LoggingInterceptor output tour (mocked backend)');

  final tempDir = await Directory.systemTemp.createTemp('sleek_http_client_example');
  try {
    final posterPath = '${tempDir.path}/poster.jpg';
    await File(posterPath).writeAsString('not really a jpeg');

    _print('\n  ── default: LogLayout.multiline ──');
    await _loggingShowcaseCalls(LoggingInterceptor(logger: _printIndented), posterPath);

    _print('\n  ── LogLayout.compact ──');
    await _loggingShowcaseCalls(
      LoggingInterceptor(logger: _printIndented, layout: LogLayout.compact),
      posterPath,
    );

    _print('\n  ── logRequests + logHeaders + custom leading / label (only POST + timeout) ──');
    await _loggingShowcaseCalls(
      LoggingInterceptor(
        logger: _printIndented,
        logRequests: true,
        logHeaders: true,
        leading: '📡',
        labelBuilder: (request) => 'staging',
      ),
      posterPath,
      only: const {2, 3, 8},
    );
  } finally {
    await tempDir.delete(recursive: true);
  }
}

/// Sends a variety of requests through a client logging with [interceptor].
/// Failures are expected (and logged by the interceptor), so they are ignored here.
///
/// [only] restricts the calls to those at the given indices.
Future<void> _loggingShowcaseCalls(
  LoggingInterceptor interceptor,
  String posterPath, {
  Set<int>? only,
}) async {
  final client = SleekHttpClient(
    client: _mockBackend(),
    authorityGetter: () => 'api.example.com',
    authorizationHeaderGetter: () => 'Bearer demo-token',
    isOnlineChecker: () async => true,
    timeOutDuration: const Duration(milliseconds: 600),
    interceptors: [interceptor],
  );

  final calls = <Future<void> Function()>[
    // 0 — 200, JSON body
    () => client.send<JsonObject>(HttpMethod.get, '/films'),
    // 1 — 504, HTML body, query string
    () => client.send<String>(HttpMethod.get, '/recherche', queryParameters: {'query': 'Paris', 'type': 'theater'}),
    // 2 — 401 (first POST), request and response bodies
    () => client.send<JsonObject>(HttpMethod.post, '/reviews', bodyJson: {'movieId': 42, 'note': 4}),
    // 3 — 201 (second POST)
    () => client.send<JsonObject>(HttpMethod.post, '/reviews', bodyJson: {'movieId': 42, 'note': 4}),
    // 4 — 200, PUT
    () => client.send<JsonObject>(HttpMethod.put, '/reviews/12', bodyJson: {'note': 5}),
    // 5 — 204, empty response
    () => client.send<void>(HttpMethod.delete, '/reviews/12'),
    // 6 — 200, large non-JSON body: only its size is logged
    () => client.send<String>(HttpMethod.get, '/films/42/poster'),
    // 7 — 301, not followed by the mocked backend
    () => client.send<void>(HttpMethod.get, '/old'),
    // 8 — timeout: an exception is thrown instead of a response
    () => client.send<void>(HttpMethod.get, '/slow'),
    // 9 — multipart upload
    () => client.sendMultipartRequest<JsonObject>(
      '/upload',
      fields: {'movieId': '42'},
      files: [MultipartRequestFileData(fieldName: 'poster', path: posterPath, contentType: 'image/jpeg')],
    ),
  ];

  for (final (index, call) in calls.indexed) {
    if (only != null && !only.contains(index)) continue;
    try {
      await call();
    } on Object {
      // Expected for 3xx / 4xx / 5xx responses and the timeout: already logged by the interceptor.
    }
  }
}

/// An in-memory backend answering the requests of [_loggingShowcaseCalls].
http.Client _mockBackend() {
  var reviewPosts = 0;

  return MockClient((request) async {
    final route = '${request.method} ${request.url.path}';

    // Never answers: ends in a timeout.
    if (route == 'GET /slow') return Completer<http.Response>().future;

    final (delayMs, response) = switch (route) {
      'GET /films' => (
        142,
        _jsonResponse(200, {
          'films': [
            {'id': 42, 'title': 'Dune'},
            {'id': 43, 'title': 'Alien'},
          ],
        }),
      ),
      'GET /recherche' => (
        312,
        http.Response(
          '<html>\n<body><h1>504 Gateway Time-out</h1></body>\n</html>',
          504,
          headers: {'content-type': 'text/html'},
        ),
      ),
      // First attempt: expired token, second one: success.
      'POST /reviews' => reviewPosts++ == 0
          ? (88, _jsonResponse(401, {'error': 'token_expired'}))
          : (98, _jsonResponse(201, {'id': 12})),
      'PUT /reviews/12' => (76, _jsonResponse(200, {'id': 12, 'movieId': 42, 'note': 5})),
      'DELETE /reviews/12' => (54, http.Response('', 204)),
      'GET /films/42/poster' => (205, http.Response('x' * 20000, 200, headers: {'content-type': 'text/plain'})),
      'GET /old' => (31, http.Response('', 301, headers: {'location': 'https://api.example.com/films'})),
      'POST /upload' => (420, _jsonResponse(201, {'uploaded': 1})),
      _ => (10, http.Response('', 404)),
    };

    await Future<void>.delayed(Duration(milliseconds: delayMs));
    return response;
  });
}

http.Response _jsonResponse(int statusCode, Object body) => http.Response(
  json.encode(body),
  statusCode,
  headers: {'content-type': SleekHttpClient.contentTypeJson},
);

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

/// Prints a (possibly multi-line) log message with every line indented,
/// so headers logged on a second line (via `LoggingInterceptor(logHeaders: true)`)
/// line up with the rest of the output.
void _printIndented(String text) => _print(text.split('\n').map((line) => '  $line').join('\n'));

String _truncate(Object? value, [int max = 40]) {
  final s = value?.toString() ?? '';
  return s.length <= max ? s : '${s.substring(0, max)}…';
}

