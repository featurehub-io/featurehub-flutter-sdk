@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_openfeatures_common/featurehub_openfeatures_common.dart';
import 'package:featurehub_sse_client/featurehub_sse_client.dart'
    show ReconnectPolicy;
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

/// A minimal FeatureHub Edge: GET /features/?apiKey=... (polling) and
/// `GET /features/<apiKey>` (SSE). The colour feature's value is the userkey
/// from the x-featurehub header (or query parameter), so server-side
/// evaluation is visible.
class _Edge {
  late HttpServer _server;
  final requests = <HttpRequest>[];
  int status = 200;

  /// The number of requests to leave unanswered.
  int hang = 0;

  /// Reply to polling requests gzip-compressed.
  bool gzipped = false;

  /// A Cache-Control header for polling responses.
  String? cacheControl;

  String get host => 'http://127.0.0.1:${_server.port}';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    // compression is done by hand when [gzipped]
    _server.autoCompress = false;
    _server.listen(_handle);
  }

  Future<void> stop() => _server.close(force: true);

  static String _colour(String? header) {
    final match = RegExp(r'userkey=([^,]*)').firstMatch(header ?? '');
    return match == null ? 'anonymous' : Uri.decodeQueryComponent(match[1]!);
  }

  List<Map<String, Object?>> _features(String? header) => [
    {
      'id': 'fv1',
      'key': 'colour',
      'version': 1,
      'type': 'STRING',
      'value': _colour(header),
      'l': false,
    },
  ];

  Future<void> _handle(HttpRequest request) async {
    requests.add(request);
    if (hang > 0) {
      hang--;
      return; // never respond
    }
    final header =
        request.headers.value('x-featurehub') ??
        request.uri.queryParameters['xfeaturehub'];
    final response = request.response;

    if (status != 200) {
      response.statusCode = status;
      await response.close();
      return;
    }

    if (request.uri.path == '/features/') {
      response.headers.contentType = ContentType.json;
      if (cacheControl != null) {
        response.headers.set(HttpHeaders.cacheControlHeader, cacheControl!);
      }
      final body = utf8.encode(
        jsonEncode([
          {'id': 'env', 'features': _features(header)},
        ]),
      );
      if (gzipped) {
        response.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
        response.add(gzip.encode(body));
      } else {
        response.add(body);
      }
      await response.close();
      return;
    }

    response.headers.contentType = ContentType('text', 'event-stream');
    response.bufferOutput = false;
    response.write(
      'event: features\ndata: ${jsonEncode(_features(header))}\n\n',
    );
    await response.flush();
  }
}

