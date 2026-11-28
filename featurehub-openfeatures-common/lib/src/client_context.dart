import 'package:featurehub_client_api/api.dart';

import 'strategy/strategy_context.dart';

typedef ClientContextChangedHandler = Future<void> Function(String? header);

/// The context features are evaluated for: sent to the server for
/// server-evaluated API keys, and used to apply rollout strategies locally for
/// client-evaluated API keys.
class ClientContext implements StrategyContext {
  final Map<String, List<String>> _attributes = <String, List<String>>{};
  final _handlers = <ClientContextChangedHandler>[];

  /// Allows to set User Key context when using rollout strategy with User Key rule.
  /// userKey can be anything that identifies your user, e.g userId, email, etc.
  /// @param userKey
  /// returns [ClientContext]
  ClientContext userKey(String userkey) {
    _attributes['userkey'] = [userkey];
    return this;
  }

  /// For Percentage rule to work Context either needs userKey or sessionKey.
  /// If userKey is not provided, sessionKey can be used instead
  /// @param sessionKey
  /// returns [ClientContext]
  ClientContext sessionKey(String sessionKey) {
    _attributes['session'] = [sessionKey];
    return this;
  }

  /// Allows to set Country context when using rollout strategy with Country rule.
  /// @param countryName name of the country provided as enum from [StrategyAttributeCountryName]
  /// returns [ClientContext]
  ClientContext country(StrategyAttributeCountryName countryName) {
    _attributes['country'] = [countryName.name!];
    return this;
  }

  /// Allows to set Device context when using rollout strategy with Device rule.
  /// @param device name of the device provided as enum from [StrategyAttributeDeviceName]
  /// returns [ClientContext]
  ClientContext device(StrategyAttributeDeviceName device) {
    _attributes['device'] = [device.name!];
    return this;
  }

  /// Allows to set Platform context when using rollout strategy with Platform rule.
  /// @param platform name of the platform provided as enum from [StrategyAttributePlatformName]
  /// returns [ClientContext]
  ClientContext platform(StrategyAttributePlatformName platform) {
    _attributes['platform'] = [platform.name!];
    return this;
  }

  /// Allows to set Version context when using rollout strategy with Version rule.
  /// @param version Semantic version
  /// returns [ClientContext]
  ClientContext version(String version) {
    _attributes['version'] = [version];
    return this;
  }

  /// Allows to set Custom context attribute when using rollout strategy with Custom rule.
  /// @param key Name of the Custom rule
  /// @param value Value of the Custom rule
  /// returns [ClientContext]
  ClientContext attr(String key, String value) {
    _attributes[key] = [value];
    return this;
  }

  /// Allows to set a Custom context attribute with a list of values when using rollout strategy with Custom rule.
  /// @param key Name of the Custom rule
  /// @param values Values of the Custom rule
  /// returns [ClientContext]
  ClientContext attrs(String key, List<String> values) {
    _attributes[key] = values;
    return this;
  }

  /// Call this method to clear Context
  ClientContext clear() {
    _attributes.clear();
    return this;
  }

  @override
  Object? getAttr(String key) => _attributes[key];

  /// The attributes, by key (read-only).
  Map<String, List<String>> get attributes => Map.unmodifiable(_attributes);

  @override
  String? defaultPercentageKey() =>
      _attributes['session']?.join(',') ?? _attributes['userkey']?.join(',');

  /// Call this method to rebuild Context
  void build() {
    final header = generateHeader();
    for (var handler in _handlers) {
      handler(header);
    }
  }

  /// The context in FeatureHub's `x-featurehub` header form, or null if
  /// there are no attributes: for each attribute with values,
  /// `encode(key)=encode(values joined by ",")`, sorted, joined with ",".
  /// Keys and values are both encoded as JavaScript's `encodeURIComponent`
  /// does, so a "," or "=" in either cannot be confused with the separators.
  String? generateHeader() {
    final params = [
      for (final MapEntry(:key, :value) in _attributes.entries)
        if (value.isNotEmpty)
          '${Uri.encodeComponent(key)}=${Uri.encodeComponent(value.join(','))}',
    ]..sort();
    return params.isEmpty ? null : params.join(',');
  }

  Future<Function> registerChangeHandler(
    ClientContextChangedHandler handler,
  ) async {
    _handlers.add(
      handler,
    ); // have to do this first in case other code triggers before this callback

    try {
      await handler(generateHeader());
      return () => {_handlers.remove(handler)};
    } catch (e) {
      _handlers.remove(handler);
      return () => {};
    }
  }
}
