
import 'package:featurehub_client_sdk/usage/usage_adapter.dart';
import 'package:featurehub_client_sdk/usage/usage_event.dart';
import 'package:featurehub_usage_api/usage.dart';

import 'client_context.dart';
import 'features.dart';

abstract class EdgeService {
  Future<void> poll();
  Future<void> contextChange(String header);
  void close();
  bool get stopped;
  int get interval;
}

abstract class FeatureHub {
  List<String> get apiKeys;
  String get apiKey;
  String get baseUrl;
  Future<ClientContext> start();
  UsageAdapter get usageAdapter;
  FeatureRepository get repository;
  ClientContext newContext();

  /// if using rest, allows us to configure whether we are using a minUpdateInterval (so we
  /// request when this timeout is exceeded and we have requested a feature state) or an interval.
  /// If the interval is set, we start a background timer so be careful with use in Mobile apps.

  /// we are using SSE and near-real-time updates
  FeatureHub streaming();
  FeatureHub restPoll({int interval = 180});
  FeatureHub rest({int minUpdateInterval = 180});

  Stream<Readiness> get readinessStream;
  void recordUsageEvent(UsageEvent event);

  void close() {}
}

abstract class FeatureRepository {
  void registerUsageProvider(UsageProvider provider);
  void registerFeatureValueInterceptor(bool allowOverrideLock, FeatureValueInterceptor interceptor);
  FeatureStateHolder feature(String key);
  Readiness get readiness;
  /// newFeatureStateAvailable triggers after the repository has become ready, some new feature has turned up
  Stream<FeatureRepository> get newFeatureStateAvailableStream;
  Stream<UsageEvent> get usageStream;
  Iterable<String> get availableFeatures;
}

