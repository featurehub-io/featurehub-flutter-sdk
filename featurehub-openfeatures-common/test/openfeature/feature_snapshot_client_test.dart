@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_openfeatures_common/featurehub_openfeatures_common.dart';
import 'package:test/test.dart';

FeatureState _colour({int version = 1, String nz = 'green'}) => FeatureState(
  id: 'fv-colour',
  key: 'colour',
  version: version,
  type: FeatureValueType.STRING,
  value: 'blue',
  strategies: [
    FeatureRolloutStrategy(
      id: 'nz',
      value: nz,
      attributes: [
        FeatureRolloutStrategyAttribute(
          conditional: RolloutStrategyAttributeConditional.EQUALS,
          fieldName: 'country',
          values: ['nz'],
          type: RolloutStrategyFieldType.STRING,
        ),
      ],
    ),
  ],
);

/// Your own server, as the server SDK example's `GET /features`: the
/// features from [repository] evaluated for the context in the query
/// parameters (as they are, with no parameters, if [rawWithoutContext]), the
/// repository's SHA as the ETag, and 304 for a matching If-None-Match.
class _FeatureServer {
  late HttpServer _server;
  final repository = ClientFeatureRepository();
  final requests = <HttpRequest>[];
  int? failWith;
  String? body;
  bool rawWithoutContext = false;
  Completer<void>? hold;

  String get url => 'http://127.0.0.1:${_server.port}/api/features';

