import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_client_sdk/usage/usage.dart';
import 'package:featurehub_client_sdk/usage/usage_event.dart';
import 'package:featurehub_usage_api/usage.dart';
import 'package:meta/meta.dart';

import 'features.dart';
import 'src/internal_features.dart';
import 'src/internal_repository.dart';

class ClientContext {
  @protected
  final Map<String, List<String>> attributes = <String, List<String>>{};
  @protected
  final InternalFeatureRepository repo;

  ClientContext(this.repo);

  /// Allows to set User Key context when using rollout strategy with User Key rule.
  /// userKey can be anything that identifies your user, e.g userId, email, etc.
  /// @param userKey
  /// returns [ClientContext]
  ClientContext userKey(String userkey) {
    attributes['userkey'] = [userkey];
    return this;
  }

  /// For Percentage rule to work Context either needs userKey or sessionKey.
  /// If userKey is not provided, sessionKey can be used instead
  /// @param sessionKey
  /// returns [ClientContext]
  ClientContext sessionKey(String sessionKey) {
    attributes['session'] = [sessionKey];
    return this;
  }

  String? getAttr(String key) => attributes.containsKey(key) ? attributes[key]![0] : null;

  String? usageUserKey() {
    return getAttr('session') ?? getAttr('userkey') ?? null;
  }

  /// Allows to set Country context when using rollout strategy with Country rule.
  /// @param countryName name of the country provided as enum from [StrategyAttributeCountryName]
  /// returns [ClientContext]
  ClientContext country(StrategyAttributeCountryName countryName) {
    attributes['country'] = [countryName.name!];
    return this;
  }

  /// Allows to set Device context when using rollout strategy with Device rule.
  /// @param device name of the device provided as enum from [StrategyAttributeDeviceName]
  /// returns [ClientContext]
  ClientContext device(StrategyAttributeDeviceName device) {
    attributes['device'] = [device.name!];
    return this;
  }

  /// Allows to set Platform context when using rollout strategy with Platform rule.
  /// @param platform name of the platform provided as enum from [StrategyAttributePlatformName]
  /// returns [ClientContext]
  ClientContext platform(StrategyAttributePlatformName platform) {
    attributes['platform'] = [platform.name!];
    return this;
  }

  /// Allows to set Version context when using rollout strategy with Version rule.
  /// @param version Semantic version
  /// returns [ClientContext]
  ClientContext version(String version) {
    attributes['version'] = [version];
    return this;
  }

  List<String>? operator [](String key) {
    return attributes[key];
  }

  /// Allows to set a Custom context attribute with a list of values when using rollout strategy with Custom rule.
  /// @param key Name of the Custom rule
  /// @param values Values of the Custom rule
  /// returns [ClientContext]
  void operator []=(String key, List<String> value) {
    attributes[key] = value;
  }

  /// Allows to set Custom context attribute when using rollout strategy with Custom rule.
  /// @param key Name of the Custom rule
  /// @param value Value of the Custom rule
  /// returns [ClientContext]
  ClientContext attr(String key, String value) {
    attributes[key] = [value];
    return this;
  }

  /// direct setting of values, easier to use in flow-API
  ClientContext attrs(String key, List<String> value) {
    attributes[key] = value;
    return this;
  }

  /// Call this method to clear Context
  ClientContext clear() {
    attributes.clear();
    return this;
  }

  FeatureStateHolder feature(String key) => repo.feat(key);

  bool set(String key) => feature(key).set;

  bool enabled(String key) => feature(key).enabled;

  bool? flag(String key) => feature(key).flag;

  bool exists(String key) => feature(key).exists;

  num? number(String key) => feature(key).number;

  String? string(String key) => feature(key).string;

  dynamic json(String key) => feature(key).json;

  Readiness get readiness => repo.readiness;

  UsageEvent _fillUsageCollection(UsageEvent usage) {
    usage
      ..userKey=usageUserKey();

    if (usage is UsageFeaturesCollection) {
      usage
        ..featureValues = repo.features
            .map((key) => FeatureHubUsageValue(feature(key) as FeatureStateBaseHolder))
            .toList();
    }

    if (usage is UsageFeaturesCollectionContext) {
      usage
        ..attributes = attributes;
    }

    return usage;
  }

  @protected
  recordRelativeValuesForUser() {
    repo.recordUsageEvent(
        _fillUsageCollection(repo.usageProvider.createUsageContextCollectionEvent()));
  }

  void recordUsageEvent(UsageEvent usageEvent) {
    _fillUsageCollection(usageEvent);
  }

  /// Call this method to rebuild Context
  Future<ClientContext> build() async {
    return this;
  }
}
