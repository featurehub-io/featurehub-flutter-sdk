import 'package:featurehub_openfeatures_common/featurehub_openfeatures_common.dart';

/// Reading the provider's settings from environment variables, as the
/// FeatureHub protocol specification defines them
/// (providers.environment_variables).
///
/// A variable counts as set when it is present and not empty after
/// trimming. Durations are a single number and a lowercase unit (`ms`, `s`,
/// `m` or `h`), or `0`: `30s`, `500ms`, `1.5m`. A bare number such as `30`
/// is not one (seconds to one SDK, milliseconds to another), nor is a
/// compound value such as `1m30s`. A value that is not valid is an
/// [ArgumentError], whichever variable it is in.
class FeatureHubEnvironment {
  final Map<String, String> _env;

  FeatureHubEnvironment(this._env);

  static final _duration = RegExp(r'^(0|[0-9]+(\.[0-9]+)?(ms|s|m|h))$');
  static final _number = RegExp(r'^[0-9]+(\.[0-9]+)?$');

  /// The value of [name], trimmed, or null if it is not set.
  String? operator [](String name) {
    final value = _env[name]?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  /// [name] as a duration, or null if it is not set.
  Duration? duration(String name) {
    final value = this[name];
    if (value == null) return null;
    final parsed = parseDuration(value);
    if (parsed == null) {
      throw ArgumentError(
        '$name must be a number followed by a unit (ms, s, m or h), such as '
        '30s or 500ms, or 0; not "$value"',
      );
    }
    return parsed;
  }

  /// [name] as a number of at least [minimum], or null if it is not set.
  double? number(String name, {double minimum = 0}) {
    final value = this[name];
    if (value == null) return null;
    final parsed = _number.hasMatch(value) ? double.parse(value) : null;
    if (parsed == null || parsed < minimum) {
      throw ArgumentError(
        '$name must be a number of at least $minimum, not "$value"',
      );
    }
    return parsed;
  }

  /// The mode [name] chooses (`active`, `passive` or `streaming`, in any
  /// case), or null if it is not set.
  FeatureHubUpdateMode? mode(String name) {
    final value = this[name];
    if (value == null) return null;
    return switch (value.toLowerCase()) {
      'active' => FeatureHubUpdateMode.activePolling,
      'passive' => FeatureHubUpdateMode.passivePolling,
      'streaming' => FeatureHubUpdateMode.streaming,
      _ => throw ArgumentError(
        '$name must be active, passive or streaming, not "$value"',
      ),
    };
  }

  /// [value] as a duration (see [FeatureHubEnvironment]), or null if it is
  /// not one.
  static Duration? parseDuration(String value) {
    final match = _duration.firstMatch(value);
    if (match == null) return null;
    if (value == '0') return Duration.zero;
    final unit = match[3]!;
    final amount = double.parse(value.substring(0, value.length - unit.length));
    final microseconds = switch (unit) {
      'ms' => Duration.microsecondsPerMillisecond,
      's' => Duration.microsecondsPerSecond,
      'm' => Duration.microsecondsPerMinute,
      _ => Duration.microsecondsPerHour,
    };
    return Duration(microseconds: (amount * microseconds).round());
  }
}
