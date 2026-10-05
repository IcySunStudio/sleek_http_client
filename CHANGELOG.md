# Changelog

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
