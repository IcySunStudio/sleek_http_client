import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sleek_http_client/sleek_http_client.dart';
import 'package:test/test.dart';

void main() {
  group('abort', () {
    test('abortAll aborts every request in flight', () async {
      final client = _client(_hangingMockClient());

      final a = expectLater(client.send<String>(HttpMethod.get, '/a'), throwsA(isA<RequestAbortedException>()));
      final b = expectLater(client.send<String>(HttpMethod.get, '/b'), throwsA(isA<RequestAbortedException>()));
      await Future<void>.delayed(Duration.zero);
      client.abortAll();

      await Future.wait([a, b]);
    });

    test('abortAll does not affect requests sent afterwards', () async {
      final client = _client(MockClient((request) async => http.Response('ok', 200)));

      client.abortAll();

      expect(await client.send<String>(HttpMethod.get, '/x'), 'ok');
    });

    test('abortAll aborts a multipart request, including during the file reading', () async {
      final dir = await Directory.systemTemp.createTemp('sleek_abort_test');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}${Platform.pathSeparator}f.txt')..writeAsStringSync('hello');
      final client = _client(_hangingMockClient());

      final future = client.sendMultipartRequest<String>(
        '/upload',
        files: [MultipartRequestFileData(fieldName: 'file', path: file.path)],
      );
      final expectation = expectLater(future, throwsA(isA<RequestAbortedException>()));
      client.abortAll();

      await expectation;
    });

    test('a retry after a 401 stays aborted', () async {
      var attempt = 0;
      late final SleekHttpClient client;
      client = _client(
        MockClient.streaming((request, body) async {
          attempt++;
          if (attempt == 1) {
            return http.StreamedResponse(Stream.value(const []), 401);
          }
          return _awaitAbort(request);
        }),
        // The abort happens during the refresh, before the retry is sent.
        interceptors: [
          TokenRefreshInterceptor(() async => client.abortAll(), excludedPaths: []),
        ],
      );

      await expectLater(
        client.send<String>(HttpMethod.get, '/x'),
        throwsA(isA<RequestAbortedException>()),
      );
      expect(attempt, 2);
    });

    test('a timeout aborts the underlying request and still throws a timeout ConnectivityException', () async {
      http.BaseRequest? sent;
      final client = _client(
        MockClient.streaming((request, body) {
          sent = request;
          return _awaitAbort(request);
        }),
        timeOutDuration: const Duration(milliseconds: 50),
      );

      await expectLater(
        client.send<String>(HttpMethod.get, '/x'),
        throwsA(isA<ConnectivityException>().having((e) => e.type, 'type', ConnectivityExceptionType.timeout)),
      );

      // The request handed to the underlying client was told to abort.
      var aborted = false;
      unawaited((sent! as http.Abortable).abortTrigger!.then((_) => aborted = true));
      await Future<void>.delayed(Duration.zero);
      expect(aborted, isTrue);
    });

    test('a request retried after a timeout is not aborted by the previous attempt', () async {
      var attempt = 0;
      final client = _client(
        MockClient.streaming((request, body) {
          attempt++;
          if (attempt == 1) return _awaitAbort(request);
          return Future.value(http.StreamedResponse(Stream.value('ok'.codeUnits), 200));
        }),
        timeOutDuration: const Duration(milliseconds: 50),
        interceptors: [_RetryOnTimeoutInterceptor()],
      );

      expect(await client.send<String>(HttpMethod.get, '/x'), 'ok');
      expect(attempt, 2);
    });

    test('LoggingInterceptor logs an aborted call on a dedicated line, not as an error', () async {
      final logs = <String>[];
      final client = _client(
        _hangingMockClient(),
        interceptors: [LoggingInterceptor(logger: logs.add)],
      );

      final expectation = expectLater(client.send<String>(HttpMethod.get, '/x'), throwsA(isA<RequestAbortedException>()));
      await Future<void>.delayed(Duration.zero);
      client.abortAll();
      await expectation;

      expect(logs, hasLength(1));
      expect(logs.single, allOf(contains('🚫'), contains('GET /x'), contains('aborted'), isNot(contains('❌'))));
    });

    test('copyAsNew keeps the abort signal', () async {
      http.BaseRequest? copy;
      final client = _client(
        _hangingMockClient(),
        interceptors: [_CopyingInterceptor((request) => copy = request)],
      );

      final expectation = expectLater(client.send<String>(HttpMethod.get, '/x'), throwsA(isA<RequestAbortedException>()));
      await Future<void>.delayed(Duration.zero);
      client.abortAll();
      await expectation;

      // The copy made during the call is aborted along with the original.
      await expectLater((copy! as http.Abortable).abortTrigger!, completes);
    });
  });
}

SleekHttpClient _client(
  http.Client inner, {
  Duration timeOutDuration = const Duration(seconds: 30),
  List<HttpInterceptor> interceptors = const [],
}) => SleekHttpClient(
  client: inner,
  authorityGetter: () => 'api.example.com',
  timeOutDuration: timeOutDuration,
  interceptors: interceptors,
);

/// A client that never answers, but honors [http.Abortable] like `IOClient` does.
MockClient _hangingMockClient() => MockClient.streaming((request, body) => _awaitAbort(request));

Future<http.StreamedResponse> _awaitAbort(http.BaseRequest request) {
  final completer = Completer<http.StreamedResponse>();
  if (request case http.Abortable(:final abortTrigger?)) {
    unawaited(abortTrigger.whenComplete(() => completer.completeError(http.RequestAbortedException(request.url))));
  }
  return completer.future;
}

class _RetryOnTimeoutInterceptor implements HttpInterceptor {
  @override
  Future<http.Response> intercept(http.BaseRequest request, HttpInterceptorChain chain) async {
    try {
      return await chain.proceed(request);
    } on ConnectivityException {
      return chain.proceed(await request.copyAsNew());
    }
  }
}

/// Hands a copy of the request to [onCopy], then proceeds with the original.
class _CopyingInterceptor implements HttpInterceptor {
  _CopyingInterceptor(this.onCopy);

  final void Function(http.BaseRequest copy) onCopy;

  @override
  Future<http.Response> intercept(http.BaseRequest request, HttpInterceptorChain chain) async {
    onCopy(await request.copyAsNew());
    return chain.proceed(request);
  }
}
