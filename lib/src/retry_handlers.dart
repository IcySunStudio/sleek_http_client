import 'exceptions.dart';

// =============================================================================
// HttpRetryPolicy — abstract interface
// =============================================================================

/// Contract for plugging retry logic into [SleekHttpClient].
///
/// Implement this interface directly for full control, use
/// [HttpRetryPolicyBuilder] for a lightweight callback-based setup, or use
/// [TokenRefreshHandler] for the standard JWT / OAuth token-refresh pattern.
abstract interface class HttpRetryPolicy {
  /// Called before every request is dispatched.
  ///
  /// Return a [Future] that completes when it is safe to send the request.
  /// Use this to pause requests while a token refresh is in progress so they
  /// are never sent with a known-stale token.
  ///
  /// Return `Future.value()` (or any already-completed future) to let the
  /// request proceed immediately.
  Future<void> beforeSend();

  /// Called after a failed request to decide whether to retry it.
  ///
  /// Return `true` to invoke [onBeforeRetry] and resend the request once.
  /// Return `false` to surface the error to the caller as-is.
  Future<bool> shouldRetry(HttpResponseException exception);

  /// Called before the request is retried, after [shouldRetry] returned `true`.
  ///
  /// Perform any side-effect needed before the retry (e.g. token refresh,
  /// back-off delay). Throw to abort the retry and surface the error.
  Future<void> onBeforeRetry(HttpResponseException exception);
}

// =============================================================================
// HttpRetryPolicyBuilder — callback-based concrete implementation
// =============================================================================

/// A callback-based [HttpRetryPolicy] for one-off or partial customisations.
///
/// Each hook is optional and falls back to a safe no-op default:
/// - [beforeSend] defaults to returning immediately.
/// - [shouldRetry] defaults to always returning `false` (no retry).
/// - [onBeforeRetry] defaults to a no-op.
///
/// Example — custom 429 back-off without token refresh:
/// ```dart
/// SleekHttpClient(
///   retryPolicy: HttpRetryPolicyBuilder(
///     shouldRetry: (e) async => e.statusCode == 429,
///     onBeforeRetry: (e) async => await Future.delayed(Duration(seconds: 2)),
///   ),
/// );
/// ```
class HttpRetryPolicyBuilder implements HttpRetryPolicy {
  const HttpRetryPolicyBuilder({
    Future<void> Function()? beforeSend,
    Future<bool> Function(HttpResponseException)? shouldRetry,
    Future<void> Function(HttpResponseException)? onBeforeRetry,
  })  : _beforeSend = beforeSend,
        _shouldRetry = shouldRetry,
        _onBeforeRetry = onBeforeRetry;

  final Future<void> Function()? _beforeSend;
  final Future<bool> Function(HttpResponseException)? _shouldRetry;
  final Future<void> Function(HttpResponseException)? _onBeforeRetry;

  @override
  Future<void> beforeSend() => _beforeSend?.call() ?? Future.value();

  @override
  Future<bool> shouldRetry(HttpResponseException exception) => _shouldRetry?.call(exception) ?? Future.value(false);

  @override
  Future<void> onBeforeRetry(HttpResponseException exception) => _onBeforeRetry?.call(exception) ?? Future.value();
}

// =============================================================================
// TokenRefreshHandler — JWT / OAuth implementation
// =============================================================================

/// Handles JWT / OAuth token refresh with de-duplication.
///
/// Implements [HttpRetryPolicy] and is intended to be passed directly to
/// [SleekHttpClient.retryPolicy]:
///
/// ```dart
/// final tokenHandler = TokenRefreshHandler(
///   () async {
///     final tokens = await authService.refresh();
///     tokenStorage.save(tokens);
///   },
///   excludedPaths: ['/auth/refresh', '/auth/login'],
/// );
///
/// SleekHttpClient(
///   authorizationHeaderGetter: () => tokenStorage.accessToken,
///   retryPolicy: tokenHandler,
/// );
/// ```
///
/// ## beforeSend — pre-send pause
///
/// [beforeSend] returns the in-flight refresh [Future] if one is running, so
/// any request started during a refresh will pause until the refresh completes
/// and pick up the fresh token — avoiding a wasted 401 round-trip.
///
/// ## shouldRetry — 401 detection with loop prevention
///
/// Returns `true` only for 401 responses whose path is **not** in
/// [excludedPaths]. Add every path called inside the refresh callback
/// (e.g. `/auth/refresh`) to prevent infinite refresh loops.
///
/// ## onBeforeRetry — de-duplicated refresh
///
/// Concurrent 401 failures share a single refresh call. Subsequent callers
/// wait for the in-flight refresh rather than triggering a second one.
class TokenRefreshHandler implements HttpRetryPolicy {
  TokenRefreshHandler(
    this._refresh, {
    required this.excludedPaths,
  });

  final Future<void> Function() _refresh;

  /// URL path substrings that are never retried on a 401.
  ///
  /// Typically includes the refresh-token endpoint and any other auth route
  /// called inside [onBeforeRetry], to prevent infinite retry loops.
  /// Also include unauthenticated routes (e.g. `/auth/login`) to avoid
  /// unnecessary refresh attempts.
  final List<String> excludedPaths;

  Future<void>? _task;

  @override
  Future<void> beforeSend() => _task ?? Future.value();

  @override
  Future<bool> shouldRetry(HttpResponseException exception) {
    if (exception.statusCode != 401) return Future.value(false);

    final path = exception.response.request?.url.path ?? '';
    final isExcluded = excludedPaths.any((p) => path.contains(p));
    return Future.value(!isExcluded);
  }

  @override
  Future<void> onBeforeRetry(HttpResponseException exception) {
    _task ??= _refresh().whenComplete(() => _task = null);
    return _task!;
  }
}
