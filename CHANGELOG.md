# Changelog

## Unreleased
- **BREAKING (log format)** `LoggingInterceptor` now logs a single line per call, once the response (or exception) is received, instead of one line for the request and one for the response:
  `🌐 [api.example.com] 🟢 200 GET /films · 142 ms · {…}`.
  - The status code is always shown, with an icon matching its class: 🟢 2xx, 🟡 3xx, 🟠 4xx, 🔴 5xx (❌ for an exception). The duration of the call is shown too.
  - The URL is logged without its host, shown in a `[label]` instead.
  - When the request has a body, it is shown before the response body: `{request} → {response}`.
  - Bodies are cut after 500 characters by default.
  - The `[SleekHttp]` prefix is gone. Replaced by labelBuilder (see below)
  - The headers (`logHeaders`) are now logged on their own indented lines, as `request headers` / `response headers`.
- Added `LoggingInterceptor.labelBuilder` (label of each line, the request host by default), `leading` (marker at the start of each line, `🌐` by default, `null` to remove it), `logRequests` (also log each request when sent, on a `⬆️` line) and `maxBodyLength` (`null` to disable truncation).

## 1.3.0
- `authorityGetter` is now optional: the authority can be passed per call instead. A `StateError` is thrown when a request is built with neither.
- `sendMultipartRequest` now accepts a per-call `authority`, like `send`.

## 1.2.0
- `LoggingInterceptor` now also logs exceptions thrown down the chain instead of a response (no internet, timeout, DNS / connection failure, ...) on a `❌` line, then rethrows them unchanged.
- Fixed `send<void>()` / `send<Null>()` / `send<Object?>()` throwing `UnimplementedError` (after the request was processed by the server) instead of resolving to `null`.
- Fixed the timeout not covering the request sending phase (only the body reading): a server that never sent its headers could block a request until the OS-level TCP timeout.
- Fixed a deadlock in `TokenRefreshInterceptor` when the refresh callback sends its request through the same client after an `await` (or behind an asynchronous interceptor): requests to `excludedPaths` no longer wait for the in-flight refresh.
- An empty success body is now treated like a JSON `null` for `JsonObject`/`JsonList`: `send<JsonObject?>()` resolves to `null`, `send<JsonObject>()` throws `NullResponseBodyException` (previously both threw a `FormatException`).

## 1.1.0
- Added `JsonHttpResponse` extension on `http.Response` (`isJson`, `decodeJson<T>()`, `tryDecodeJson<T>()`) so JSON response helpers can be used on any `http.Response`, not just those produced by `SleekHttpClient`.

## 1.0.0
- **BREAKING** Replaced `HttpRetryPolicy` / `HttpRetryPolicyBuilder` / `TokenRefreshHandler` and `HttpClientLogConfig` (`logConfig`) with a single composable `HttpInterceptor` chain (`SleekHttpClient.interceptors`), including `TokenRefreshInterceptor` and `LoggingInterceptor`.
- **BREAKING** `send<T>`/`sendMultipartRequest<T>` now return `T` instead of `T?`. `T`'s own nullability drives behavior for `JsonObject`/`JsonList`: `send<JsonObject>()` requires a non-null body and throws the new `NullResponseBodyException` if the server returns JSON `null`, while `send<JsonObject?>()` returns `null` in that case. A malformed body or unexpected JSON shape always throws (`FormatException`/`TypeError`), regardless of nullability — it is no longer silently swallowed to `null`.

## 0.1.0
- Initial release
