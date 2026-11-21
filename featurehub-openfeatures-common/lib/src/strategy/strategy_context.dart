import 'js_compat.dart';

/// The attributes a feature's rollout strategies are evaluated against.
///
/// Attribute values may be a [String], [num], [bool] or [DateTime], or a
/// [List] of those (any value in the list may match).
abstract interface class StrategyContext {
  /// The value of attribute [key], or null if it is not set. FeatureHub's
  /// well known attributes are `userkey`, `session`, `country`, `device`,
  /// `platform` and `version`.
  Object? getAttr(String key);

  /// The key used to place this context in a percentage rollout when a
  /// strategy does not name its own percentage attributes: the `session`
  /// attribute if set, otherwise the `userkey`.
  String? defaultPercentageKey();
}

/// A [StrategyContext] backed by a map of attributes.
class MapStrategyContext implements StrategyContext {
  final Map<String, Object?> attributes;

  const MapStrategyContext(this.attributes);

  @override
  Object? getAttr(String key) => attributes[key];

  @override
  String? defaultPercentageKey() =>
      _asString(attributes['session']) ?? _asString(attributes['userkey']);

  static String? _asString(Object? value) {
    if (value == null) return null;
    if (value is List) {
      return value.map((v) => jsToString(v as Object)).join(',');
    }
    return jsToString(value);
  }
}
