// reads its fixture with dart:io (test/web/web_test.dart checks murmur3 in
// browsers)
@TestOn('vm')
library;

// Checks the Dart strategy evaluation against results produced by the
// TypeScript SDK (see fixtures/generate.ts.txt), so that features evaluate
// identically on every FeatureHub platform.
import 'dart:convert';
import 'dart:io';

import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_openfeatures_common/featurehub_openfeatures_common.dart';
import 'package:test/test.dart';

void main() {
  final golden =
      jsonDecode(
            File(
              'test/strategy/fixtures/typescript_golden.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;

  test('murmur3 matches the murmurhash npm package', () {
    for (final c in golden['murmur'] as List) {
      expect(murmur3String(c['key'] as String), c['hash'], reason: c['key']);
    }
  });

  test('percentages match', () {
    const calc = Murmur3PercentageCalculator();
    for (final c in golden['percentage'] as List) {
      expect(
        calc.determineClientPercentage(c['key'] as String, c['id'] as String),
        c['value'],
        reason: c['key'],
      );
    }
  });

  test('matchers match', () {
    const registry = MatcherRegistry();
    final failures = <String>[];
    for (final c in golden['matchers'] as List) {
      final attr = FeatureRolloutStrategyAttribute(
        conditional: RolloutStrategyAttributeConditionalExtension.type(
          c['conditional'] as String,
        )!,
        type: RolloutStrategyFieldTypeExtension.type(c['type'] as String)!,
        fieldName: 'f',
        values: List<dynamic>.from(c['values'] as List),
      );
      final actual = registry
          .findMatcher(attr)
          .match(c['supplied'] as Object, attr);
      if (actual != c['result']) {
        failures.add(
          '${c['type']} ${c['conditional']} ${jsonEncode(c['values'])} '
          'supplied ${jsonEncode(c['supplied'])}: expected ${c['result']}, '
          'got $actual',
        );
      }
    }
    expect(failures, isEmpty, reason: failures.take(20).join('\n'));
  });

  test('apply matches', () {
    const apply = ApplyFeature();
    final failures = <String>[];
    for (final c in golden['apply'] as List) {
      final strategies = (c['strategies'] as List)
          .map(
            (s) => FeatureRolloutStrategy.fromJson(
              Map<String, dynamic>.from(s as Map),
            ),
          )
          .toList();
      final context = MapStrategyContext(
        Map<String, Object?>.from(c['context'] as Map),
      );
      final applied = apply.apply(
        strategies,
        'key',
        c['featureValueId'] as String,
        context,
      );
      if (applied.matched != c['matched'] ||
          applied.value != c['value'] ||
          applied.strategyId != c['strategyId']) {
        failures.add(
          '${c['name']} ${jsonEncode(c['context'])}: expected '
          '${c['matched']}/${c['value']}/${c['strategyId']}, got '
          '${applied.matched}/${applied.value}/${applied.strategyId}',
        );
      }
    }
    expect(failures, isEmpty, reason: failures.take(20).join('\n'));
  });
}
