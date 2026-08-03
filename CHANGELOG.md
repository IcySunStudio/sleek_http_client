# Changelog

## 1.0.0

### Breaking changes
- Replaced `HttpRetryPolicy` / `HttpRetryPolicyBuilder` / `TokenRefreshHandler` (`retry_handlers.dart`) and `HttpClientLogConfig` (`logConfig`) with a single composable interceptor chain.
- `SleekHttpClient.retryPolicy` and `SleekHttpClient.logConfig` constructor params are removed. Use `SleekHttpClient.interceptors` instead.
- Added `HttpInterceptor` / `HttpInterceptorChain` (`interceptor.dart`): a chain-of-responsibility mechanism (à la OkHttp/Dio) operating on raw `http.BaseRequest` → `http.Response`. Interceptors can mutate the request, short-circuit the network call entirely (e.g. a cache hit), or inspect/retry the response.
- `TokenRefreshHandler` becomes `TokenRefreshInterceptor` (`token_refresh_interceptor.dart`), implementing `HttpInterceptor`. Same JWT/OAuth de-duplicated refresh + 401 retry behavior, now expressed as `chain.proceed` calls instead of dedicated `beforeSend`/`shouldRetry`/`onBeforeRetry` hooks.
- `HttpClientLogConfig` becomes `LoggingInterceptor` (`logging_interceptor.dart`), a ship-in-the-box `HttpInterceptor`. Place it last in `interceptors` (closest to the network) to only log real network calls.

### Migration
```dart
// Before
SleekHttpClient(
  retryPolicy: TokenRefreshHandler(refresh, excludedPaths: [...]),
  logConfig: HttpClientLogConfig(logger: print),
);

// After
SleekHttpClient(
  interceptors: [
    TokenRefreshInterceptor(refresh, excludedPaths: [...]),
    LoggingInterceptor(logger: print),
  ],
);
```

- A disk-cache interceptor (e.g. backed by `flutter_cache_manager`) is intentionally **not** included in the package to keep it dependency-free; see `example/main.dart` for a minimal in-memory `HttpInterceptor` illustrating the short-circuit pattern.

## 0.1.0
- Initial release
