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
| **Logging** | `LoggingInterceptor` for request/response bodies and headers |
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

Exceptions thrown instead of a response (no internet, timeout, DNS /
connection failure, ...) are logged too, on a `❌` line, then rethrown
unchanged.

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
