// conformance: readiness-transitions, context-change-readiness,
// failure-after-context-change, features-invalid-payload, permanent-failure,
// edge-stale, bye-not-stale, x-featurehub-encoding, edge-stale-config-ignored,
// edge-polling-several-environments, edge-polling-invalid-body,
// connection-default-mode
//
// The checks of featurehub-sdk-docs specs/featurehub-protocol.yaml that the
// repository, the connection and the FeatureHub polling decoder meet.
import 'dart:async';
import 'dart:convert';

import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_openfeatures_common/featurehub_openfeatures_common.dart';
import 'package:openapi_dart_common/openapi.dart';
import 'package:test/test.dart';

Map<String, dynamic> _feature(
  String key, {
  int version = 1,
  Object? value = 'egg tart',
  String? id,
}) => {
  'id': id ?? 'fv-$key',
  'key': key,
  'version': version,
  'type': 'STRING',
  'value': value,
};

Future<void> _pump() => Future<void>.delayed(Duration.zero);

/// Records every readiness broadcast after the current one.
Future<List<Readyness>> _record(ClientFeatureRepository repo) async {
  final states = <Readyness>[];
  repo.readynessStream.skip(1).listen(states.add);
  await _pump();
  return states;
}

/// A server-evaluated transport: answers each context change with the
/// features for that context, unless [fail] (then a permanent failure).
class _ContextTransport implements FeatureHubTransport {
  final ClientFeatureRepository repository;
  var contextChanges = 0;
  bool fail = false;
  bool answer = true;

  _ContextTransport(this.repository);

  void _features() => repository.notify(SSEResultState.features, [
    _feature('kwong_pastry', value: repository.clientContext.generateHeader()),
  ]);

  @override
  Future<void> start() async => _features();

  @override
  Future<void> contextChanged() async {
    contextChanges++;
    await _pump();
    if (fail) {
      repository.notify(SSEResultState.failure, null);
    } else if (answer) {
      _features();
    }
  }

  @override
  Future<void> refreshIfStale() async {}

  @override
  Future<void> close() async {}
}

