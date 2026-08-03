# Changelog

## 1.0.0
- **BREAKING** Replaced `HttpRetryPolicy` / `HttpRetryPolicyBuilder` / `TokenRefreshHandler` and `HttpClientLogConfig` (`logConfig`) with a single composable `HttpInterceptor` chain (`SleekHttpClient.interceptors`), including `TokenRefreshInterceptor` and `LoggingInterceptor`.

## 0.1.0
- Initial release
