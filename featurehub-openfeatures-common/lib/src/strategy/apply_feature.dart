import 'package:featurehub_client_api/api.dart';

import 'js_compat.dart';
import 'matchers.dart';
import 'murmur3.dart';
import 'strategy_context.dart';

/// Places a context in a percentage rollout.
abstract interface class PercentageCalculator {
  /// A value from 0 to 999999 (a percentage with four decimal places).
  int determineClientPercentage(String percentageText, String featureId);
}

/// The FeatureHub percentage calculation used by every FeatureHub SDK, so
/// that a user is in the same rollout bucket on every platform.
class Murmur3PercentageCalculator implements PercentageCalculator {
  static const _maxPercentage = 1000000;

  const Murmur3PercentageCalculator();

  @override
  int determineClientPercentage(String percentageText, String featureId) {
    final result = murmur3String(percentageText + featureId, 0);
    return (result / 4294967296 * _maxPercentage).floor();
  }
}

/// The result of applying a feature's rollout strategies to a context.
class Applied {
  /// True if a strategy matched, in which case [value] replaces the
  /// feature's default value.
  final bool matched;
  final dynamic value;

  /// The id of the strategy that matched.
  final String? strategyId;

  /// True if the strategy that matched is a percentage rollout.
  final bool split;

  const Applied(
    this.matched,
    this.value,
    this.strategyId, {
    this.split = false,
  });

  static const notMatched = Applied(false, null, null);
}

DateTime _systemClock() => DateTime.now();

/// Evaluates a feature's rollout strategies against a context, as the
/// FeatureHub server does for server-evaluated API keys. Used for
/// client-evaluated API keys (those containing `*`).
///
/// [clock] gives the current time (by default the machine's), which
/// `fhubWhenActive` compares against and which a DATE or DATETIME attribute
/// the context does not supply uses: tests can fix it.
class ApplyFeature {
  final PercentageCalculator _percentageCalculator;
  final MatcherRepository _matcherRepository;
  final DateTime Function() _clock;

  const ApplyFeature({
    this._percentageCalculator = const Murmur3PercentageCalculator(),
    this._matcherRepository = const MatcherRegistry(),
    this._clock = _systemClock,
  });

  /// Applies [strategies] (in order) for the feature value [featureValueId],
  /// at [now] (by default the clock's time, read once for the call).
  /// Returns the first strategy that matches, or [Applied.notMatched].
  Applied apply(
    List<FeatureRolloutStrategy>? strategies,
    String key,
    String featureValueId,
    StrategyContext? context, {
    DateTime? now,
  }) {
    if (context == null || strategies == null || strategies.isEmpty) {
      return Applied.notMatched;
    }

    // the clock is read once for the evaluation, and only if needed
    DateTime? clockReading;
    DateTime clock() => clockReading ??= (now ?? _clock()).toUtc();

    int? percentage;
    String? percentageKey;
    final basePercentage = <String, int>{};
    final defaultPercentageKey = context.defaultPercentageKey();

    for (final rsi in strategies) {
      final rsiPercentage = rsi.percentage;
      final hasAttributes = rsi.attributes.isNotEmpty;

      if (rsiPercentage != null &&
          rsiPercentage != 0 &&
          (_jsTruthy(defaultPercentageKey) ||
              (rsi.percentageAttributes?.isNotEmpty ?? false))) {
        final newPercentageKey = determinePercentageKey(
          context,
          rsi.percentageAttributes,
        );

        basePercentage.putIfAbsent(newPercentageKey, () => 0);
        final basePercentageVal = basePercentage[newPercentageKey]!;

        // if we have changed the key, or have never calculated it, calculate it
        if (percentage == null || newPercentageKey != percentageKey) {
          percentageKey = newPercentageKey;
          percentage = _percentageCalculator.determineClientPercentage(
            percentageKey,
            featureValueId,
          );
        }

        final useBasePercentage = hasAttributes ? 0 : basePercentageVal;

        // if the user's percentage is within this strategy's percentage
        if (percentage <= useBasePercentage + rsiPercentage) {
          if (hasAttributes) {
            if (_matchAttribute(context, rsi, clock)) {
              return Applied(true, rsi.value, rsi.id, split: true);
            }
          } else {
            return Applied(true, rsi.value, rsi.id, split: true);
          }
        }

        // this was only a percentage and had no other attributes
        if (!hasAttributes) {
          basePercentage[percentageKey!] =
              basePercentage[percentageKey]! + rsiPercentage;
        }
      }

      if ((rsiPercentage == null || rsiPercentage == 0) &&
          hasAttributes &&
          _matchAttribute(context, rsi, clock)) {
        // nothing to do with a percentage
        return Applied(true, rsi.value, rsi.id);
      }
    }

    return Applied.notMatched;
  }

