# Changelog

## 1.0.0
- **BREAKING** Replaced `HttpRetryPolicy` / `HttpRetryPolicyBuilder` / `TokenRefreshHandler` and `HttpClientLogConfig` (`logConfig`) with a single composable `HttpInterceptor` chain (`SleekHttpClient.interceptors`), including `TokenRefreshInterceptor` and `LoggingInterceptor`.
- **BREAKING** `send<T>`/`sendMultipartRequest<T>` now return `T` instead of `T?`. `T`'s own nullability drives behavior for `JsonObject`/`JsonList`: `send<JsonObject>()` requires a non-null body and throws the new `NullResponseBodyException` if the server returns JSON `null`, while `send<JsonObject?>()` returns `null` in that case. A malformed body or unexpected JSON shape always throws (`FormatException`/`TypeError`), regardless of nullability — it is no longer silently swallowed to `null`.

## 0.1.0
- Initial release