void main() {
  group('readiness', () {
    late ClientFeatureRepository repo;
    setUp(() => repo = ClientFeatureRepository());

    test('a full set makes it Ready, and is broadcast every time', () async {
      final states = await _record(repo);
      repo.notify(SSEResultState.features, [_feature('ling')]);
      repo.notify(SSEResultState.features, [_feature('ling')]);
      await _pump();
      expect(states, [Readyness.Ready, Readyness.Ready]);
    });

    test('clearing goes Ready -> Stale -> NotReady', () async {
      repo.notify(SSEResultState.features, [_feature('ling')]);
      final states = await _record(repo);
      repo.shutdownFeatures();
      await _pump();
      expect(states, [Readyness.Stale, Readyness.NotReady]);
      expect(repo.readyness, Readyness.NotReady);
    });

    test('a context change goes Ready -> Stale, never NotReady', () async {
      repo.notify(SSEResultState.features, [_feature('ling')]);
      final states = await _record(repo);
      repo.contextChanging();
      repo.notify(SSEResultState.features, [_feature('ling', version: 2)]);
      await _pump();
      expect(states, [Readyness.Stale, Readyness.Ready]);
    });

    test('a context change before any features changes nothing', () async {
      final states = await _record(repo);
      repo.contextChanging();
      await _pump();
      expect(states, isEmpty);
      expect(repo.readyness, Readyness.NotReady);
    });

    test('a failure before any features is Failed, which is final', () async {
      final states = await _record(repo);
      repo.notify(SSEResultState.failure, null);
      expect(repo.connectionFailed, true);
      expect(repo.readyness, Readyness.Failed);
      // a later full set (from a store, say) is applied; readiness stays
      repo.notify(SSEResultState.features, [_feature('ling')]);
      repo.contextChanging();
      repo.shutdownFeatures();
      await _pump();
      expect(states, [Readyness.Failed]);
      expect(repo.readyness, Readyness.Failed);
    });

    test('a failure after features is Stale, and the features stay', () async {
      repo.notify(SSEResultState.features, [_feature('ling')]);
      final failed = <bool>[];
      repo.connectionFailedStream.listen(failed.add);
      final states = await _record(repo);

      repo.notify(SSEResultState.failure, null);
      repo.notify(SSEResultState.failure, null); // changes nothing
      await _pump();
      expect(failed, [false, true]);
      expect(states, [Readyness.Stale]);
      expect(repo.evaluate('ling').value, 'egg tart');

      // nothing will bring them up to date: a later full set stays Stale
      repo.notify(SSEResultState.features, [
        _feature('ling', version: 2, value: 'mango'),
      ]);
      await _pump();
      expect(repo.evaluate('ling').value, 'mango');
      expect(states, [Readyness.Stale, Readyness.Stale]);
    });

    test('a failure during a context change stays Stale, not Failed', () {
      repo.notify(SSEResultState.features, [_feature('ling')]);
      repo.contextChanging();
      repo.notify(SSEResultState.failure, null);
      expect(repo.connectionFailed, true);
      expect(repo.readyness, Readyness.Stale);
      expect(repo.evaluate('ling').value, 'egg tart');
    });

    test('a stale environment goes Ready -> Stale, and is broadcast', () async {
      repo.notify(SSEResultState.features, [_feature('ling')]);
      final stale = <bool>[];
      repo.environmentStaleStream.listen(stale.add);
      repo.markEnvironmentStale();
      await _pump();
      expect(stale, [false, true]);
      expect(repo.readyness, Readyness.Stale);
      repo.notify(SSEResultState.features, [_feature('ling')]);
      expect(repo.readyness, Readyness.Stale);
    });

    test('a stale environment before any features leaves readiness', () {
      repo.markEnvironmentStale();
      expect(repo.environmentStale, true);
      expect(repo.readyness, Readyness.NotReady);
    });

    test('a bye leaves Ready and Stale as they are', () async {
      final states = await _record(repo);
      repo.notify(SSEResultState.bye, null);
      repo.notify(SSEResultState.features, [_feature('ling')]);
      repo.notify(SSEResultState.bye, null);
      repo.contextChanging();
      repo.notify(SSEResultState.bye, null);
      await _pump();
      expect(states, [Readyness.Ready, Readyness.Stale]);
    });
  });

  group('payloads', () {
    late ClientFeatureRepository repo;
    setUp(() {
      repo = ClientFeatureRepository()
        ..notify(SSEResultState.features, [_feature('ling')]);
    });

    test('features that are not a list change nothing', () async {
      final states = await _record(repo);
      for (final payload in ['ling', <String, dynamic>{}, 3, null]) {
        repo.notify(SSEResultState.features, payload);
      }
      await _pump();
      expect(states, isEmpty);
      expect(repo.evaluate('ling').value, 'egg tart');
    });

    test('invalid features are skipped, and are not in the set', () {
      repo.notify(SSEResultState.features, [_feature('orm')]);
      repo.notify(SSEResultState.features, [
        _feature('kornaphat'),
        {'id': 'fv-orm', 'key': 'orm', 'type': 'STRING'}, // no version
        {'id': 'fv-ling', 'key': 'ling', 'version': 2}, // no type
        'chago',
        null,
      ]);
      expect(repo.readyness, Readyness.Ready);
      expect(repo.featureStates.map((f) => f.key), ['kornaphat']);
    });

    test('an invalid single feature is skipped', () {
      repo.notify(SSEResultState.feature, {'key': 'ling', 'version': 9});
      repo.notify(SSEResultState.feature, 'ling');
      expect(repo.evaluate('ling').featureState!.version, 1);
    });

    test('a deletion needs only the key', () {
      repo.notify(SSEResultState.deleteFeature, {'key': 'ling'});
      expect(repo.evaluate('ling').exists, false);
      repo.notify(SSEResultState.deleteFeature, {'id': 'no-key'});
    });
  });

  group('x-featurehub', () {
    String? header(Map<String, List<String>> attributes) {
      final context = ClientContext();
      attributes.forEach(context.attrs);
      return context.generateHeader();
    }

    test('the spec examples reproduce', () {
      expect(
        header({
          'userkey': ['fred'],
          'country': ['nz'],
        }),
        'country=nz,userkey=fred',
      );
      expect(
        header({
          'shop': ['a&b', 'c d'],
        }),
        'shop=a%26b%2Cc%20d',
      );
      expect(
        header({
          'my key': ['x'],
          'a,b=c': ['y'],
        }),
        'a%2Cb%3Dc=y,my%20key=x',
      );
    });

    test('encodes as encodeURIComponent, leaving out empty attributes', () {
      expect(
        header({
          'empty': [],
          'name': ["kwong!~*'()", 'หลิงหลิง'],
        }),
        "name=kwong!~*'()%2C%E0%B8%AB%E0%B8%A5%E0%B8%B4%E0%B8%87%E0%B8%AB"
        '%E0%B8%A5%E0%B8%B4%E0%B8%87',
      );
      expect(header({'empty': []}), isNull);
      expect(header({}), isNull);
    });
  });

  test('a config event is stale with any edge.stale value, only', () {
    for (final data in [
      '{"edge.stale": true}',
      '{"edge.stale": false}',
      '{"edge.stale": null}',
      '{"edge.stale": "always wonder"}',
    ]) {
      expect(featureHubConfigIsStale(data), true, reason: data);
    }
    for (final data in [null, '{}', '{"stale": true}', '["edge.stale"]', 'x']) {
      expect(featureHubConfigIsStale(data), false, reason: data);
    }
  });

  group('FeatureHub polling body', () {
    late ClientFeatureRepository repo;
    late FeatureHubRestClient client;

    setUp(() {
      repo = ClientFeatureRepository()
        ..notify(SSEResultState.features, [_feature('ling')]);
      client = FeatureHubRestClient('http://localhost', [
        'lingling/kwong*pastry',
      ], repo);
    });

    Future<void> decode(String body) => client.decodeResponse(
      ApiResponse(200, {}, Stream.value(utf8.encode(body))),
    );

    test('several environments are one full set', () async {
      await decode(
        jsonEncode([
          {
            'id': 'env-ling',
            'features': [_feature('ling', version: 2)],
          },
          null,
          {'id': 'env-empty', 'features': null},
          {'id': 'env-none'},
          {
            'id': 'env-orm',
            'features': [_feature('orm')],
          },
        ]),
      );
      expect(
        {for (final f in repo.featureStates) f.key: f.environmentId},
        {'ling': 'env-ling', 'orm': 'env-orm'},
      );
    });

    test('anything else is an error, and changes nothing', () async {
      final states = await _record(repo);
      for (final body in [
        '{"id": "e1", "features": []}',
        '["e1"]',
        '[{"id": "e1", "features": {"key": "f1"}}]',
        'not json',
      ]) {
        await expectLater(decode(body), throwsFormatException, reason: body);
      }
      await _pump();
      expect(states, isEmpty);
      expect(repo.featureStates.map((f) => f.key), ['ling']);
    });
  });

  group('connection', () {
    test('the default mode is streaming, for any key', () {
      expect(
        FeatureHubConnection(host: 'http://x', apiKey: 'lingling/kwong').mode,
        FeatureHubUpdateMode.streaming,
      );
      expect(
        FeatureHubConnection(host: 'http://x', apiKey: 'lingling/kwong*a').mode,
        FeatureHubUpdateMode.streaming,
      );
      FeatureHubConnection(
        host: 'http://x',
        apiKey: 'lingling/kwong',
        mode: FeatureHubUpdateMode.streaming,
      );
    });

    late ClientFeatureRepository repo;
    late _ContextTransport transport;
    late FeatureHubConnection connection;

    setUp(() async {
      repo = ClientFeatureRepository();
      transport = _ContextTransport(repo);
      connection = FeatureHubConnection(
        host: 'http://x',
        apiKey: 'lingling/kwong',
        repository: repo,
        transport: transport,
      );
      await connection.start(
        context: mapEvaluationContext({'targetingKey': 'ling'}),
      );
    });

    test('a context change is Stale until its features arrive', () async {
      final states = await _record(repo);
      final readiness = await connection.setContext(
        mapEvaluationContext({'targetingKey': 'orm'}),
        const Duration(seconds: 2),
      );
      expect(readiness, Readyness.Ready);
      expect(states, [Readyness.Stale, Readyness.Ready]);
      expect(repo.evaluate('kwong_pastry').value, 'userkey=orm');
    });

    test('a failure during a context change ends the wait', () async {
      transport.fail = true;
      final readiness = await connection.setContext(
        mapEvaluationContext({'targetingKey': 'orm'}),
        const Duration(seconds: 30),
      );
      expect(readiness, Readyness.Stale);
      expect(repo.connectionFailed, true);
      expect(repo.evaluate('kwong_pastry').value, 'userkey=ling');
    });

    test('once the connection failed, nothing is fetched', () async {
      repo.notify(SSEResultState.failure, null);
      await connection.setContext(
        mapEvaluationContext({'targetingKey': 'orm'}),
        const Duration(seconds: 2),
      );
      expect(transport.contextChanges, 0);
    });

    test('an unanswered context change stays Stale', () async {
      transport.answer = false;
      final readiness = await connection.setContext(
        mapEvaluationContext({'targetingKey': 'orm'}),
        const Duration(milliseconds: 50),
      );
      expect(readiness, Readyness.Stale);
    });

    // conformance: single-context
    test('a context change is pending until its features arrive', () async {
      expect(connection.contextChangePending, false);
      expect(connection.contextChangeStartedAt, isNull);
      transport.answer = false;
      await connection.setContext(
        mapEvaluationContext({'targetingKey': 'orm'}),
        const Duration(milliseconds: 20),
      );
      expect(connection.contextChangePending, true);
      expect(connection.contextChangeStartedAt, isNotNull);

      // the same context again waits again, and wakes when they arrive
      final again = connection.setContext(
        mapEvaluationContext({'targetingKey': 'orm'}),
        const Duration(seconds: 5),
      );
      await _pump();
      transport._features();
      expect(await again, Readyness.Ready);
      expect(connection.contextChangePending, false);
      expect(connection.contextChangeStartedAt, isNull);
      expect(repo.evaluate('kwong_pastry').value, 'userkey=orm');
      expect(transport.contextChanges, 1);
    });

    test('a context change is not pending once the source stops', () async {
      transport.answer = false;
      await connection.setContext(
        mapEvaluationContext({'targetingKey': 'orm'}),
        const Duration(milliseconds: 20),
      );
      repo.notify(SSEResultState.failure, null);
      expect(connection.contextChangePending, false);
    });
  });
}
