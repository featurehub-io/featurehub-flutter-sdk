import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_openfeatures_common/featurehub_openfeatures_common.dart';
import 'package:test/test.dart';

EvaluatedFeature _feature(
  FeatureValueType type,
  dynamic value, {
  String? strategyId,
  bool intercepted = false,
  Map<String, String>? fp,
}) => EvaluatedFeature(
  key: 'f',
  featureState: FeatureState(
    id: 'id',
    key: 'f',
    version: 4,
    type: type,
    value: value,
    fp: fp,
  ),
  value: value,
  strategyId: strategyId,
  intercepted: intercepted,
);

void main() {
  group('context mapping', () {
    test('targetingKey becomes the userkey; other attributes pass through', () {
      final mapped = mapEvaluationContext({
        'targetingKey': 'user-1',
        'Country': 'nz',
        'tier': ['gold', 'silver'],
        'age': 42,
        'beta': true,
        'missing': null,
      });
      expect(mapped.userkey, 'user-1');
      expect(mapped.attributes, {
        'country': 'nz',
        'tier': ['gold', 'silver'],
        'age': 42,
        'beta': true,
      });
      expect(mapped.asAttributes['userkey'], 'user-1');
    });

    test('well-known keys are recognised case-insensitively', () {
      final mapped = mapEvaluationContext({
        'Platform': 'ios',
        'DEVICE': 'mobile',
        'Session': 's1',
        'Custom': 'kept',
      });
      expect(mapped.attributes.keys, [
        'platform',
        'device',
        'session',
        'Custom',
      ]);
    });

    // conformance: when-active (the context half)
    test('a context fhubWhenActive, in any case, is dropped', () {
      final mapped = mapEvaluationContext({
        'targetingKey': 'lingling',
        'fhubWhenActive': '2020-01-01T00:00:00Z',
        'FHUBWHENACTIVE': '2020-01-01T00:00:00Z',
        'shop': 'kwong pastry',
      });
      expect(mapped.attributes, {'shop': 'kwong pastry'});
      expect(mapped.header, 'shop=kwong%20pastry,userkey=lingling');
    });

    // conformance: date-time-wire-value
    test('a date-time is sent as UTC to the second', () {
      final mapped = mapEvaluationContext({
        'targetingKey': 'orm',
        'since': DateTime.utc(2026, 11, 17, 2, 47, 28, 456),
        'local': DateTime.fromMillisecondsSinceEpoch(0),
      });
      expect(
        mapped.header,
        'local=1970-01-01T00%3A00%3A00Z,since=2026-11-17T02%3A47%3A28Z,'
        'userkey=orm',
      );
    });

    test('the well-known keys are the Edge API\'s, so email is not one', () {
      expect(StrategyAttributeWellKnownNamesExtension.fromMap.keys.toSet(), {
        'device',
        'country',
        'platform',
        'userkey',
        'session',
        'version',
        'fhubWhenActive',
      });
      final mapped = mapEvaluationContext({
        'Version': '2.0.0',
        'Email': 'lingling@kwong.example',
      });
      // a custom attribute keeps its case
      expect(mapped.attributes, {
        'version': '2.0.0',
        'Email': 'lingling@kwong.example',
      });
    });

    test('nested objects are rejected', () {
      expect(
        () => mapEvaluationContext({
          'nested': {'a': 1},
        }),
        throwsA(isA<InvalidContextException>()),
      );
      expect(
        () => mapEvaluationContext({
          'list': [
            {'a': 1},
          ],
        }),
        throwsA(isA<InvalidContextException>()),
      );
    });

    test(
      'the strategy context uses session, then userkey, for percentages',
      () {
        expect(
          mapEvaluationContext({
            'targetingKey': 'u',
          }).strategyContext.defaultPercentageKey(),
          'u',
        );
        expect(
          mapEvaluationContext({
            'targetingKey': 'u',
            'session': 's',
          }).strategyContext.defaultPercentageKey(),
          's',
        );
      },
    );

    test('the header matches ClientContext', () {
      final mapped = mapEvaluationContext({
        'targetingKey': 'fred',
        'country': 'new_zealand',
        'tags': ['a', 'b'],
      });
      final context = ClientContext()
        ..userKey('fred')
        ..attrs('country', ['new_zealand'])
        ..attrs('tags', ['a', 'b']);
      expect(mapped.header, context.generateHeader());
      expect(mapEvaluationContext(null).header, isNull);
    });

    test('applyTo replaces the context attributes', () {
      final context = ClientContext()..attrs('stale', ['x']);
      mapEvaluationContext({'targetingKey': 'u', 'n': 1}).applyTo(context);
      expect(context.getAttr('stale'), isNull);
      expect(context.getAttr('userkey'), ['u']);
      expect(context.getAttr('n'), ['1']);
    });
  });

  group('resolution', () {
    test('not found', () {
      final r = resolveFromEvaluation(
        'f',
        FeatureKind.boolean,
        false,
        const EvaluatedFeature(key: 'f'),
      );
      expect(r.errorCode, ResolutionErrorCode.flagNotFound);
      expect(r.reason, ResolutionReason.error);
      expect(r.value, false);
    });

    test('type mismatch', () {
      final r = resolveFromEvaluation(
        'f',
        FeatureKind.boolean,
        false,
        _feature(FeatureValueType.STRING, 'x'),
      );
      expect(r.errorCode, ResolutionErrorCode.typeMismatch);
      expect(r.flagMetadata, {'featureVersion': 4, 'featureType': 'STRING'});
    });

    test('the feature properties are merged into the metadata', () {
      final r = resolveFromEvaluation(
        'f',
        FeatureKind.string,
        'd',
        _feature(
          FeatureValueType.STRING,
          'x',
          fp: {'owner': 'team-a', 'category': 'ui', 'featureVersion': '99'},
        ),
      );
      expect(r.value, 'x');
      expect(r.flagMetadata, {
        'featureVersion': 4,
        'featureType': 'STRING',
        'owner': 'team-a',
        'category': 'ui',
      });
    });

    test('value-less features give the default, disabled', () {
      final r = resolveFromEvaluation(
        'keep-silent',
        FeatureKind.string,
        'always wonder',
        _feature(FeatureValueType.STRING, null),
      );
      expect(r.value, 'always wonder');
      expect(r.reason, ResolutionReason.disabled);
      expect(r.variant, isNull);
      expect(r.isError, false);
    });

    test('a strategy with no value is disabled, with its variant', () {
      final r = resolveFromEvaluation(
        'keep-silent',
        FeatureKind.string,
        'always wonder',
        _feature(FeatureValueType.STRING, null, strategyId: 'ormkorn'),
      );
      expect(r.value, 'always wonder');
      expect(r.reason, ResolutionReason.disabled);
      expect(r.variant, 'ormkorn');
    });

    test('static and targeting-match values', () {
      final static = resolveFromEvaluation(
        'f',
        FeatureKind.boolean,
        false,
        _feature(FeatureValueType.BOOLEAN, true),
      );
      expect(static.value, true);
      expect(static.reason, ResolutionReason.static_);
      expect(static.variant, isNull);

      final matched = resolveFromEvaluation(
        'f',
        FeatureKind.string,
        '',
        _feature(FeatureValueType.STRING, 'green', strategyId: 's1'),
      );
      expect(matched.value, 'green');
      expect(matched.reason, ResolutionReason.targetingMatch);
      expect(matched.variant, 's1');
    });

    test('numbers', () {
      expect(
        resolveFromEvaluation(
          'f',
          FeatureKind.integer,
          0,
          _feature(FeatureValueType.NUMBER, 12.0),
        ).value,
        12,
      );
      expect(
        resolveFromEvaluation(
          'f',
          FeatureKind.integer,
          0,
          _feature(FeatureValueType.NUMBER, 12.5),
        ).errorCode,
        ResolutionErrorCode.typeMismatch,
      );
      expect(
        resolveFromEvaluation(
          'f',
          FeatureKind.double,
          0.0,
          _feature(FeatureValueType.NUMBER, 3),
        ).value,
        3.0,
      );
    });

    test('JSON objects, and invalid JSON', () {
      final r = resolveFromEvaluation<Map<String, Object?>>(
        'f',
        FeatureKind.object,
        const {},
        _feature(FeatureValueType.JSON, '{"a": [1, 2]}'),
      );
      expect(r.value, {
        'a': [1, 2],
      });

      expect(
        resolveFromEvaluation<Map<String, Object?>>(
          'f',
          FeatureKind.object,
          const {},
          _feature(FeatureValueType.JSON, '{oops'),
        ).errorCode,
        ResolutionErrorCode.parseError,
      );
      expect(
        resolveFromEvaluation<Map<String, Object?>>(
          'f',
          FeatureKind.object,
          const {},
          _feature(FeatureValueType.JSON, '[1]'),
        ).errorCode,
        ResolutionErrorCode.typeMismatch,
      );
    });

    test('intercepted string values are converted', () {
      expect(
        resolveFromEvaluation(
          'f',
          FeatureKind.boolean,
          false,
          _feature(FeatureValueType.BOOLEAN, 'true', intercepted: true),
        ).value,
        true,
      );
      expect(
        resolveFromEvaluation(
          'f',
          FeatureKind.integer,
          0,
          _feature(FeatureValueType.NUMBER, '7', intercepted: true),
        ).value,
        7,
      );
    });
  });

  group('the reason for a locally matched strategy', () {
    final repository = ClientFeatureRepository()
      ..notify(SSEResultState.features, [
        FeatureState(
          id: 'fv-pastry',
          key: 'kwong-pastry',
          version: 1,
          type: FeatureValueType.STRING,
          value: 'plain',
          strategies: [
            // everyone outside Thailand: an attribute strategy
            FeatureRolloutStrategy(
              id: 'chago',
              value: 'mango',
              attributes: [
                FeatureRolloutStrategyAttribute(
                  conditional: RolloutStrategyAttributeConditional.NOT_EQUALS,
                  fieldName: 'country',
                  values: ['thailand'],
                  type: RolloutStrategyFieldType.STRING,
                ),
              ],
            ),
            // 100% of the rest (percentages are out of 1,000,000)
            FeatureRolloutStrategy(
              id: 'omu-co',
              value: 'durian',
              percentage: 1000000,
              attributes: [],
            ),
          ],
        ),
      ]);

    FeatureHubResolution<String> resolve(Map<String, Object> context) =>
        resolveFromEvaluation(
          'kwong-pastry',
          FeatureKind.string,
          'none',
          repository.evaluate(
            'kwong-pastry',
            context: MapStrategyContext(context),
          ),
        );

    test('a percentage rollout is SPLIT', () {
      final r = resolve({'userkey': 'lingling', 'country': 'thailand'});
      expect(r.value, 'durian');
      expect(r.reason, ResolutionReason.split);
      expect(r.variant, 'omu-co');
    });

    test('an attribute strategy is TARGETING_MATCH', () {
      final r = resolve({'userkey': 'orm', 'country': 'new_zealand'});
      expect(r.value, 'mango');
      expect(r.reason, ResolutionReason.targetingMatch);
      expect(r.variant, 'chago');
    });

    test('a strategy the server applied (v) is TARGETING_MATCH', () {
      final r = resolveFromEvaluation(
        'f',
        FeatureKind.string,
        'none',
        _feature(FeatureValueType.STRING, 'durian', strategyId: 'omu-co'),
      );
      expect(r.reason, ResolutionReason.targetingMatch);
    });
  });
}
