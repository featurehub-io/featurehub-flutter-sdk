import 'package:featurehub_client_api/api.dart'
    show StrategyAttributeWellKnownNamesExtension;

import '../client_context.dart';
import '../strategy/js_compat.dart';
import '../strategy/strategy_context.dart';

/// Raised when an OpenFeature evaluation context contains a value FeatureHub
/// cannot represent (a nested object, or a list containing one).
class InvalidContextException implements Exception {
  final String key;

  InvalidContextException(this.key);

  String get message =>
      "Context attribute '$key' is an object or contains nested objects; "
      'FeatureHub attributes must be strings, numbers, booleans, dates, or '
      'lists of those.';

  @override
  String toString() => 'InvalidContextException: $message';
}

/// The strategy-only attribute name: FeatureHub sets it in a strategy, and
/// the application can never supply it, so a context key with this name (in
/// any case) is dropped.
const fhubWhenActiveKey = 'fhubWhenActive';

/// Attribute keys FeatureHub treats specially (recognised case-insensitively,
/// written lowercase): the `StrategyAttributeWellKnownNames` of the FeatureHub
/// Edge API definition (device, country, platform, userkey, session, version),
/// but for [fhubWhenActiveKey], which is not a context key.
final _featureHubKeys = {
  for (final name in StrategyAttributeWellKnownNamesExtension.fromMap.keys)
    if (name.toLowerCase() != fhubWhenActiveKey.toLowerCase())
      name.toLowerCase(),
};

/// A date-time as it is sent: UTC ISO-8601 to the second,
/// `YYYY-MM-DDTHH:MM:SSZ` (any fraction of a second dropped).
String wireDateTime(DateTime value) =>
    '${value.toUtc().toIso8601String().substring(0, 19)}Z';

/// An OpenFeature evaluation context mapped onto FeatureHub's context model.
class MappedContext {
  /// FeatureHub's user key (OpenFeature's `targetingKey`).
  final String? userkey;

  /// The remaining attributes, keyed by FeatureHub attribute key. Values are
  /// a [String], [num], [bool] or [DateTime], or a list of those.
  final Map<String, Object> attributes;

  const MappedContext(this.userkey, this.attributes);

  /// All attributes including `userkey`, as used for strategy evaluation.
  Map<String, Object> get asAttributes => {'userkey': ?userkey, ...attributes};

  /// A [StrategyContext] for evaluating client-evaluated features locally.
  StrategyContext get strategyContext => MapStrategyContext(asAttributes);

  /// Replaces [context]'s attributes with these (for server-evaluated keys,
  /// whose context is sent to the server). Does not call [ClientContext.build].
  void applyTo(ClientContext context) {
    context.clear();
    asAttributes.forEach((key, value) {
      context.attrs(key, _stringValues(value));
    });
  }

  /// The `x-featurehub` header (and context signature) for this context: the
  /// same format [ClientContext.generateHeader] produces.
  String? get header {
    final context = ClientContext();
    applyTo(context);
    return context.generateHeader();
  }

  static List<String> _stringValues(Object value) {
    if (value is List) return value.map((v) => _toWire(v as Object)).toList();
    return [_toWire(value)];
  }

  static String _toWire(Object value) =>
      value is DateTime ? wireDateTime(value) : jsToString(value);
}

bool _isPrimitive(Object? v) =>
    v is String || v is num || v is bool || v is DateTime;

/// Maps an OpenFeature evaluation context (in map form, as passed to
/// providers, with the targeting key under `targetingKey`) onto FeatureHub's
/// context model:
///
/// - `targetingKey` (or `userkey`) becomes FeatureHub's `userkey`, the
///   default percentage rollout key.
/// - FeatureHub's well-known keys, the `StrategyAttributeWellKnownNames` of
///   the Edge API definition (`device`, `country`, `platform`, `session`,
///   `version`), are recognised case-insensitively and written lowercase.
/// - `fhubWhenActive` (in any case) is dropped: it is a strategy-only name,
///   and its time comes from the clock, never the context.
/// - A date-time is sent as UTC ISO-8601 to the second ([wireDateTime]).
/// - Everything else passes through as a custom attribute; null values are
///   skipped.
///
/// Throws an [InvalidContextException] for a value that cannot be represented.
MappedContext mapEvaluationContext(Map<String, Object?>? context) {
  final attributes = <String, Object>{};
  String? userkey;

  if (context != null) {
    for (final entry in context.entries) {
      final key = entry.key;
      final value = entry.value;
      if (value == null) continue;

      final lower = key.toLowerCase();
      if (lower == fhubWhenActiveKey.toLowerCase()) continue;
      if (lower == 'targetingkey' || lower == 'userkey') {
        userkey = value is DateTime ? wireDateTime(value) : jsToString(value);
      } else if (_isPrimitive(value) ||
          (value is List && value.every(_isPrimitive))) {
        attributes[_featureHubKeys.contains(lower) ? lower : key] = value;
      } else {
        throw InvalidContextException(key);
      }
    }
  }

  return MappedContext(userkey, attributes);
}