void main() {
  late _Edge edge;

  setUp(() async {
    edge = _Edge();
    await edge.start();
  });

  tearDown(() => edge.stop());

  for (final mode in [
    FeatureHubUpdateMode.streaming,
    FeatureHubUpdateMode.polling,
  ]) {
    group(mode.name, () {
      test('becomes ready with features', () async {
        final connection = FeatureHubConnection(
          host: edge.host,
          apiKey: 'a/b/c',
          mode: mode,
        );
        await connection.start();
        expect(
          await connection.waitForReady(const Duration(seconds: 5)),
          Readyness.Ready,
        );
        expect(connection.repository.evaluate('colour').value, 'anonymous');
        await connection.close();
      });

      test('sends the headers, with the HTTP client given', () async {
        var dioRequests = 0;
        final dio = Dio()
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                dioRequests++;
                handler.next(options);
              },
            ),
          );
        final httpClient = _CountingClient();
        final connection = FeatureHubConnection(
          host: edge.host,
          apiKey: 'a/b/c',
          mode: mode,
          headers: {'proxy-authorization': 'Basic abc', 'x-team': 'web'},
          dio: dio,
          httpClient: httpClient,
        );
        await connection.start(
          context: mapEvaluationContext({'targetingKey': 'fred'}),
        );
        await connection.waitForReady(const Duration(seconds: 5));
        await connection.close();

        final request = edge.requests.last;
        expect(request.headers.value('proxy-authorization'), 'Basic abc');
        expect(request.headers.value('x-team'), 'web');
        // the context header is still sent
        expect(request.headers.value('x-featurehub'), 'userkey=fred');
        if (mode == FeatureHubUpdateMode.streaming) {
          expect(httpClient.sent, greaterThan(0));
          expect(dioRequests, 0);
        } else {
          expect(dioRequests, greaterThan(0));
          expect(httpClient.sent, 0);
        }
      });

      test('a server-evaluated context is sent and refreshed', () async {
        final connection = FeatureHubConnection(
          host: edge.host,
          apiKey: 'a/b/c',
          mode: mode,
        );
        await connection.start(
          context: mapEvaluationContext({'targetingKey': 'fred'}),
        );
        await connection.waitForReady(const Duration(seconds: 5));
        expect(connection.repository.evaluate('colour').value, 'fred');

        final readiness = await connection.setContext(
          mapEvaluationContext({'targetingKey': 'mary'}),
          const Duration(seconds: 5),
        );
        expect(readiness, Readyness.Ready);
        expect(connection.repository.evaluate('colour').value, 'mary');

        // the same context again does not refetch
        final count = edge.requests.length;
        await connection.setContext(
          mapEvaluationContext({'targetingKey': 'mary'}),
          const Duration(seconds: 5),
        );
        expect(edge.requests.length, count);
        await connection.close();
      });

      test('a client-evaluated key never sends the context', () async {
        final connection = FeatureHubConnection(
          host: edge.host,
          apiKey: 'a/b/c*d',
          mode: mode,
        );
        expect(connection.clientEvaluated, true);
        await connection.start(
          context: mapEvaluationContext({'targetingKey': 'fred'}),
        );
        await connection.waitForReady(const Duration(seconds: 5));
        expect(connection.repository.evaluate('colour').value, 'anonymous');
        await connection.close();
      });
    });
  }

  group('request timeout', () {
    test('polling: an unanswered request times out', () async {
      edge.hang = 1;
      final connection = FeatureHubConnection(
        host: edge.host,
        apiKey: 'a/b/c',
        mode: FeatureHubUpdateMode.passive,
        pollInterval: Duration.zero,
        requestTimeout: const Duration(milliseconds: 200),
      );
      final started = DateTime.now();
      await connection.start();
      expect(
        DateTime.now().difference(started),
        lessThan(const Duration(seconds: 3)),
      );
      // a timeout is not a rejection of the key
      expect(connection.repository.readyness, Readyness.NotReady);

      // the next request is answered
      await connection.refreshIfStale();
      expect(connection.repository.readyness, Readyness.Ready);
      await connection.close();
    });

    test('streaming: an unanswered attempt is retried', () async {
      edge.hang = 1;
      final connection = FeatureHubConnection(
        host: edge.host,
        apiKey: 'a/b/c',
        requestTimeout: const Duration(milliseconds: 200),
        reconnectPolicy: const ReconnectPolicy(
          delay: Duration(milliseconds: 10),
        ),
      );
      await connection.start();
      expect(
        await connection.waitForReady(const Duration(seconds: 5)),
        Readyness.Ready,
      );
      expect(edge.requests, hasLength(2));
      await connection.close();
    });

    test('a connect timeout can be set', () async {
      // a closed local port refuses at once; checks the option is wired
      // through to working polling and streaming clients
      for (final mode in [
        FeatureHubUpdateMode.polling,
        FeatureHubUpdateMode.streaming,
      ]) {
        final connection = FeatureHubConnection(
          host: 'http://127.0.0.1:1',
          apiKey: 'a/b/c',
          mode: mode,
          connectTimeout: const Duration(seconds: 2),
          reconnectPolicy: ReconnectPolicy.none,
        );
        await connection.start();
        expect(
          await connection.waitForReady(const Duration(milliseconds: 500)),
          isNot(Readyness.Ready),
        );
        await connection.close();
      }
    });
  });

  test('polling requests at every interval', () async {
    final connection = FeatureHubConnection(
      host: edge.host,
      apiKey: 'a/b/c',
      mode: FeatureHubUpdateMode.polling,
      pollInterval: const Duration(seconds: 1),
    );
    await connection.start();
    await Future<void>.delayed(const Duration(milliseconds: 3500));
    await connection.close();
    // the first request, and one at each of the three intervals since
    expect(edge.requests, hasLength(4));
  });

  test('a Cache-Control max-age replaces the poll interval', () async {
    edge.cacheControl = 'private, max-age=1';
    final connection = FeatureHubConnection(
      host: edge.host,
      apiKey: 'a/b/c',
      mode: FeatureHubUpdateMode.polling,
      pollInterval: const Duration(seconds: 30),
    );
    await connection.start();
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    await connection.close();
    // the first request, then one a second (not after 30 seconds)
    expect(edge.requests, hasLength(3));
  });

  test('a longer Cache-Control max-age slows polling down', () async {
    edge.cacheControl = 'max-age=3';
    final connection = FeatureHubConnection(
      host: edge.host,
      apiKey: 'a/b/c',
      mode: FeatureHubUpdateMode.polling,
      pollInterval: const Duration(seconds: 1),
    );
    await connection.start();
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    await connection.close();
    expect(edge.requests, hasLength(1));
  });

  test('polling accepts gzip-compressed responses', () async {
    edge.gzipped = true;
    final connection = FeatureHubConnection(
      host: edge.host,
      apiKey: 'a/b/c',
      mode: FeatureHubUpdateMode.polling,
    );
    await connection.start();
    expect(
      await connection.waitForReady(const Duration(seconds: 5)),
      Readyness.Ready,
    );
    expect(connection.repository.evaluate('colour').value, 'anonymous');
    expect(
      edge.requests.single.headers.value(HttpHeaders.acceptEncodingHeader),
      contains('gzip'),
    );
    await connection.close();
  });

  test('polling does not wait when a store has made it ready', () async {
    edge.hang = 1;
    final repository = ClientFeatureRepository()
      ..notify(SSEResultState.features, [
        FeatureState(
          id: 'fv1',
          key: 'colour',
          version: 1,
          type: FeatureValueType.STRING,
          value: 'stored',
        ),
      ], source: 'a-store');
    final connection = FeatureHubConnection(
      host: edge.host,
      apiKey: 'a/b/c',
      repository: repository,
      mode: FeatureHubUpdateMode.polling,
    );
    await connection.start().timeout(const Duration(seconds: 2));
    expect(repository.evaluate('colour').value, 'stored');
    await connection.close();
  });

  group('a rejected key (4xx)', () {
    test('stops polling', () async {
      edge.status = 401;
      final connection = FeatureHubConnection(
        host: edge.host,
        apiKey: 'a/b/c',
        mode: FeatureHubUpdateMode.polling,
        pollInterval: const Duration(milliseconds: 50),
      );
      await connection.start();
      expect(connection.repository.readyness, Readyness.Failed);

      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(edge.requests, hasLength(1), reason: 'no further polls');
      await connection.close();
    });

    test('stops passive refreshes and context changes', () async {
      edge.status = 404;
      final connection = FeatureHubConnection(
        host: edge.host,
        apiKey: 'a/b/c',
        mode: FeatureHubUpdateMode.passive,
        pollInterval: Duration.zero,
      );
      await connection.start();
      expect(connection.repository.readyness, Readyness.Failed);

      await connection.refreshIfStale();
      await connection.setContext(
        mapEvaluationContext({'targetingKey': 'fred'}),
        const Duration(milliseconds: 200),
      );
      expect(edge.requests, hasLength(1));
      await connection.close();
    });

    test('a 5xx keeps polling', () async {
      edge.status = 503;
      final connection = FeatureHubConnection(
        host: edge.host,
        apiKey: 'a/b/c',
        mode: FeatureHubUpdateMode.polling,
        pollInterval: const Duration(milliseconds: 50),
      );
      await connection.start();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(edge.requests.length, greaterThan(2));
      expect(connection.repository.readyness, Readyness.NotReady);
      await connection.close();
    });

    test('FeatureHubConfig marks the repository failed and stops', () async {
      edge.status = 403;
      final repo = ClientFeatureRepository();
      final config = FeatureHubConfig(edge.host, ['a/b/c'], repo);

      await config.request(); // does not throw
      expect(repo.readyness, Readyness.Failed);
      expect(config.isConnectionDead, true);

      await config.request(force: true);
      expect(edge.requests, hasLength(1));
    });

    test('FeatureHubConfig still throws for other errors', () async {
      edge.status = 500;
      final repo = ClientFeatureRepository();
      final config = FeatureHubConfig(edge.host, ['a/b/c'], repo);

      await expectLater(config.request(), throwsA(isA<Exception>()));
      expect(repo.readyness, Readyness.NotReady);
      expect(config.isConnectionDead, false);
    });
  });

  test('polling: a 4xx fails the repository', () async {
    edge.status = 401;
    final connection = FeatureHubConnection(
      host: edge.host,
      apiKey: 'a/b/c',
      mode: FeatureHubUpdateMode.polling,
    );
    await connection.start();
    expect(
      await connection.waitForReady(const Duration(seconds: 5)),
      Readyness.Failed,
    );
    await connection.close();
  });

  test('passive: only fetches when stale', () async {
    final connection = FeatureHubConnection(
      host: edge.host,
      apiKey: 'a/b/c',
      mode: FeatureHubUpdateMode.passive,
      pollInterval: const Duration(seconds: 30),
    );
    await connection.start();
    expect(edge.requests, hasLength(1));
    await connection.refreshIfStale();
    expect(edge.requests, hasLength(1), reason: 'still fresh');
    await connection.close();
  });

  test('passive: a failed request is not retried until the interval', () async {
    edge.status = 503;
    final connection = FeatureHubConnection(
      host: edge.host,
      apiKey: 'a/b/c',
      mode: FeatureHubUpdateMode.passive,
      pollInterval: const Duration(milliseconds: 300),
    );
    await connection.start();
    expect(edge.requests, hasLength(1));

    // during the outage, evaluations do not each make a request
    for (var i = 0; i < 5; i++) {
      await connection.refreshIfStale();
    }
    expect(edge.requests, hasLength(1));

    // after the interval it tries again, and recovers
    edge.status = 200;
    await Future<void>.delayed(const Duration(milliseconds: 350));
    await connection.refreshIfStale();
    expect(edge.requests, hasLength(2));
    expect(connection.repository.readyness, Readyness.Ready);
    await connection.close();
  });
}

/// Counts the requests it sends.
class _CountingClient extends http.BaseClient {
  final _inner = http.Client();
  int sent = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    sent++;
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
