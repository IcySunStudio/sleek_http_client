# sleek_http_client

A lightweight, pure-Dart HTTP client built on top of [`package:http`](https://pub.dev/packages/http).

## Features

| Feature | Details |
|---|---|
| **Pure Dart** | No Flutter dependency — works on mobile, desktop, and server |
| **Connectivity check** | Throws `ConnectivityException` before sending if the device is offline |
| **Token refresh** | Automatic retry with a pluggable `shouldRetry` / `onBeforeRetry` pair; concurrent requests share a single refresh call |
| **Pre-send pause** | `beforeSend` hook pauses new requests while a refresh is running, avoiding wasted 401 round-trips |
| **Multipart upload** | `sendMultipartRequest` with transparent retry support |
| **Logging** | Per-client `HttpClientLogConfig` for request/response bodies and headers |
| **Timeout** | Configurable `timeOutDuration` (default 30 s) |

## Getting started

```yaml
dependencies:
  sleek_http_client: ^0.1.0
```

## Usage

```dart
import 'package:sleek_http_client/sleek_http_client.dart';

final client = SleekHttpClient(
  authorityGetter: () => 'api.example.com',
  basePath: '/v1',
  authorizationHeaderGetter: () => 'Bearer $token',
  logConfig: HttpClientLogConfig(logger: print),
);

// GET  → returns Map<String, dynamic>?
final json = await client.send<JsonObject>(HttpMethod.get, '/users/me');

// POST
await client.send<void>(
  HttpMethod.post,
  '/posts',
  bodyJson: {'title': 'Hello'},
);

// File upload
await client.sendMultipartRequest<void>(
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

## Token refresh

Use `TokenRefreshHandler` to automatically retry requests after refreshing an
expired token. Concurrent 401 failures share a single refresh call — subsequent
requests wait for the in-flight refresh rather than triggering a second one.

```dart
final tokenHandler = TokenRefreshHandler(
  // Called once when a 401 is received. Store the new tokens here.
  () async {
    final tokens = await authService.refresh();
    tokenStorage.save(tokens);
  },
  // Paths that must never trigger a refresh (login, the refresh endpoint
  // itself, etc.). A 401 on these is surfaced immediately to the caller.
  excludedPaths: ['/auth/refresh', '/auth/login'],
);

final client = SleekHttpClient(
  authorityGetter: () => 'api.example.com',
  authorizationHeaderGetter: () => tokenStorage.accessToken,
  retryPolicy: tokenHandler,
);
```

**How it works:**

1. A request is about to be sent. `beforeSend` is called first — if a refresh
   is already in progress it pauses here until it completes, then attaches the
   fresh token before sending. No wasted 401.
2. A request returns 401 (token was valid at send time but expired server-side).
3. `shouldRetry` is called — returns `true` if the status is 401 **and** the
   path is not in `excludedPaths`.
4. `onBeforeRetry` runs the refresh callback (de-duplicated across concurrent
   failures).
5. The original request is retried once with the fresh token.
6. If the retry also fails, or if `onBeforeRetry` throws, the error is surfaced
   to the caller.

> **Custom retry logic** — implement `HttpRetryPolicy` directly, or use
> `HttpRetryPolicyBuilder` for a callback-based one-off (e.g. back-off on 429):
>
> ```dart
> SleekHttpClient(
>   retryPolicy: HttpRetryPolicyBuilder(
>     shouldRetry: (e) async => e.statusCode == 429,
>     onBeforeRetry: (_) => Future.delayed(const Duration(seconds: 2)),
>   ),
> );
> ```

## Response types

| Type argument | Returns |
|---|---|
| `JsonObject` | `Map<String, dynamic>?` decoded from JSON body |
| `JsonList` | `List<dynamic>?` decoded from JSON body |
| `String` | Raw response body string |
| `BytesBody` | Raw bytes + MIME type |
| *(omitted / `void`)* | `null` — body is ignored |

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