  Future<void> start(List<FeatureState> features) async {
    repository.notify(SSEResultState.features, features);
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> stop() async {
    await _server.close(force: true);
    repository.shutdown();
  }

  void update(List<FeatureState> features) =>
      repository.notify(SSEResultState.features, features);

  Future<void> _handle(HttpRequest request) async {
    requests.add(request);
    final held = hold;
    if (held != null) await held.future;
    final response = request.response;

    if (failWith != null) {
      response.statusCode = failWith!;
      await response.close();
      return;
    }

    final etag = '"${repository.featuresSha}"';
    response.headers.set('etag', etag);
    if (request.headers.value('if-none-match') == etag) {
      response.statusCode = 304;
      await response.close();
      return;
    }

    final params = request.uri.queryParametersAll;
    final snapshot = rawWithoutContext && params.isEmpty
        ? repository.featureSnapshot()
        : repository.featureSnapshot(
            context: {
              for (final MapEntry(:key, :value) in params.entries)
                key: value.length == 1 ? value.single : value,
            },
          );
    response.headers.contentType = ContentType.json;
    response.write(body ?? jsonEncode(snapshot));
    await response.close();
  }
}

void main() {
  late _FeatureServer server;
  final connections = <FeatureHubConnection>[];

  FeatureHubConnection connect({
    String? url,
    FeatureHubUpdateMode mode = FeatureHubUpdateMode.polling,
    Duration pollInterval = const Duration(seconds: 1),
    bool sendContext = true,
    Map<String, String> headers = const {},
  }) {
    final connection = FeatureHubConnection(
      featuresUrl: url ?? server.url,
      sendContext: sendContext,
      headers: headers,
      mode: mode,
      pollInterval: pollInterval,
    );
    connections.add(connection);
    return connection;
  }

  Future<Readyness> ready(FeatureHubConnection c) =>
      c.waitForReady(const Duration(seconds: 5));

  setUp(() async {
    server = _FeatureServer();
    await server.start([_colour()]);
  });

  tearDown(() async {
    for (final c in connections) {
      await c.close();
      c.repository.shutdown();
    }
    connections.clear();
    await server.stop();
  });

  test('loads the features for the context, and is ready', () async {
    final c = connect();
    expect(c.connectsToFeatureHub, false);
    expect(c.clientEvaluated, false);

    await c.start(
      context: mapEvaluationContext({'targetingKey': 'fred', 'country': 'nz'}),
    );
    expect(await ready(c), Readyness.Ready);
    expect(c.repository.evaluate('colour').value, 'green');
    expect(c.repository.evaluate('colour').strategyId, 'nz');
    expect(c.repository.featuresSha, server.repository.featuresSha);

    final request = server.requests.single;
    expect(request.uri.path, '/api/features');
    expect(request.uri.queryParameters, {'userkey': 'fred', 'country': 'nz'});
    expect(request.headers.value('if-none-match'), isNull);
  });

  test(
    'keeps the query parameters in the URL, and sends the headers',
    () async {
      final c = connect(
        url: '${server.url}?app=web',
        headers: {'authorization': 'Bearer t'},
      );
      await c.start(
        context: mapEvaluationContext({
          'country': 'nz',
          'tags': ['a', 'b'],
        }),
      );
      await ready(c);

      final request = server.requests.single;
      expect(request.uri.queryParametersAll, {
        'app': ['web'],
        'country': ['nz'],
        'tags': ['a', 'b'],
      });
      expect(request.headers.value('authorization'), 'Bearer t');
    },
  );

  test('polls with If-None-Match, and loads features that changed', () async {
    final c = connect(pollInterval: const Duration(milliseconds: 1500));
    await c.start(context: mapEvaluationContext({'country': 'nz'}));
    await ready(c);
    final etag = '"${server.repository.featuresSha}"';

    await Future<void>.delayed(const Duration(milliseconds: 1700));
    expect(server.requests, hasLength(2));
    expect(server.requests.last.headers.value('if-none-match'), etag);
    expect(c.repository.evaluate('colour').value, 'green');

    server.update([_colour(version: 2, nz: 'silver')]);
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(server.requests, hasLength(3));
    expect(c.repository.evaluate('colour').value, 'silver');
    expect(c.repository.featuresSha, server.repository.featuresSha);
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('a context change fetches the features for it at once', () async {
    final c = connect(pollInterval: const Duration(hours: 1));
    await c.start(context: mapEvaluationContext({'country': 'au'}));
    await ready(c);
    expect(c.repository.evaluate('colour').value, 'blue');

    final readiness = await c.setContext(
      mapEvaluationContext({'country': 'nz'}),
      const Duration(seconds: 5),
    );
    expect(readiness, Readyness.Ready);
    expect(c.repository.evaluate('colour').value, 'green');

    final request = server.requests.last;
    expect(request.uri.queryParameters, {'country': 'nz'});
    // the features held were for another context
    expect(request.headers.value('if-none-match'), isNull);
  });

  test('a response for an earlier context is discarded', () async {
    final c = connect(
      mode: FeatureHubUpdateMode.passive,
      pollInterval: Duration.zero,
    );
    await c.start(context: mapEvaluationContext({'country': 'nz'}));
    await ready(c);

    server.update([_colour(version: 2)]);
    server.hold = Completer<void>();
    final slow = c.refreshIfStale();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final changed = c.setContext(
      mapEvaluationContext({'country': 'au'}),
      const Duration(seconds: 5),
    );
    server.hold!.complete();
    server.hold = null;
    await (slow, changed).wait;

    expect(server.requests.map((r) => r.uri.queryParameters['country']), [
      'nz',
      'nz',
      'au',
    ]);
    expect(c.repository.evaluate('colour').value, 'blue');
    expect(c.repository.feature('colour').version, 2);
  });

  test(
    'passive mode fetches when read, once the interval has passed',
    () async {
      final c = connect(
        mode: FeatureHubUpdateMode.passive,
        pollInterval: const Duration(milliseconds: 300),
      );
      await c.start();
      await ready(c);

      await c.refreshIfStale();
      expect(server.requests, hasLength(1), reason: 'still fresh');

      await Future<void>.delayed(const Duration(milliseconds: 350));
      await c.refreshIfStale();
      expect(server.requests, hasLength(2));
      expect(
        server.requests.last.headers.value('if-none-match'),
        '"${server.repository.featuresSha}"',
      );

      // no polling of its own
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(server.requests, hasLength(2));
    },
  );

  test('without sendContext, the strategies are evaluated locally', () async {
    server.rawWithoutContext = true;
    final c = connect(sendContext: false);
    expect(c.clientEvaluated, true);
    await c.start(context: mapEvaluationContext({'country': 'au'}));
    await ready(c);

    expect(server.requests.single.uri.hasQuery, false);
    expect(
      c.repository
          .evaluate('colour', context: MapStrategyContext({'country': 'nz'}))
          .value,
      'green',
    );
  });

  test('a server error is retried at the next poll', () async {
    server.failWith = 500;
    final c = connect(pollInterval: const Duration(milliseconds: 1100));
    await c.start();
    expect(c.repository.readyness, Readyness.NotReady);

    server.failWith = null;
    expect(await ready(c), Readyness.Ready);
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('a rejection (4xx) fails the repository and stops polling', () async {
    server.failWith = 401;
    final c = connect(pollInterval: const Duration(milliseconds: 1000));
    await c.start();
    expect(await ready(c), Readyness.Failed);

    await Future<void>.delayed(const Duration(milliseconds: 1200));
    expect(server.requests, hasLength(1));
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('a response that is not a snapshot leaves it not ready', () async {
    server.body = '<html></html>';
    final c = connect(pollInterval: const Duration(hours: 1));
    await c.start();
    expect(c.repository.readyness, Readyness.NotReady);
  });

  test('a featuresUrl is polled, and not used with FeatureHub', () {
    expect(
      () => FeatureHubConnection(
        featuresUrl: 'http://x/features',
        mode: FeatureHubUpdateMode.streaming,
      ),
      throwsArgumentError,
    );
    expect(
      () => FeatureHubConnection(
        featuresUrl: 'http://x/features',
        host: 'http://edge',
        apiKey: 'a/b',
        mode: FeatureHubUpdateMode.polling,
      ),
      throwsArgumentError,
    );
  });
}
