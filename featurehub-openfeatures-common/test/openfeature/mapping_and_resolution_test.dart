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

    test('value-less features give the default', () {
      final r = resolveFromEvaluation(
        'f',
        FeatureKind.string,
        'def',
        _feature(FeatureValueType.STRING, null),
      );
      expect(r.value, 'def');
      expect(r.reason, ResolutionReason.default_);
      expect(r.isError, false);
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
}
