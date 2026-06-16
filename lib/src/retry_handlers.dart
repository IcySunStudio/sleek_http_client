import 'exceptions.dart';

/// Handles JWT / OAuth token refresh with de-duplication.
///
/// Provides [shouldRetry] and [onBeforeRetry] callbacks suitable for use with
/// [SleekHttpClient]. Any number of concurrent 401 failures will share a single
/// refresh task — subsequent callers wait for the in-flight refresh to complete
/// rather than triggering a second one.
///
/// ## Infinite loop prevention
///
/// If [onBeforeRetry] itself calls the same [SleekHttpClient] (e.g. to hit a
/// `/auth/refresh` endpoint), a 401 on *that* request would trigger
/// [shouldRetry] again — causing an infinite refresh loop.
///
/// Pass every auth-related path in [excludedPaths] to prevent this.
/// [shouldRetry] will return `false` for any request whose URL contains one of
/// those substrings, so those requests are never retried.
///
/// ## Example
///
/// ```dart
/// final tokenHandler = TokenRefreshHandler(
///   myRefreshLogic,
///   excludedPaths: ['/auth/refresh', '/auth/login'],
/// );
///
/// SleekHttpClient(
///   shouldRetry: tokenHandler.shouldRetry,
///   onBeforeRetry: tokenHandler.onBeforeRetry,
/// );
/// ```
class TokenRefreshHandler {
  TokenRefreshHandler(
    this._refresh, {
    required this.excludedPaths,
  });

  final Future<void> Function() _refresh;

  /// URL path substrings that are never retried on a 401.
  ///
  /// Typically includes the refresh-token endpoint and any other auth routes
  /// that are called inside [onBeforeRetry], to prevent infinite retry loops.
  /// May also includes routes that does not require authentication, to avoid unnecessary refreshes (like login).
  final List<String> excludedPaths;

  Future<void>? _task;

  /// Returns `true` when [exception] carries a 401 Unauthorized status code
  /// AND the request URL does not match any of [excludedPaths].
  Future<bool> shouldRetry(HttpResponseException exception) {
    if (exception.statusCode != 401) return Future.value(false);

    final path = exception.response.request?.url.path ?? '';
    final isExcluded = excludedPaths.any((excluded) => path.contains(excluded));
    return Future.value(!isExcluded);
  }

  /// Executes the token refresh before the request is retried.
  ///
  /// Concurrent calls are de-duplicated: if a refresh is already in progress,
  /// this returns the same [Future] rather than starting a second one.
  ///
  /// If the refresh throws, the exception propagates to the original caller.
  Future<void> onBeforeRetry(HttpResponseException exception) {
    _task ??= _refresh().whenComplete(() => _task = null);
    return _task!;
  }
}
