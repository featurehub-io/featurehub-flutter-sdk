import 'package:featurehub_client_api/api.dart';

import 'js_compat.dart';
import 'netmask.dart';

/// Matches one supplied context value against a strategy attribute.
abstract interface class StrategyMatcher {
  bool match(Object suppliedValue, FeatureRolloutStrategyAttribute attr);
}

/// Finds the [StrategyMatcher] for a strategy attribute's field type.
abstract interface class MatcherRepository {
  StrategyMatcher findMatcher(FeatureRolloutStrategyAttribute attr);
}

typedef _Cond = RolloutStrategyAttributeConditional;

List<String> _stringValues(List<dynamic> values) =>
    values.where((v) => v != null).map((v) => jsToString(v as Object)).toList();

bool _regexMatch(String value, String pattern) {
  try {
    return RegExp(pattern).hasMatch(value);
  } on FormatException {
    return false;
  }
}

class BooleanMatcher implements StrategyMatcher {
  const BooleanMatcher();

  static bool _toBool(Object v) => v is bool ? v : jsToString(v) == 'true';

  @override
  bool match(Object suppliedValue, FeatureRolloutStrategyAttribute attr) {
    final values = attr.values
        .where((v) => v != null)
        .map((v) => _toBool(v as Object))
        .toList();

    if (values.isEmpty) return false;

    final val = _toBool(suppliedValue);

    // only the first value is relevant
    if (attr.conditional == _Cond.EQUALS) return val == values[0];
    if (attr.conditional == _Cond.NOT_EQUALS) return val != values[0];

    return false;
  }
}

class StringMatcher implements StrategyMatcher {
  const StringMatcher();

  @override
  bool match(Object suppliedValue, FeatureRolloutStrategyAttribute attr) =>
      matchString(jsToString(suppliedValue), attr);

  bool matchString(String suppliedValue, FeatureRolloutStrategyAttribute attr) {
    final vals = attrToStringValues(attr);

    switch (attr.conditional) {
      case _Cond.EQUALS:
        return vals.contains(suppliedValue);
      case _Cond.ENDS_WITH:
        return vals.any((v) => suppliedValue.endsWith(v));
      case _Cond.STARTS_WITH:
        return vals.any((v) => suppliedValue.startsWith(v));
      case _Cond.GREATER:
        return vals.any((v) => suppliedValue.compareTo(v) > 0);
      case _Cond.GREATER_EQUALS:
        return vals.any((v) => suppliedValue.compareTo(v) >= 0);
      case _Cond.LESS:
        return vals.any((v) => suppliedValue.compareTo(v) < 0);
      case _Cond.LESS_EQUALS:
        return vals.any((v) => suppliedValue.compareTo(v) <= 0);
      case _Cond.NOT_EQUALS:
        return !vals.contains(suppliedValue);
      case _Cond.INCLUDES:
        return vals.any((v) => suppliedValue.contains(v));
      case _Cond.EXCLUDES:
        return !vals.any((v) => suppliedValue.contains(v));
      case _Cond.REGEX:
        return vals.any((v) => _regexMatch(suppliedValue, v));
    }
  }

  /// overridden by the date matchers
  List<String> attrToStringValues(FeatureRolloutStrategyAttribute attr) =>
      _stringValues(attr.values);
}

final _dateOnly = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

/// Parses a supplied date the way JavaScript's `new Date(string)` does for
/// ISO formats: a date-only value is UTC, a date-time without an offset is
/// local time. Returns the instant in UTC, or null if it cannot be parsed.
DateTime? _parseDate(Object value) {
  if (value is DateTime) return value.toUtc();
  if (value is! String) return null;
  final dateOnly = _dateOnly.firstMatch(value);
  if (dateOnly != null) {
    return DateTime.utc(
      int.parse(dateOnly.group(1)!),
      int.parse(dateOnly.group(2)!),
      int.parse(dateOnly.group(3)!),
    );
  }
  return DateTime.tryParse(value)?.toUtc();
}

String _isoDate(DateTime utc) => utc.toIso8601String().substring(0, 10);

String _isoDateTime(DateTime utc) =>
    '${utc.toIso8601String().substring(0, 19)}Z';

class DateMatcher extends StringMatcher {
  const DateMatcher();

  @override
  bool match(Object suppliedValue, FeatureRolloutStrategyAttribute attr) {
    final parsed = _parseDate(suppliedValue);
    if (parsed == null) return false;
    return matchString(_isoDate(parsed), attr);
  }

  @override
  List<String> attrToStringValues(FeatureRolloutStrategyAttribute attr) => attr
      .values
      .where((v) => v != null)
      .map((v) => v is DateTime ? _isoDate(v.toUtc()) : jsToString(v as Object))
      .toList();
}

class DateTimeMatcher extends StringMatcher {
  const DateTimeMatcher();