  static const _fhubWhenActive = 'fhubwhenactive';

  /// The key used for the percentage calculation: the context's default
  /// percentage key, or the named attributes joined with `$`.
  static String determinePercentageKey(
    StrategyContext context,
    List<String>? percentageAttributes,
  ) {
    if (percentageAttributes == null || percentageAttributes.isEmpty) {
      // only called when a default key exists or attributes were given
      return context.defaultPercentageKey()!;
    }

    // as in JS, `getAttr(pa) || "<none>"`: any falsy value is "<none>"
    return percentageAttributes
        .map((pa) {
          final value = context.getAttr(pa);
          return _jsTruthy(value) ? _caToString(value)! : '<none>';
        })
        .join(r'$');
  }

  /// JavaScript truthiness: null, false, 0, NaN and '' are falsy.
  static bool _jsTruthy(Object? value) {
    if (value == null) return false;
    if (value is bool) return value;
    if (value is num) return value != 0 && !value.isNaN;
    if (value is String) return value.isNotEmpty;
    return true;
  }

  static String? _caToString(Object? value) {
    if (value == null) return null;
    if (value is List) {
      return value.map((v) => jsToString(v as Object)).join(',');
    }
    return jsToString(value);
  }

  /// The `fhubWhenActive` attribute ([attr], whose type is ignored)
  /// compared with the clock: true if the conditional holds between the
  /// clock and its date-time, both to the second
  /// (rollout-strategies.yaml algorithm.well_known_attributes.fhubWhenActive).
  static bool whenActive(FeatureRolloutStrategyAttribute attr, DateTime now) {
    final clock = truncateToSecond(now.toUtc());
    final times = [
      for (final v in attr.values)
        if (v != null)
          if (parseIsoDateTime(v as Object) case final t?) truncateToSecond(t),
    ];
    if (times.isEmpty) return false;
    return switch (attr.conditional) {
      RolloutStrategyAttributeConditional.EQUALS => times.any(
        (t) => clock == t,
      ),
      RolloutStrategyAttributeConditional.NOT_EQUALS => !times.any(
        (t) => clock == t,
      ),
      RolloutStrategyAttributeConditional.GREATER => times.any(clock.isAfter),
      RolloutStrategyAttributeConditional.GREATER_EQUALS => times.any(
        (t) => !clock.isBefore(t),
      ),
      RolloutStrategyAttributeConditional.LESS => times.any(clock.isBefore),
      RolloutStrategyAttributeConditional.LESS_EQUALS => times.any(
        (t) => !clock.isAfter(t),
      ),
      // INCLUDES, EXCLUDES, STARTS_WITH, ENDS_WITH, REGEX: never a match
      _ => false,
    };
  }

  bool _matchAttribute(
    StrategyContext context,
    FeatureRolloutStrategy rsi,
    DateTime Function() now,
  ) {
    for (final attr in rsi.attributes) {
      // strategy-only: the clock, never the context
      if (attr.fieldName.toLowerCase() == _fhubWhenActive) {
        if (!whenActive(attr, now())) return false;
        continue;
      }

      Object? suppliedValues = context.getAttr(attr.fieldName);

      if (suppliedValues == null ||
          (suppliedValues is List &&
              suppliedValues.isEmpty &&
              attr.fieldName.toLowerCase() == 'now')) {
        switch (attr.type) {
          case RolloutStrategyFieldType.DATE:
            suppliedValues = [now().toIso8601String().substring(0, 10)];
          case RolloutStrategyFieldType.DATETIME:
            suppliedValues = [isoDateTimeToSecond(now())];
          default:
            break;
        }
      }

      if (suppliedValues == null) {
        return false;
      }

      final comparedValues = suppliedValues is List
          ? suppliedValues.where((v) => v != null).cast<Object>().toList()
          : <Object>[suppliedValues];

      // The TypeScript SDK skips an EQUALS attribute whose values are null when
      // the context supplies an empty list. The Dart API model turns null
      // values into an empty list, so the two cannot be told apart here; an
      // empty supplied list never matches, as in TypeScript for `values: []`.
      if (comparedValues.isEmpty) {
        return false;
      }

      final matcher = _matcherRepository.findMatcher(attr);
      if (!comparedValues.any((sv) => matcher.match(sv, attr))) {
        return false;
      }
    }

    return true;
  }
}
