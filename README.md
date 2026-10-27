# sleek_http_client

A lightweight, pure-Dart HTTP client built on top of [`package:http`](https://pub.dev/packages/http).

## Features

| Feature | Details |
|---|---|
| **Pure Dart** | No Flutter dependency — works on mobile, desktop, and server |
| **Connectivity check** | Throws `ConnectivityException` before sending if the device is offline |
| **Interceptor chain** | Composable `HttpInterceptor` chain — retry, token refresh, logging, caching, ... |
| **Token refresh** | `TokenRefreshInterceptor`: automatic 401 retry with de-duplicated refresh, shared across concurrent requests |
| **Multipart upload** | `sendMultipartRequest` with transparent retry support |
| **Logging** | `LoggingInterceptor`: readable log of each call (status icon, duration, bodies, optional headers), multiline or compact |
| **Timeout** | Configurable `timeOutDuration` (default 30 s) |

## Getting started

```yaml
dependencies:
  sleek_http_client: ^1.0.0
```

## Usage

```dart
import 'package:sleek_http_client/sleek_http_client.dart';

final client = SleekHttpClient(
  authorityGetter: () => 'api.example.com',
  basePath: '/v1',
  authorizationHeaderGetter: () => 'Bearer $token',
  interceptors: [LoggingInterceptor(logger: print)],
);

// GET  → returns Map<String, dynamic> (throws if the body is missing/malformed)
final json = await client.send<JsonObject>(HttpMethod.get, '/users/me');

// POST — omit the type argument (defaults to dynamic) when you don't care about the body
await client.send(
  HttpMethod.post,
  '/posts',
  bodyJson: {'title': 'Hello'},
);

// `authorityGetter` is optional: pass `authority` per call instead (a StateError is thrown if neither is set)
await client.send(HttpMethod.get, '/health', authority: 'status.example.com');

// File upload
await client.sendMultipartRequest(
  '/upload',
  files: [
    MultipartRequestFileData(
      fieldName: 'file',
      path: '/tmp/photo.jpg',
      contentType: 'image/jpeg',
    ),
  ],
);
```

## Interceptors

`SleekHttpClient.interceptors` is a chain-of-responsibility list, evaluated in
order: index `0` is the **outermost** interceptor (sees every retry /
short-circuit decision made by interceptors after it); the last one is the
**innermost**, closest to the actual network call.

```dart
abstract interface class HttpInterceptor {
  Future<http.Response> intercept(http.BaseRequest request, HttpInterceptorChain chain);
}

abstract interface class HttpInterceptorChain {
  Future<http.Response> proceed(http.BaseRequest request);
}
```

Each interceptor can:
- Mutate `request` before calling `chain.proceed(request)`.
- Short-circuit entirely by returning a `http.Response` **without** calling
  `proceed` (e.g. a cache hit — see below).
- Inspect / retry after `proceed` returns (e.g. token refresh).
- Wrap `proceed` to observe both the outgoing request and the incoming
  response (e.g. logging).

It operates on the raw `http.BaseRequest` → `http.Response`, independently of
the generic `T` requested by the caller — the typed parsing (`send<T>`) always
happens once, after the whole chain completes.

### Token refresh

Use `TokenRefreshInterceptor` to automatically retry requests after refreshing
an expired token. Concurrent 401 failures share a single refresh call —
subsequent requests wait for the in-flight refresh rather than triggering a
second one, and are also paused if a refresh is already running when they
start (so they pick up the fresh token instead of a known-stale one).

```dart
final client = SleekHttpClient(
  authorityGetter: () => 'api.example.com',
  authorizationHeaderGetter: () => tokenStorage.accessToken,
  interceptors: [
    TokenRefreshInterceptor(
      // Called once when a 401 is received. Store the new tokens here.
      () async {
        final tokens = await authService.refresh();
        tokenStorage.save(tokens);
      },
      // Paths that must never trigger a refresh (login, the refresh endpoint
      // itself, etc.). A 401 on these is surfaced immediately to the caller.
      excludedPaths: ['/auth/refresh', '/auth/login'],
    ),
  ],
);
```

**How it works:**

1. A request enters `TokenRefreshInterceptor.intercept`. If a refresh is
   already in progress, it pauses here until it completes (the fresh token is
   attached by `SleekHttpClient` right before every network call — no wasted
   401).
2. `chain.proceed(request)` runs the rest of the chain and the actual network
   call.
3. If the response is 401 **and** the path is not in `excludedPaths`, the
   refresh callback runs (de-duplicated across concurrent failures).
4. The original request is retried once via `chain.proceed` with a fresh copy.
5. If the retry also fails, or the refresh throws, the error/response is
   surfaced to the caller as-is.

> **Custom retry logic** — implement `HttpInterceptor` directly; it's a
> single method:
>
> ```dart
> class BackOffOn429 implements HttpInterceptor {
>   @override
>   Future<http.Response> intercept(http.BaseRequest request, HttpInterceptorChain chain) async {
>     final response = await chain.proceed(request);
>     if (response.statusCode != 429) return response;
>     await Future.delayed(const Duration(seconds: 2));
>     return chain.proceed(await request.copyAsNew());
>   }
> }
> ```

### Caching

`sleek_http_client` does **not** ship a cache interceptor (to stay
dependency-free), but the `HttpInterceptor` API supports a full network
short-circuit on cache hit. See `example/main.dart` (`_InMemoryCacheInterceptor`)
for a minimal illustration of the pattern — a production version would persist
entries to disk (e.g. via `flutter_cache_manager`) and handle expiry.

Place a cache interceptor **first** in `interceptors` so a cache hit
short-circuits everything after it (auth header attachment, token refresh,
logging, the real network call).

### Per-request `extra`

Pass typed data to interceptors, per call, without going through HTTP headers
(a header is a string and would be sent to the server):

```dart
await client.send<JsonObject>(
  HttpMethod.get,
  '/users',
  extra: {'cachePolicy': CachePolicy.noCache},
);

// In an interceptor:
final policy = request.extra['cachePolicy'] as CachePolicy? ?? CachePolicy.normal;
```

`extra` is also accepted by `sendMultipartRequest`. To report information back
to the caller (cache date, origin, ...), pass a mutable object in the `extra`
and let the interceptor fill it — no need to return anything else than the
response:

```dart
final info = CacheInfo();
await client.send<JsonObject>(HttpMethod.get, '/users', extra: {'cacheInfo': info});
print(info.fromCache);
```

`copyAsNew()` copies the `extra` entries to the new request, so they are still
available when an interceptor (e.g. `TokenRefreshInterceptor`) retries.

## Response types

`send<T>`/`sendMultipartRequest<T>` return `T` directly — **not** `T?`. For
`JsonObject`/`JsonList`, `T`'s own nullability controls what happens when the
server returns a `null` body:

| Type argument | Returns | If the body is JSON `null` or empty |
|---|---|---|
| `JsonObject` | `Map<String, dynamic>` | throws `NullResponseBodyException` |
| `JsonObject?` | `Map<String, dynamic>?` | `null` |
| `JsonList` | `List<dynamic>` | throws `NullResponseBodyException` |
| `JsonList?` | `List<dynamic>?` | `null` |
| `String` | Raw response body string (never null) | — |
| `BytesBody` | Raw bytes + MIME type (never null) | — |
| *(omitted / `void` / `Null` / `Object?` / `dynamic`)* | `null` — body is ignored | — |

A malformed body, or JSON of the wrong shape (e.g. a list where an object was
expected), always throws — `FormatException` / `TypeError` respectively —
regardless of nullability: only an explicit JSON `null` (or an empty body,
e.g. `204 No Content`) is treated as a legitimate value.

## Logging

Pass a `LoggingInterceptor` to control what gets logged. Place it **last** in
`interceptors` so only real network calls are logged (not short-circuits from
earlier interceptors, e.g. a cache hit). For Flutter apps, a common setup is
to use `debugPrint` as the logger, skip headers (which may contain sensitive
tokens), and only include bodies outside of release mode.

By default, one message is logged per call, once the response is received,
with the request / response bodies on their own lines:

```text
🌐 [api.example.com] 🟢 200 GET /films · 142 ms
  ⬇️ {"films":[…]}
🌐 [api.example.com] 🟠 401 POST /reviews · 88 ms
  ⬆️ {"note":4}
  ⬇️ {"error":"token_expired"}
🌐 [api.example.com] 🔴 504 GET /recherche?query=Paris · 312 ms
  ⬇️ <html>Gateway Timeout</html>
```

- The status icon reflects the status code (🟢 2xx, 🟡 3xx, 🟠 4xx, 🔴 5xx).
  Non-2xx responses are logged as regular responses: they only become
  exceptions when parsed, after the interceptor chain.
- The URL is logged without its host, which is shown in the `[label]`
  instead (the request host by default, see `labelBuilder`).
- Bodies longer than `maxBodyLength` (500 by default) are cut with `…`.

Exceptions thrown instead of a response (no internet, timeout, DNS /
connection failure, ...) are logged too, on a `❌` line, then rethrown
unchanged:

```text
🌐 [api.example.com] ❌ GET /films · 30001 ms · ConnectivityException(timeout)
```

```dart
import 'package:flutter/foundation.dart';

final client = SleekHttpClient(
  authorityGetter: () => 'api.example.com',
  interceptors: [
    LoggingInterceptor(
      logger: debugPrint,
      logHeaders: false,
      includeBody: !kReleaseMode,
    ),
  ],
);
```

### Customizing the output

| Parameter | Details |
|---|---|
| `layout` | `LogLayout.multiline` (default): each body on its own line. `LogLayout.compact`: everything on a single line, easier to filter. |
| `labelBuilder` | `(request) => label` displayed between brackets. Defaults to the request host. Use it to show an environment, or a short name per API. A `null` or empty result removes the brackets. |
| `leading` | Marker at the start of every message (`🌐` by default). `null` removes it. |
| `logRequests` | Also log each request when it is sent (`⬆️`), e.g. to spot calls that never complete. |
| `maxBodyLength` | Maximum length of each logged body (`500` by default). `null` disables truncation. |
| `logHeaders` | Also log the request and response headers, on indented lines. |
| `includeBody` | Whether to log the bodies at all. |

With `LogLayout.compact`, a call takes a single line. When the request has a
body, both bodies are told apart with `⬆️` / `⬇️`:

```text
🌐 [api.example.com] 🟢 200 GET /films · 142 ms · {"films":[…]}
🌐 [api.example.com] 🟠 401 POST /reviews · 88 ms · ⬆️ {"note":4} ⬇️ {"error":"token_expired"}
```

```dart
LoggingInterceptor(
  logger: debugPrint,
  labelBuilder: (request) => '${environment.name} · ${request.url.host}',
  logRequests: true,
);
```

```text
🌐 [staging · api.example.com] ⬆️ GET /films
🌐 [staging · api.example.com] 🟢 200 GET /films · 142 ms
  ⬇️ {"films":[…]}
```

Run `dart run example/main.dart` (scenario 5) to see the output for every kind
of call.

## Error handling

Non-2xx responses throw `HttpResponseException`. Provide an `errorBuilder` to
wrap it into a domain-specific exception.

```dart
final client = SleekHttpClient(
  authorityGetter: () => 'api.example.com',
  errorBuilder: (response, json) => MyApiException(response, json),
);
```

Connectivity problems throw `ConnectivityException`.