  @override
  bool match(Object suppliedValue, FeatureRolloutStrategyAttribute attr) {
    final parsed = _parseDate(suppliedValue);
    if (parsed == null) return false;
    return matchString(_isoDateTime(parsed), attr);
  }

  @override
  List<String> attrToStringValues(FeatureRolloutStrategyAttribute attr) => attr
      .values
      .where((v) => v != null)
      .map(
        (v) =>
            v is DateTime ? _isoDateTime(v.toUtc()) : jsToString(v as Object),
      )
      .toList();
}

class NumberMatcher implements StrategyMatcher {
  const NumberMatcher();

  @override
  bool match(Object comparedValue, FeatureRolloutStrategyAttribute attr) {
    // a supplied value that is not a number never matches, whatever the
    // conditional; values that are not numbers are ignored
    final suppliedValue = strictNumber(comparedValue);
    if (suppliedValue == null) return false;

    final valid = attr.values.where((v) => strictNumber(v) != null).toList();
    final nums = valid.map((v) => strictNumber(v)!).toList();
    final asString = jsToString(suppliedValue);
    final strings = _stringValues(valid);

    switch (attr.conditional) {
      case _Cond.EQUALS:
        return nums.any((v) => v == suppliedValue);
      case _Cond.GREATER:
        return nums.any((v) => suppliedValue > v);
      case _Cond.GREATER_EQUALS:
        return nums.any((v) => suppliedValue >= v);
      case _Cond.LESS:
        return nums.any((v) => suppliedValue < v);
      case _Cond.LESS_EQUALS:
        return nums.any((v) => suppliedValue <= v);
      case _Cond.NOT_EQUALS:
        return !nums.any((v) => suppliedValue == v);
      // the below are string comparisons
      case _Cond.INCLUDES:
        return strings.any((v) => asString.contains(v));
      case _Cond.EXCLUDES:
        return !strings.any((v) => asString.contains(v));
      case _Cond.REGEX:
        return strings.any((v) => _regexMatch(asString, v));
      case _Cond.ENDS_WITH:
        return strings.any((v) => asString.endsWith(v));
      case _Cond.STARTS_WITH:
        return strings.any((v) => asString.startsWith(v));
    }
  }
}

class SemanticVersionMatcher implements StrategyMatcher {
  const SemanticVersionMatcher();

  @override
  bool match(Object comparedValue, FeatureRolloutStrategyAttribute attr) {
    final vals = _stringValues(attr.values);
    final suppliedValue = jsToString(comparedValue);

    switch (attr.conditional) {
      case _Cond.INCLUDES:
      case _Cond.EQUALS:
        return vals.any((v) => semverCompare(suppliedValue, v) == 0);
      case _Cond.GREATER:
        return vals.any((v) => semverCompare(suppliedValue, v) > 0);
      case _Cond.GREATER_EQUALS:
        return vals.any((v) => semverCompare(suppliedValue, v) >= 0);
      case _Cond.LESS:
        return vals.any((v) => semverCompare(suppliedValue, v) < 0);
      case _Cond.LESS_EQUALS:
        return vals.any((v) => semverCompare(suppliedValue, v) <= 0);
      case _Cond.NOT_EQUALS:
      case _Cond.EXCLUDES:
        return vals.any((v) => semverCompare(suppliedValue, v) != 0);
      case _Cond.ENDS_WITH:
      case _Cond.STARTS_WITH:
      case _Cond.REGEX:
        return false;
    }
  }
}

class IPNetworkMatcher implements StrategyMatcher {
  const IPNetworkMatcher();

  @override
  bool match(Object comparedValue, FeatureRolloutStrategyAttribute attr) {
    final vals = _stringValues(attr.values);
    final ip = jsToString(comparedValue);

    // an invalid address or network never matches
    try {
      switch (attr.conditional) {
        case _Cond.EQUALS:
        case _Cond.INCLUDES:
          return vals.any((v) => Netmask(v).contains(ip));
        case _Cond.NOT_EQUALS:
        case _Cond.EXCLUDES:
          return !vals.any((v) => Netmask(v).contains(ip));
        default:
          return false;
      }
    } on FormatException {
      return false;
    }
  }
}

class MatcherRegistry implements MatcherRepository {
  const MatcherRegistry();

  @override
  StrategyMatcher findMatcher(FeatureRolloutStrategyAttribute attr) {
    switch (attr.type) {
      case RolloutStrategyFieldType.STRING:
        return const StringMatcher();
      case RolloutStrategyFieldType.SEMANTIC_VERSION:
        return const SemanticVersionMatcher();
      case RolloutStrategyFieldType.NUMBER:
        return const NumberMatcher();
      case RolloutStrategyFieldType.DATE:
        return const DateMatcher();
      case RolloutStrategyFieldType.DATETIME:
        return const DateTimeMatcher();
      case RolloutStrategyFieldType.BOOLEAN:
        return const BooleanMatcher();
      case RolloutStrategyFieldType.IP_ADDRESS:
        return const IPNetworkMatcher();
    }
  }
}
