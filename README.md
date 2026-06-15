# sleek_http_client

A lightweight, pure-Dart HTTP client built on top of [`package:http`](https://pub.dev/packages/http).

## Features

| Feature | Details |
|---|---|
| **Pure Dart** | No Flutter dependency — works on mobile, desktop, and server |
| **Connectivity check** | Throws `ConnectivityException` before sending if the device is offline |
| **Token refresh** | Automatic 401 retry after refreshing tokens; concurrent requests share a single refresh call |
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
  refreshAuthorizationTokens: () async { /* refresh logic */ },
  refreshAuthorizationTokensEndpoint: '/auth/refresh',
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

