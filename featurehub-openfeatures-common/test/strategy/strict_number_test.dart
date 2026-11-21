// NUMBER attributes use strict numbers, not JavaScript's parseInt /
// parseFloat (featurehub-sdk-docs specs/rollout-strategies.yaml,
// js_conversions.strict_number).
import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_openfeatures_common/featurehub_openfeatures_common.dart';
import 'package:featurehub_openfeatures_common/src/strategy/js_compat.dart';
import 'package:test/test.dart';

typedef _C = RolloutStrategyAttributeConditional;

bool _match(
  RolloutStrategyAttributeConditional conditional,
  List<dynamic> values,
  Object supplied,
) {
  final attr = FeatureRolloutStrategyAttribute(
    conditional: conditional,
    type: RolloutStrategyFieldType.NUMBER,
    fieldName: 'kwong_age',
    values: values,
  );
  return const MatcherRegistry().findMatcher(attr).match(supplied, attr);
}

void main() {
  test('strings that are exactly a decimal integer or float are numbers', () {
    const valid = {
      '0': 0,
      '12': 12,
      '-5': -5,
      '+7': 7,
      '007': 7,
      '2.5': 2.5,
      '-0.5': -0.5,
      '100.0': 100.0,
      '99999999999999999999': 1e20,
    };
    valid.forEach((s, n) => expect(strictNumber(s), n, reason: s));
    expect(strictNumber(41), 41);
    expect(strictNumber(1.5), 1.5);
  });

  test('anything else is not a number', () {
    for (final s in [
      '12abc', '1e3', '1E3', '0x10', '.5', '-.5', '5.', ' 3', '3 ', '1,000', //
      'Infinity', '-Infinity', 'NaN', '', '+', '1.2.3', '๑๒', 'ling',
    ]) {
      expect(strictNumber(s), isNull, reason: '"$s"');
    }
    for (final v in [
      double.nan,
      double.infinity,
      double.negativeInfinity,
      true,
      null,
      DateTime(2024),
    ]) {
      expect(strictNumber(v), isNull, reason: '$v');
    }
  });

  group('a supplied value that is not a number never matches', () {
    for (final conditional in RolloutStrategyAttributeConditional.values) {
      test(conditional.name, () {
        for (final supplied in ['12abc', '1e3', 'orm', ' 3']) {
          expect(
            _match(conditional, [1, 12, 1000, 'kornaphat'], supplied),
            false,
            reason: supplied,
          );
        }
      });
    }
  });

  test('values that are not numbers are ignored', () {
    expect(
      _match(RolloutStrategyAttributeConditional.EQUALS, ['1e3', 1000], 1000),
      true,
    );
    expect(
      _match(RolloutStrategyAttributeConditional.EQUALS, ['1e3'], 1000),
      false,
    );
    expect(
      _match(RolloutStrategyAttributeConditional.GREATER, ['0x10'], 1000),
      false,
    );
    expect(
      _match(RolloutStrategyAttributeConditional.NOT_EQUALS, ['1e3'], 1000),
      true,
    );
    expect(
      _match(RolloutStrategyAttributeConditional.STARTS_WITH, ['1e'], 1000),
      false,
    );
  });

  test('valid numbers still compare numerically and as text', () {
    expect(_match(_C.EQUALS, [1, 2], '1.0'), true);
    expect(_match(_C.GREATER, [10], '12'), true);
    expect(_match(_C.LESS_EQUALS, ['2.5'], '+2.5'), true);
    expect(_match(_C.STARTS_WITH, [1, 2], '100.0'), true);
    expect(_match(_C.NOT_EQUALS, [1, 2], '-5'), true);
  });
}
