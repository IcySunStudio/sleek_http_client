import 'package:http/http.dart' as http;

/// A single link in the interceptor chain.
///
/// Implementations can:
/// - Mutate [request] before calling `chain.proceed(request)`.
/// - Short-circuit entirely by returning a [http.Response] without calling `chain.proceed` (e.g. a cache hit).
/// - Inspect / retry after `chain.proceed` returns (e.g. token refresh).
/// - Wrap `chain.proceed` to observe both the outgoing request and the incoming response (e.g. logging).
///
/// Interceptors are passed to [SleekHttpClient] via the `interceptors` list.
/// The first interceptor in the list is the outermost (sees every retry /
/// short-circuit decision made by interceptors after it); the last one is the
/// innermost, closest to the actual network call.
abstract interface class HttpInterceptor {
  /// Handles [request], typically by delegating to `chain.proceed(request)` and returning (a possibly transformed) result.
  Future<http.Response> intercept(http.BaseRequest request, HttpInterceptorChain chain);
}

/// Represents the remainder of the interceptor chain, to be invoked by an [HttpInterceptor].
abstract interface class HttpInterceptorChain {
  /// Passes [request] to the next interceptor in the chain (or to the
  /// terminal network call if this is the last interceptor).
  Future<http.Response> proceed(http.BaseRequest request);
}

/// Builds and runs an [HttpInterceptor] chain terminated by [terminal].
///
/// [interceptors] index 0 is the outermost link; [terminal] is always the
/// innermost link (the actual network call).
Future<http.Response> runInterceptorChain(
  http.BaseRequest request,
  List<HttpInterceptor> interceptors,
  Future<http.Response> Function(http.BaseRequest request) terminal,
) {
  HttpInterceptorChain chain = _TerminalChain(terminal);

  for (final interceptor in interceptors.reversed) {
    chain = _InterceptorChainLink(interceptor, chain);
  }

  return chain.proceed(request);
}

class _InterceptorChainLink implements HttpInterceptorChain {
  const _InterceptorChainLink(this._interceptor, this._next);

  final HttpInterceptor _interceptor;
  final HttpInterceptorChain _next;

  @override
  Future<http.Response> proceed(http.BaseRequest request) => _interceptor.intercept(request, _next);
}

class _TerminalChain implements HttpInterceptorChain {
  const _TerminalChain(this._terminal);

  final Future<http.Response> Function(http.BaseRequest request) _terminal;

  @override
  Future<http.Response> proceed(http.BaseRequest request) => _terminal(request);
}

