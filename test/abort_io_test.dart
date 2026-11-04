import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:sleek_http_client/sleek_http_client.dart';
import 'package:test/test.dart';

/// Same scenarios as `abort_test.dart`, but against the real [IOClient] and a
/// raw local socket, to check that aborting really closes the connection.
void main() {
  group('abort with a real IOClient', () {
    late ServerSocket server;
    late StreamController<_Connection> connections;
    late SleekHttpClient client;

    setUp(() async {
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      connections = StreamController<_Connection>.broadcast();
      server.listen((socket) => connections.add(_Connection(socket)));
      client = _client(server, timeOutDuration: const Duration(seconds: 30));
    });

    tearDown(() async {
      client.abortAll();
      await server.close();
    });

    test('abortAll aborts a request the server never answers, and closes the connection', () async {
      final connection = connections.stream.first;

      final expectation = expectLater(client.send<String>(HttpMethod.get, '/x'), throwsA(isA<RequestAbortedException>()));
      final serverSide = await connection;
      await serverSide.requestReceived;
      client.abortAll();

      await expectation;
      expect(await serverSide.closedWithin(const Duration(seconds: 2)), isTrue);
    });

    test('abortAll aborts a request whose body is being received', () async {
      final connection = connections.stream.first;

      final expectation = expectLater(client.send<String>(HttpMethod.get, '/x'), throwsA(isA<RequestAbortedException>()));
      final serverSide = await connection;
      await serverSide.requestReceived;
      // Headers and a first chunk go out, the rest of the body never comes.
      serverSide.socket.write('HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n7\r\npartial\r\n');
      await serverSide.socket.flush();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      client.abortAll();

      await expectation;
      expect(await serverSide.closedWithin(const Duration(seconds: 2)), isTrue);
    });

    test('a timeout closes the connection and still throws a timeout ConnectivityException', () async {
      client = _client(server, timeOutDuration: const Duration(milliseconds: 200));
      final connection = connections.stream.first;

      await expectLater(
        client.send<String>(HttpMethod.get, '/x'),
        throwsA(isA<ConnectivityException>().having((e) => e.type, 'type', ConnectivityExceptionType.timeout)),
      );

      expect(await (await connection).closedWithin(const Duration(seconds: 2)), isTrue);
    });
  });
}

/// The test server only speaks plain HTTP while [SleekHttpClient] builds `https` URLs: the scheme is rewritten on the way to [IOClient].
SleekHttpClient _client(ServerSocket server, {required Duration timeOutDuration}) => SleekHttpClient(
  client: _PlainHttpClient(),
  authorityGetter: () => 'localhost:${server.port}',
  timeOutDuration: timeOutDuration,
);

/// The server side of one connection: tells when the request arrived and when the client hung up.
class _Connection {
  _Connection(this.socket) {
    socket.listen(
      (_) {
        if (!_requestReceived.isCompleted) _requestReceived.complete();
      },
      onDone: _closed.complete,
      onError: (Object _) => _closed.complete(),
      cancelOnError: true,
    );
  }

  final Socket socket;
  final _requestReceived = Completer<void>();
  final _closed = Completer<void>();

  Future<void> get requestReceived => _requestReceived.future;

  Future<bool> closedWithin(Duration timeout) =>
      _closed.future.then((_) => true).timeout(timeout, onTimeout: () => false);
}

class _PlainHttpClient extends http.BaseClient {
  final _inner = IOClient();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final plain = _AbortableHttpRequest(
      request.method,
      request.url.replace(scheme: 'http'),
      request is http.Abortable ? request.abortTrigger : null,
    )..headers.addAll(request.headers);
    return _inner.send(plain);
  }

  @override
  void close() => _inner.close();
}

class _AbortableHttpRequest extends http.Request implements http.Abortable {
  _AbortableHttpRequest(super.method, super.url, this.abortTrigger);

  @override
  final Future<void>? abortTrigger;
}
