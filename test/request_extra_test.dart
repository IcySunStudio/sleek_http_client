import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sleek_http_client/sleek_http_client.dart';
import 'package:test/test.dart';

void main() {
  group('RequestExtra', () {
    test('is empty by default and is stable across accesses', () {
      final request = http.Request('GET', Uri.parse('https://example.com'));

      expect(request.extra, isEmpty);
      request.extra['a'] = 1;
      expect(request.extra['a'], 1);
    });

    test('is independent between requests', () {
      final a = http.Request('GET', Uri.parse('https://example.com'));
      final b = http.Request('GET', Uri.parse('https://example.com'));

      a.extra['key'] = 'value';

      expect(b.extra, isEmpty);
    });

    test('send(extra:) is visible to interceptors and never sent as a header', () async {
      Object? seen;
      http.BaseRequest? sent;
      final client = SleekHttpClient(
        client: MockClient((request) async {
          sent = request;
          return http.Response('ok', 200);
        }),
        authorityGetter: () => 'api.example.com',
        interceptors: [_ExtraReaderInterceptor('policy', (value) => seen = value)],
      );

      await client.send<String>(HttpMethod.get, '/x', extra: {'policy': 'noCache'});

      expect(seen, 'noCache');
      expect(sent!.headers.keys, isNot(contains('policy')));
      expect(sent!.headers.values, isNot(contains('noCache')));
    });

    test('an interceptor can report info back to the caller through a mutable object', () async {
      final info = _CacheInfo();
      final client = SleekHttpClient(
        client: MockClient((request) async => http.Response('ok', 200)),
        authorityGetter: () => 'api.example.com',
        interceptors: [_CacheInfoFillingInterceptor()],
      );

      await client.send<String>(HttpMethod.get, '/x', extra: {'cacheInfo': info});

      expect(info.fromCache, isTrue);
    });

    test('copyAsNew copies the extra of an http.Request', () async {
      final request = http.Request('GET', Uri.parse('https://example.com'))..extra['key'] = 'value';

      final copy = await request.copyAsNew();

      expect(copy.extra['key'], 'value');
      expect(identical(copy.extra, request.extra), isFalse);
    });

    test('TokenRefreshInterceptor keeps the extra on the retried request', () async {
      final seenOnAttempts = <Object?>[];
      var attempt = 0;
      final client = SleekHttpClient(
        client: MockClient((request) async {
          attempt++;
          return attempt == 1 ? http.Response('unauthorized', 401) : http.Response('ok', 200);
        }),
        authorityGetter: () => 'api.example.com',
        interceptors: [
          TokenRefreshInterceptor(() async {}, excludedPaths: []),
          _ExtraReaderInterceptor('key', seenOnAttempts.add),
        ],
      );

      await client.send<String>(HttpMethod.get, '/x', extra: {'key': 'value'});

      expect(seenOnAttempts, ['value', 'value']);
    });

    test('sendMultipartRequest(extra:) survives a retry', () async {
      final dir = await Directory.systemTemp.createTemp('sleek_extra_test');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}${Platform.pathSeparator}f.txt')..writeAsStringSync('hello');

      final seenOnAttempts = <Object?>[];
      var attempt = 0;
      final client = SleekHttpClient(
        client: MockClient((request) async {
          attempt++;
          return attempt == 1 ? http.Response('unauthorized', 401) : http.Response('ok', 200);
        }),
        authorityGetter: () => 'api.example.com',
        interceptors: [
          TokenRefreshInterceptor(() async {}, excludedPaths: []),
          _ExtraReaderInterceptor('key', seenOnAttempts.add),
        ],
      );

      await client.sendMultipartRequest<String>(
        '/upload',
        files: [MultipartRequestFileData(fieldName: 'file', path: file.path)],
        extra: {'key': 'value'},
      );

      expect(seenOnAttempts, ['value', 'value']);
    });
  });
}

class _CacheInfo {
  bool fromCache = false;
}

class _ExtraReaderInterceptor implements HttpInterceptor {
  _ExtraReaderInterceptor(this.key, this.onRead);

  final String key;
  final void Function(Object? value) onRead;

  @override
  Future<http.Response> intercept(http.BaseRequest request, HttpInterceptorChain chain) {
    onRead(request.extra[key]);
    return chain.proceed(request);
  }
}

class _CacheInfoFillingInterceptor implements HttpInterceptor {
  @override
  Future<http.Response> intercept(http.BaseRequest request, HttpInterceptorChain chain) {
    (request.extra['cacheInfo'] as _CacheInfo).fromCache = true;
    return chain.proceed(request);
  }
}
