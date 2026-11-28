// conformance: when-active, when-active-combined, date-time-utc
// (rollout-strategies.yaml algorithm.well_known_attributes.fhubWhenActive and
// matchers.utc_vectors)
import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_openfeatures_common/featurehub_openfeatures_common.dart';
import 'package:test/test.dart';

const _t = '2026-12-01T09:00:00Z';

FeatureRolloutStrategyAttribute _attr(
  RolloutStrategyAttributeConditional conditional,
  List<Object?> values, {
  String fieldName = 'fhubWhenActive',
  RolloutStrategyFieldType type = RolloutStrategyFieldType.DATETIME,
}) => FeatureRolloutStrategyAttribute(
  conditional: conditional,
  type: type,
  fieldName: fieldName,
  values: values,
);

/// Whether a strategy holding [attributes] (and [percentage]) applies at
/// [clock] for [context].
bool _applies(
  List<FeatureRolloutStrategyAttribute> attributes,
  String clock, {
  Map<String, Object?> context = const {'userkey': 'lingling'},
  int? percentage,
}) {
  final apply = ApplyFeature(clock: () => DateTime.parse(clock));
  return apply
      .apply(
        [
          FeatureRolloutStrategy(
            id: 's1',
            value: true,
            percentage: percentage,
            attributes: attributes,
          ),
        ],
        'kwong-pastry',
        'fv-kwong',
        MapStrategyContext(context),
      )
      .matched;
}

