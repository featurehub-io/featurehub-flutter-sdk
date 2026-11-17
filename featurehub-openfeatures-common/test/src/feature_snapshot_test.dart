import 'dart:convert';

import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_openfeatures_common/featurehub_openfeatures_common.dart';
import 'package:test/test.dart';

FeatureState _colour() => FeatureState(
  id: 'fv-colour',
  key: 'colour',
  version: 2,
  type: FeatureValueType.STRING,
  value: 'blue',
  fp: {'owner': 'ui'},
  environmentId: 'env',
  strategies: [
    FeatureRolloutStrategy(
      id: 'nz',
      value: 'green',
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

FeatureState _flag() => FeatureState(
  id: 'fv-flag',
  key: 'flag',
  version: 3,
  type: FeatureValueType.BOOLEAN,
  value: true,
  environmentId: 'env',
);

FeatureState _byKey(FeatureSnapshot s, String key) =>
    s.features.singleWhere((f) => f.key == key);

void main() {
  late ClientFeatureRepository repo;

  setUp(() {
    repo = ClientFeatureRepository();
    repo.notify(SSEResultState.features, [_colour(), _flag()]);
  });
  tearDown(() => repo.shutdown());

  group('featureSnapshot', () {
    test('without a context, gives the features as they are', () {
      final s = repo.featureSnapshot();
      expect(s.sha, repo.featuresSha);
      expect(s.features.map((f) => f.toJson()), [
        _colour().toJson(),
        _flag().toJson(),
      ]);

      // copies: changing them does not change the repository
      _byKey(s, 'colour').value = 'red';
      expect(repo.feature('colour').stringValue, 'blue');
    });

    test('with a context, evaluates the strategies for it', () {
      final s = repo.featureSnapshot(context: {'country': 'nz'});
      expect(s.sha, repo.featuresSha);

      final colour = _byKey(s, 'colour');
      expect(colour.value, 'green');
      expect(colour.v, 'nz');
      expect(colour.strategies, isNull);
      expect(colour.version, 2);
      expect(colour.fp, {'owner': 'ui'});
      expect(colour.environmentId, 'env');

      expect(_byKey(s, 'flag').toJson(), _flag().toJson());
    });

    test('with a context no strategy matches, gives the default value', () {
      final colour = _byKey(
        repo.featureSnapshot(context: {'targetingKey': 'fred'}),
        'colour',
      );
      expect(colour.value, 'blue');
      expect(colour.v, isNull);
      expect(colour.strategies, isNull);
    });

    test('ignores value interceptors', () {
      repo.addValueInterceptor(_Override());
      expect(repo.feature('flag').booleanValue, false);
      expect(_byKey(repo.featureSnapshot(context: {}), 'flag').value, true);
    });

    test('rejects a context FeatureHub cannot represent', () {
      expect(
        () => repo.featureSnapshot(
          context: {
            'nested': {'a': 1},
          },
        ),
        throwsA(isA<InvalidContextException>()),
      );
    });
  });

  group('FeatureHubConfig.loadFeatureSnapshot', () {
    late ClientFeatureRepository client;
    late FeatureHubConfig config;

    setUp(() {
      client = ClientFeatureRepository();
      config = FeatureHubConfig('http://localhost', ['a/b/c'], client);
    });
    tearDown(() => client.shutdown());

    test('loads a snapshot, as it would arrive from a server API', () {
      final served = jsonEncode(
        repo.featureSnapshot(context: {'country': 'nz'}),
      );

      final loaded = config.loadFeatureSnapshot(served);
      expect(loaded.sha, repo.featuresSha);
      expect(client.readyness, Readyness.Ready);
      expect(client.feature('colour').stringValue, 'green');
      expect(client.evaluate('colour').strategyId, 'nz');
      expect(client.feature('flag').booleanValue, true);
      // the same features, so the same SHA
      expect(client.featuresSha, repo.featuresSha);
    });

    test('accepts the snapshot, its JSON map, or a list of features', () {
      final snapshot = repo.featureSnapshot();
      for (final data in [
        snapshot,
        snapshot.toJson(),
        jsonDecode(jsonEncode(snapshot)),
        snapshot.features,
        jsonDecode(jsonEncode(snapshot.features)),
      ]) {
        final loaded = config.loadFeatureSnapshot(data);
        expect(loaded.sha, repo.featuresSha, reason: '$data');
        expect(client.featuresSha, repo.featuresSha, reason: '$data');
      }
    });

    test('a client-evaluated repository evaluates loaded strategies', () {
      config.loadFeatureSnapshot(repo.featureSnapshot().toJson());
      expect(
        client
            .evaluate('colour', context: MapStrategyContext({'country': 'nz'}))
            .value,
        'green',
      );
    });

    test('a full set: features not in it are removed', () {
      config.loadFeatureSnapshot(repo.featureSnapshot());
      config.loadFeatureSnapshot([_flag()]);
      expect(client.feature('colour').exists, false);
      expect(client.feature('flag').exists, true);
    });

    test('rejects anything else, leaving the repository as it was', () {
      config.loadFeatureSnapshot([_flag()]);
      for (final data in [
        42,
        'not json',
        {'nothing': 'here'},
        [
          {'id': 'x'},
        ],
      ]) {
        expect(
          () => config.loadFeatureSnapshot(data),
          throwsFormatException,
          reason: '$data',
        );
      }
      expect(client.feature('flag').exists, true);
    });
  });
}

class _Override extends ValueInterceptor {
  @override
  ValueMatch matched(String key, FeatureState? featureState) =>
      key == 'flag' ? const ValueMatch(true, false) : ValueMatch.none;
}
