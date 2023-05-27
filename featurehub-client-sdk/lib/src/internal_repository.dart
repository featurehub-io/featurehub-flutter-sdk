

import 'package:featurehub_analytics_api/analytics.dart';
import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_client_sdk/featurehub.dart';
import 'package:featurehub_client_sdk/src/internal_context.dart';
import 'package:featurehub_client_sdk/src/internal_features.dart';
import 'package:meta/meta.dart';

abstract class AppliedValue {
  final bool matched;
  final dynamic value;

  AppliedValue(this.matched, this.value);
}

@internal
abstract class InternalFeatureRepository extends FeatureRepository {
  void recordAnalyticsEvent(AnalyticsEvent event);

  /// there were no features returned for a valid set of API Keys, so repository is ready but empty
  repositoryEmpty();
  /// force the repo into not ready status only happens when we swap context in server eval key
  repositoryNotReady();

  AppliedValue apply(List<FeatureRolloutStrategy> strategies, String key, String id, InternalContext? clientContext);
  registerFeatureValueInterceptor(bool allowOverrideLock, FeatureValueInterceptor interceptor);

  FeatureStateBaseHolder feat(String key);
  InterceptorValue? findInterceptor(String key, bool locked);

  void updateFeatures(List<FeatureState> features);
  void updateFeature(FeatureState feature);
  void deleteFeature(FeatureState feature);

  void notify(SSEResultState? status);

  // for historic support of Google Analytics
  Set<String> get features;
  Stream<Readiness> get readinessStream;
  Stream<AnalyticsEvent> get analyticsStream;
  AnalyticsProvider get analyticsProvider;
  Stream<FeatureStateBaseHolder> get featureUpdatedStream;

  Future<void> used(String key, String id, val, FeatureValueType valueType, Map<String, List<String>> attributes, String? analyticsUserKey);
}