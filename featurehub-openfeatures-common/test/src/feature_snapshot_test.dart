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

// The core SDK only reads snapshots (feature-snapshot-protocol.yaml
// encoding.feature_snapshot.decoding); the server SDK's snapshot store
// builds them.
void main() {
  group('FeatureSnapshot.from', () {
    final features = [_colour(), _flag()];
    const sha =
        '5da6ce2616ad4cb03d94d3308a7557f2805d2de9624a63985ab267e449641876';

    test('keeps the sha the server sent', () {
      final json = {
        'sha': sha,
        'features': [for (final f in features) f.toJson()],
      };
      for (final data in [json, jsonEncode(json)]) {
        final snapshot = FeatureSnapshot.from(data);
        expect(snapshot.sha, sha);
        expect(_byKey(snapshot, 'colour').toJson(), _colour().toJson());
      }
    });

    test('computes none when it sent none', () {
      for (final data in [
        {
          'features': [for (final f in features) f.toJson()],
        },
        {'sha': 42, 'features': <Object>[]},
        features,
        jsonEncode(features),
      ]) {
        expect(FeatureSnapshot.from(data).sha, isNull, reason: '$data');
      }
      expect(
        FeatureSnapshot(null, features).toJson().containsKey('sha'),
        false,
      );
    });

    test('rejects anything else', () {
      for (final data in [
        42,
        'not json',
        {'nothing': 'here'},
        [
          {'id': 'x'},
        ],
      ]) {
        expect(
          () => FeatureSnapshot.from(data),
          throwsFormatException,
          reason: '$data',
        );
      }
    });
  });

  test('nullable strategy fields decode, and mean empty lists', () {
    final snapshot = FeatureSnapshot.from(
      jsonEncode({
        'features': [
          {
            'id': 'fv-orm',
            'key': 'orm',
            'version': 1,
            'type': 'STRING',
            'value': 'kornaphat',
            'strategies': [
              // a pure percentage strategy written by an SDK that sends null
              {
                'id': 'all',
                'value': 'everyone',
                'percentage': 1000000,
                'attributes': null,
                'percentageAttributes': null,
              },
              {'id': 'absent', 'value': 'never'},
            ],
          },
        ],
      }),
    );
    final strategies = snapshot.features.single.strategies!;
    expect(strategies.map((s) => s.attributes), [isEmpty, isEmpty]);

    final repo = ClientFeatureRepository()
      ..notify(SSEResultState.features, snapshot.features);
    final evaluated = repo.evaluate(
      'orm',
      context: MapStrategyContext({'userkey': 'ling'}),
    );
    expect(evaluated.value, 'everyone');
    expect(evaluated.strategyId, 'all');
    repo.shutdown();
  });
}
