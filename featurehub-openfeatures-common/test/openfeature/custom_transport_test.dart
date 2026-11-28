@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_openfeatures_common/featurehub_openfeatures_common.dart';
import 'package:test/test.dart';

/// A transport over a WebSocket, as the README describes: the server sends
/// FeatureHub's events as `{"event": ..., "data": ...}` messages, and is
/// sent the context (`{"context": {...}}`) when it changes.
class WebSocketTransport implements FeatureHubTransport {
  final FeatureHubTransportTarget target;
  WebSocket? _socket;

  WebSocketTransport(this.target);

  @override
  Future<void> start() async {
    final socket = await WebSocket.connect(
      target.featuresUrl!,
      headers: target.headers,
    );
    _socket = socket;
    socket.listen((message) {
      final json = jsonDecode(message as String) as Map<String, dynamic>;
      target.repository.notify(
        SSEResultStateExtension.fromJson(json['event']),
        json['data'],
      );
    }, onDone: () => target.repository.notify(SSEResultState.bye, null));
    _sendContext();
  }

  void _sendContext() =>
      _socket?.add(jsonEncode({'context': target.contextAttributes}));

  @override
  Future<void> contextChanged() async => _sendContext();

  @override
  Future<void> refreshIfStale() async {}

  @override
  Future<void> close() async => _socket?.close();
}

/// Sends the features for each context it is sent, with `who` the userkey.
class _Server {
  late HttpServer _server;
  final sockets = <WebSocket>[];
  final headers = <HttpHeaders>[];

  String get url => 'ws://127.0.0.1:${_server.port}/ws';

  static Map<String, Object?> who(String? userkey, {int version = 1}) =>
      FeatureState(
        id: 'who',
        key: 'who',
        version: version,
        type: FeatureValueType.STRING,
        value: userkey,
      ).toJson();

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      headers.add(request.headers);
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.listen((message) {
        final context =
            (jsonDecode(message as String) as Map)['context'] as Map;
        final userkey = (context['userkey'] as List?)?.single as String?;
        socket.add(
          jsonEncode({
            'event': 'features',
            'data': [who(userkey)],
          }),
        );
      });
    });
  }

  void push(Map<String, Object?> message) {
    for (final s in sockets) {
      s.add(jsonEncode(message));
    }
  }

  Future<void> stop() async {
    for (final s in sockets) {
      await s.close();
    }
    await _server.close(force: true);
  }
}

void main() {
  late _Server server;
  setUp(() async {
    server = _Server();
    await server.start();
  });
  tearDown(() => server.stop());

  test('a transport of your own fills the repository', () async {
    final connection = FeatureHubConnection(
      featuresUrl: server.url,
      headers: {'authorization': 'Bearer t'},
      transportFactory: WebSocketTransport.new,
    );
    expect(connection.clientEvaluated, false, reason: 'the context is sent');
    expect(connection.sourceDescription, contains('transport'));

    await connection.start(
      context: mapEvaluationContext({'targetingKey': 'fred'}),
    );
    expect(
      await connection.waitForReady(const Duration(seconds: 5)),
      Readyness.Ready,
    );
    expect(connection.repository.evaluate('who').value, 'fred');
    expect(server.headers.single.value('authorization'), 'Bearer t');

    // a context change waits for the features for it
    expect(
      await connection.setContext(
        mapEvaluationContext({'targetingKey': 'mary'}),
        const Duration(seconds: 5),
      ),
      Readyness.Ready,
    );
    expect(connection.repository.evaluate('who').value, 'mary');

    // updates pushed by the server
    server.push({'event': 'feature', 'data': _Server.who('june', version: 2)});
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(connection.repository.evaluate('who').value, 'june');

    // a lost connection is a bye: the repository stays ready, and keeps
    // resolving from the last features
    for (final s in server.sockets) {
      await s.close();
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(connection.repository.readyness, Readyness.Ready);
    expect(connection.repository.evaluate('who').value, 'june');

    await connection.close();
    connection.repository.shutdown();
  });
}
