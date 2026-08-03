import 'package:http/http.dart' as http;
import 'package:sleek_http_client/sleek_http_client.dart';
import 'package:test/test.dart';

void main() {
  group('runInterceptorChain', () {
    test('runs interceptors outermost-first and terminal last', () async {
      final callOrder = <String>[];

      final response = await runInterceptorChain(
        http.Request('GET', Uri.parse('https://example.com')),
        [
          _RecordingInterceptor('A', callOrder),
          _RecordingInterceptor('B', callOrder),
        ],
        (request) async {
          callOrder.add('terminal');
          return http.Response('ok', 200, request: request);
        },
      );

      expect(callOrder, ['A', 'B', 'terminal']);
      expect(response.body, 'ok');
    });

    test('an interceptor can short-circuit without calling proceed', () async {
      var terminalCalled = false;

      final response = await runInterceptorChain(
        http.Request('GET', Uri.parse('https://example.com')),
        [_ShortCircuitInterceptor()],
        (request) async {
          terminalCalled = true;
          return http.Response('network', 200, request: request);
        },
      );

      expect(terminalCalled, isFalse);
      expect(response.body, 'short-circuited');
    });

    test('an interceptor can mutate the request before proceeding', () async {
      http.BaseRequest? seenByTerminal;

      await runInterceptorChain(
        http.Request('GET', Uri.parse('https://example.com')),
        [_HeaderInjectingInterceptor()],
        (request) async {
          seenByTerminal = request;
          return http.Response('ok', 200, request: request);
        },
      );

      expect(seenByTerminal!.headers['x-injected'], 'true');
    });

    test('with no interceptors, only the terminal runs', () async {
      final response = await runInterceptorChain(
        http.Request('GET', Uri.parse('https://example.com')),
        [],
        (request) async => http.Response('direct', 200, request: request),
      );

      expect(response.body, 'direct');
    });
  });
}

class _RecordingInterceptor implements HttpInterceptor {
  _RecordingInterceptor(this.name, this.callOrder);

  final String name;
  final List<String> callOrder;

  @override
  Future<http.Response> intercept(http.BaseRequest request, HttpInterceptorChain chain) {
    callOrder.add(name);
    return chain.proceed(request);
  }
}

class _ShortCircuitInterceptor implements HttpInterceptor {
  @override
  Future<http.Response> intercept(http.BaseRequest request, HttpInterceptorChain chain) async {
    return http.Response('short-circuited', 200, request: request);
  }
}

class _HeaderInjectingInterceptor implements HttpInterceptor {
  @override
  Future<http.Response> intercept(http.BaseRequest request, HttpInterceptorChain chain) {
    request.headers['x-injected'] = 'true';
    return chain.proceed(request);
  }
}

