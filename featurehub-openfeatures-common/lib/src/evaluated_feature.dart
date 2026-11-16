import 'package:featurehub_client_api/api.dart';

/// The result of evaluating a feature for a context.
class EvaluatedFeature {
  final String key;

  /// The feature as delivered by the server, or null if it does not exist.
  final FeatureState? featureState;

  /// The evaluated value: from a matching rollout strategy, an interceptor,
  /// or the feature's default value. Null if the feature has no value.
  final dynamic value;

  /// The id of the rollout strategy that supplied [value], if any: the
  /// strategy that matched locally for a client-evaluated API key, or the one
  /// the server applied (`FeatureState.v`) for a server-evaluated key.
  final String? strategyId;

  /// True if a value interceptor supplied [value].
  final bool intercepted;

  const EvaluatedFeature({
    required this.key,
    this.featureState,
    this.value,
    this.strategyId,
    this.intercepted = false,
  });

  /// True if the server has delivered this feature.
  bool get exists => featureState != null;

  FeatureValueType? get type => featureState?.type;

  /// True if the feature is locked in its environment.
  bool get locked => featureState?.l == true;

  int? get version => featureState?.version;

  @override
  String toString() =>
      'EvaluatedFeature($key=$value'
      '${strategyId == null ? '' : ', strategy $strategyId'}'
      '${intercepted ? ', intercepted' : ''})';
}
