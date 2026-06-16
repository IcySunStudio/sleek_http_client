import 'exceptions.dart';

/// Handles JWT / OAuth token refresh with de-duplication.
///
/// Provides [shouldRetry] and [onBeforeRetry] callbacks suitable for use with
/// [SleekHttpClient]. Any number of concurrent 401 failures will share a single
/// refresh task — subsequent callers wait for the in-flight refresh to complete
/// rather than triggering a second one.
///
/// Example:
/// ```dart
/// final tokenHandler = TokenRefreshHandler(myRefreshLogic);
///
/// SleekHttpClient(
///   shouldRetry: tokenHandler.shouldRetry,
///   onBeforeRetry: tokenHandler.onBeforeRetry,
/// );
/// ```
class TokenRefreshHandler {
  TokenRefreshHandler(this._refresh);

  final Future<void> Function() _refresh;
  Future<void>? _task;

  /// Returns `true` when [exception] carries a 401 Unauthorized status code.
  Future<bool> shouldRetry(HttpResponseException exception) => Future.value(exception.statusCode == 401);

  /// Executes the token refresh before the request is retried.
  ///
  /// Concurrent calls are de-duplicated: if a refresh is already in progress,
  /// this returns the same [Future] rather than starting a second refresh.
  Future<void> onBeforeRetry(HttpResponseException exception) {
    _task ??= _refresh().whenComplete(() => _task = null);
    return _task!;
  }
}