void main() {
  group('fhubWhenActive', () {
    const c = RolloutStrategyAttributeConditional.values;
    RolloutStrategyAttributeConditional named(String name) =>
        c.firstWhere((v) => v.name == name);

    // rollout-strategies.yaml well_known_attributes.vectors
    final vectors = <(String, List<Object?>, String, bool, String)>[
      ('GREATER_EQUALS', [_t], '2026-12-01T08:59:59.999Z', false, 'before'),
      ('GREATER_EQUALS', [_t], '2026-12-01T09:00:00.000Z', true, 'at'),
      ('GREATER_EQUALS', [_t], '2027-01-01T00:00:00Z', true, 'after'),
      ('GREATER', [_t], '2026-12-01T09:00:00.000Z', false, 'strictly after'),
      ('LESS', [_t], '2026-12-01T08:59:59.999Z', true, 'until'),
      ('LESS', [_t], '2026-12-01T09:00:00.000Z', false, 'not at'),
      ('LESS_EQUALS', [_t], '2026-12-01T09:00:00.000Z', true, 'at'),
      ('EQUALS', [_t], '2026-12-01T09:00:00.000Z', true, 'at'),
      ('EQUALS', [_t], '2026-12-01T09:00:00.999Z', true, 'to the second'),
      ('EQUALS', [_t], '2026-12-01T09:00:01Z', false, 'next second'),
      ('NOT_EQUALS', [_t], '2026-12-01T09:00:00.500Z', false, 'same second'),
      ('NOT_EQUALS', [_t], '2026-12-01T09:00:01Z', true, 'other second'),
      ('GREATER', [_t], '2026-12-01T09:00:00.999Z', false, 'next second'),
      (
        'GREATER_EQUALS',
        ['2026-12-01T09:00:00.750Z'],
        '2026-12-01T09:00:00.100Z',
        true,
        "the value's fraction is dropped",
      ),
      ('INCLUDES', [_t], '2027-01-01T00:00:00Z', false, 'unsupported'),
      ('EXCLUDES', [_t], '2027-01-01T00:00:00Z', false, 'unsupported'),
      ('STARTS_WITH', ['2026'], '2026-12-02T00:00:00Z', false, 'not text'),
      ('ENDS_WITH', ['Z'], '2026-12-02T00:00:00Z', false, 'not text'),
      ('REGEX', ['.*'], '2026-12-02T00:00:00Z', false, 'not a pattern'),
      ('NOT_EQUALS', [], '2027-01-01T00:00:00Z', false, 'no values'),
      ('GREATER_EQUALS', [], '2026-12-02T00:00:00Z', false, 'no values'),
      (
        'GREATER_EQUALS',
        ['next tuesday'],
        '2026-12-02T00:00:00Z',
        false,
        'unparseable',
      ),
    ];
    for (final (conditional, values, clock, result, shows) in vectors) {
      test('$conditional $values at $clock is $result ($shows)', () {
        expect(
          ApplyFeature.whenActive(
            _attr(named(conditional), values),
            DateTime.parse(clock),
          ),
          result,
        );
        expect(_applies([_attr(named(conditional), values)], clock), result);
      });
    }

    const atOrAfter = RolloutStrategyAttributeConditional.GREATER_EQUALS;

    test('its type is ignored', () {
      final attr = _attr(atOrAfter, [
        _t,
      ], type: RolloutStrategyFieldType.STRING);
      expect(_applies([attr], '2026-12-02T00:00:00Z'), true);
    });

    test('its name is case-insensitive', () {
      final attr = _attr(atOrAfter, [_t], fieldName: 'FHUBWHENACTIVE');
      expect(_applies([attr], '2026-12-02T00:00:00Z'), true);
    });

    test('the context cannot supply it', () {
      expect(
        _applies(
          [
            _attr(RolloutStrategyAttributeConditional.GREATER_EQUALS, [_t]),
          ],
          '2026-11-30T00:00:00Z',
          context: {'userkey': 'orm', 'fhubWhenActive': '2020-01-01T00:00:00Z'},
        ),
        false,
      );
    });

    test('the result follows the clock, with no new features', () {
      var now = DateTime.utc(2026, 12, 1, 8, 59, 59);
      final apply = ApplyFeature(clock: () => now);
      final strategies = [
        FeatureRolloutStrategy(
          id: 's1',
          value: true,
          attributes: [
            _attr(RolloutStrategyAttributeConditional.GREATER_EQUALS, [_t]),
          ],
        ),
      ];
      bool matched() => apply
          .apply(
            strategies,
            'chago',
            'fv-chago',
            const MapStrategyContext({'userkey': 'fiona'}),
          )
          .matched;
      expect(matched(), false);
      now = DateTime.utc(2026, 12, 1, 9);
      expect(matched(), true);
    });
  });

  // well_known_attributes.strategy_vectors
  group('fhubWhenActive combined', () {
    final at = _attr(RolloutStrategyAttributeConditional.GREATER_EQUALS, [_t]);
    final nz = _attr(
      RolloutStrategyAttributeConditional.EQUALS,
      ['nz'],
      fieldName: 'country',
      type: RolloutStrategyFieldType.STRING,
    );

    test('with a country', () {
      expect(
        _applies([at, nz], '2026-12-02T00:00:00Z', context: {'country': 'nz'}),
        true,
      );
      expect(
        _applies([at, nz], '2026-12-02T00:00:00Z', context: {'country': 'au'}),
        false,
        reason: 'the country does not match',
      );
      expect(
        _applies([at, nz], '2026-11-30T00:00:00Z', context: {'country': 'nz'}),
        false,
        reason: 'the time is not reached',
      );
    });

    test('with a percentage', () {
      expect(
        _applies(
          [at],
          '2026-12-02T00:00:00Z',
          context: {'userkey': 'fred'},
          percentage: 1000000,
        ),
        true,
      );
      expect(
        _applies(
          [at],
          '2026-11-30T00:00:00Z',
          context: {'userkey': 'fred'},
          percentage: 1000000,
        ),
        false,
      );
    });

    test('an unsupported conditional is not skipped', () {
      expect(
        _applies(
          [
            _attr(RolloutStrategyAttributeConditional.INCLUDES, [_t]),
            nz,
          ],
          '2027-01-01T00:00:00Z',
          context: {'country': 'nz'},
        ),
        false,
      );
    });
  });

  // matchers.utc_vectors (the machine's time zone plays no part)
  group('date-times are UTC', () {
    bool match(
      RolloutStrategyFieldType type,
      RolloutStrategyAttributeConditional conditional,
      List<Object?> values,
      Object supplied,
    ) {
      final attr = _attr(conditional, values, fieldName: 'f', type: type);
      return const MatcherRegistry().findMatcher(attr).match(supplied, attr);
    }

    const dt = RolloutStrategyFieldType.DATETIME;
    const date = RolloutStrategyFieldType.DATE;
    const eq = RolloutStrategyAttributeConditional.EQUALS;

    test('no offset is UTC', () {
      expect(
        match(dt, eq, ['2021-05-05T10:00:00Z'], '2021-05-05T10:00:00'),
        true,
      );
      expect(
        match(dt, eq, ['2021-05-05T10:00:00'], '2021-05-05T10:00:00Z'),
        true,
        reason: 'a value without an offset is UTC too',
      );
      expect(
        match(dt, RolloutStrategyAttributeConditional.GREATER, [
          '2021-05-05T10:00:00Z',
        ], '2021-05-05T10:00:01.5'),
        true,
      );
      expect(match(date, eq, ['2020-06-15'], '2020-06-15T23:30:00'), true);
    });

    test('only ISO-8601 is a date-time', () {
      expect(
        match(dt, eq, ['2021-05-05T10:00:00Z'], '2021-05-05 10:00:00Z'),
        false,
      );
      expect(match(date, eq, ['2020-06-15'], 1592179200000), false);
    });

    test('an offset is converted to UTC', () {
      expect(
        match(dt, eq, ['2021-05-05T10:00:00Z'], '2021-05-05T22:00:00+12:00'),
        true,
      );
    });
  });
}
