import 'dart:async';

import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_openfeatures_common/featurehub_openfeatures_common.dart';
import 'package:featurehub_sse_client/featurehub_sse_client.dart';
import 'package:rxdart/rxdart.dart';
import 'package:test/test.dart';

FeatureRolloutStrategyAttribute _attr(
  String field,
  RolloutStrategyAttributeConditional conditional,
  List<dynamic> values, [
  RolloutStrategyFieldType type = RolloutStrategyFieldType.STRING,
]) => FeatureRolloutStrategyAttribute(
  conditional: conditional,
  fieldName: field,
  values: values,
  type: type,
);

FeatureState _colour() => FeatureState(
  id: 'fv-colour',
  key: 'colour',
  version: 1,
  type: FeatureValueType.STRING,
  value: 'blue',
  strategies: [
    FeatureRolloutStrategy(
      id: 'nz',
      value: 'green',
      attributes: [
        _attr('country', RolloutStrategyAttributeConditional.EQUALS, ['nz']),
      ],
    ),
    FeatureRolloutStrategy(
      id: 'new-app',
      value: 'purple',
      attributes: [
        _attr('version', RolloutStrategyAttributeConditional.GREATER_EQUALS, [
          '2.0.0',
        ], RolloutStrategyFieldType.SEMANTIC_VERSION),
      ],
    ),
  ],
);

void main() {
  group('repository evaluation', () {
    late ClientFeatureRepository repo;

    setUp(() {
      repo = ClientFeatureRepository();
      repo.notify(SSEResultState.features, [
        _colour(),
        FeatureState(
          id: 'fv-flag',
          key: 'flag',
          version: 3,
          type: FeatureValueType.BOOLEAN,
          value: true,
          l: true,
        ),
      ]);
    });

    test('a matching strategy supplies the value', () {
      final result = repo.evaluate(
        'colour',
        context: const MapStrategyContext({
          'country': ['nz'],
        }),
      );
      expect(result.value, 'green');
      expect(result.strategyId, 'nz');
      expect(result.exists, true);
      expect(result.type, FeatureValueType.STRING);
    });

    test('strategies are applied in order', () {
      final result = repo.evaluate(
        'colour',
        context: const MapStrategyContext({
          'country': 'nz',
          'version': '3.0.0',
        }),
      );
      expect(result.strategyId, 'nz');
    });

    test('no match, or no context, gives the default value', () {
      expect(
        repo
            .evaluate(
              'colour',
              context: const MapStrategyContext({'country': 'au'}),
            )
            .value,
        'blue',
      );
      final noContext = repo.evaluate('colour');
      expect(noContext.value, 'blue');
      expect(noContext.strategyId, isNull);
    });

    test('an unknown feature does not exist', () {
      final result = repo.evaluate('nope');
      expect(result.exists, false);
      expect(result.value, isNull);
    });

    test('feature metadata is available', () {
      final result = repo.evaluate('flag');
      expect(result.value, true);
      expect(result.locked, true);
      expect(result.version, 3);
      expect(repo.featureStates.map((f) => f.key), ['colour', 'flag']);
    });

    test('interceptors take precedence, respecting locks', () {
      repo.registerFeatureValueInterceptor(
        false,
        (key) => ValueMatch(true, 'intercepted'),
      );
      final colour = repo.evaluate('colour');
      expect(colour.value, 'intercepted');
      expect(colour.intercepted, true);
      // flag is locked and the interceptor may not override locks
      expect(repo.evaluate('flag').value, true);
    });

    test('client-evaluated features report the strategy that matched', () {
      final noMatch = repo.evaluate(
        'colour',
        context: const MapStrategyContext({'country': 'au'}),
      );
      expect(noMatch.strategyId, isNull);
    });

    test('feature holders apply strategies with the repository context', () {
      expect(repo.getString('colour'), 'blue');
      repo.clientContext.version('2.1.0');
      expect(repo.getString('colour'), 'purple');
      repo.clientContext.attrs('country', ['nz']);
      expect(repo.getString('colour'), 'green');
    });
  });

  group('server-evaluated features', () {
    FeatureState served(String value, String? strategyId) => FeatureState(
      id: 'fv-banner',
      key: 'banner',
      version: 5,
      type: FeatureValueType.STRING,
      value: value,
      v: strategyId,
    );

    test('report the strategy the server applied', () {
      final repo = ClientFeatureRepository();
      repo.notify(SSEResultState.features, [served('sale', 'black-friday')]);

      final result = repo.evaluate('banner');
      expect(result.value, 'sale');
      expect(result.strategyId, 'black-friday');
    });

    test('report no strategy when the server applied none', () {
      final repo = ClientFeatureRepository();
      repo.notify(SSEResultState.features, [served('default', null)]);
      expect(repo.evaluate('banner').strategyId, isNull);
    });

    test('pick up a different strategy with the same value and version', () {
      // e.g. after a context change, another strategy matches with the same
      // value
      final repo = ClientFeatureRepository();
      repo.notify(SSEResultState.features, [served('sale', 'black-friday')]);
      repo.notify(SSEResultState.features, [served('sale', 'vip')]);
      expect(repo.evaluate('banner').strategyId, 'vip');

      repo.notify(SSEResultState.features, [served('sale', null)]);
      expect(repo.evaluate('banner').strategyId, isNull);
    });
  });

  group('client-evaluated API keys', () {
    test('FeatureHubConfig accepts them and never sends the context', () async {
      final repo = ClientFeatureRepository();
      final config = FeatureHubConfig('http://localhost', [
        'default/env/key*abc',
      ], repo);
      expect(config.clientEvaluated, true);

      repo.clientContext.userKey('fred').build();
      await Future<void>.delayed(Duration.zero);
      expect(config.xFeatureHubHeader, isNull);
    });

    test('server-evaluated keys still send the context', () async {
      final repo = ClientFeatureRepository();
      final config = FeatureHubConfig('http://localhost', [
        'default/env/key',
      ], repo);
      expect(config.clientEvaluated, false);

      repo.clientContext.userKey('fred').build();
      await Future<void>.delayed(Duration.zero);
      expect(config.xFeatureHubHeader, contains('fred'));
    });

    test('client- and server-evaluated keys cannot be mixed', () {
      expect(
        () => FeatureHubConfig('http://localhost', [
          'a/b/c*d',
          'a/b/c',
        ], ClientFeatureRepository()),
        throwsArgumentError,
      );
    });

    test(
      'the SSE listener connects once and ignores context changes',
      () async {
        final repo = ClientFeatureRepository();
        final streams = <PublishSubject<Event>>[];
        final listener = _RecordingListener('a/b/c*d', repo, streams);
        expect(listener.clientEvaluated, true);

        await listener.init();
        await Future<void>.delayed(Duration.zero);
        expect(streams, hasLength(1));

        repo.clientContext.userKey('fred').build();
        await Future<void>.delayed(Duration.zero);
        expect(streams, hasLength(1), reason: 'no reconnection');
        expect(streams.single.hasListener, true);

        listener.close();
      },
      // the dart:io listener; test/web/web_test.dart tests the browser one
      testOn: 'vm',
    );
  });
}

class _RecordingListener extends EventSourceRepositoryListener {
  final List<PublishSubject<Event>> streams;

  _RecordingListener(String apiKey, ClientFeatureRepository repo, this.streams)
    : super('http://localhost', apiKey, repo, doInit: false);

  // not @override: the analyzer resolves the conditional export to the stub
  // listener, but at runtime this overrides the dart:io connect()
  Future<Stream<Event>> connect(String url) async {
    final stream = PublishSubject<Event>();
    streams.add(stream);
    return stream;
  }
}
