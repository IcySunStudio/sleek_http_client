import 'package:http/http.dart' as http;

import '../sleek_http_client.dart' show CopyableBaseRequest;
import 'interceptor.dart';

// =============================================================================
// TokenRefreshInterceptor — JWT / OAuth implementation
// =============================================================================

/// Handles JWT / OAuth token refresh with de-duplication, as an
/// [HttpInterceptor].
///
/// ```dart
/// SleekHttpClient(
///   authorizationHeaderGetter: () => tokenStorage.accessToken,
///   interceptors: [
///     TokenRefreshInterceptor(
///       () async {
///         final tokens = await authService.refresh();
///         tokenStorage.save(tokens);
///       },
///       excludedPaths: ['/auth/refresh', '/auth/login'],
///     ),
///   ],
/// );
/// ```
///
/// ## Pre-send pause
///
/// If a refresh is already in progress when [intercept] is called, the
/// request pauses until the refresh completes before being sent, so it picks
/// up the fresh token and avoids a wasted 401 round-trip. (The fresh token
/// itself is attached by [SleekHttpClient] right before every network call.)
/// Requests to [excludedPaths] never pause, so the refresh callback can call
/// the refresh endpoint through the same client without deadlocking.
///
/// ## 401 detection with loop prevention
///
/// After [chain]'s response comes back, a refresh + retry is triggered only
/// for 401 responses whose path is **not** in [excludedPaths]. Add every path
/// called inside the refresh callback (e.g. `/auth/refresh`) to prevent
/// infinite refresh loops.
///
/// ## De-duplicated refresh
///
/// Concurrent 401 failures share a single refresh call. Subsequent callers
/// wait for the in-flight refresh rather than triggering a second one.
class TokenRefreshInterceptor implements HttpInterceptor {
  TokenRefreshInterceptor(
    this._refresh, {
    required this.excludedPaths,
  });

  final Future<void> Function() _refresh;

  /// URL path substrings that are never retried on a 401.
  ///
  /// Typically includes the refresh-token endpoint and any other auth route
  /// called inside the refresh callback, to prevent infinite retry loops.
  /// Also include unauthenticated routes (e.g. `/auth/login`) to avoid
  /// unnecessary refresh attempts.
  final List<String> excludedPaths;

  Future<void>? _task;

  @override
  Future<http.Response> intercept(http.BaseRequest request, HttpInterceptorChain chain) async {
    // Excluded requests bypass this interceptor entirely, including the pre-send pause: the refresh request itself, sent from
    // within the refresh callback, would otherwise wait for the very refresh it is part of — a deadlock.
    final path = request.url.path;
    final isExcluded = excludedPaths.any((p) => path.contains(p));
    if (isExcluded) return chain.proceed(request);

    // Pause here if a refresh is already in progress, so this request is sent with the fresh token instead of a known-stale one.
    await (_task ?? Future.value());

    final response = await chain.proceed(request);

    if (response.statusCode != 401) return response;

    // De-duplicate concurrent refreshes.
    _task ??= _refresh().whenComplete(() => _task = null);
    await _task;

    // Retry once with a fresh copy of the request (the fresh auth header is attached by SleekHttpClient right before the network call).
    return chain.proceed(await request.copyAsNew());
  }
}


