
import 'package:featurehub_client_sdk/analytics/analytics_plugin.dart';

import 'analytics/analytics_event.dart';
import 'client_context.dart';
import 'features.dart';

abstract class EdgeService {
  Future<void> poll();
  Future<void> contextChange(String header);
  void close();
  bool get stopped;
}

abstract class FeatureHub {
  List<String> get apiKeys;
  String get apiKey;
  String get baseUrl;
  FeatureHub timeout(int seconds);
  Future<ClientContext> start();
  AnalyticsAdapter get analyticsAdapter;
  FeatureRepository get repository;
  ClientContext newContext();
  FeatureHub streaming();
  Stream<Readiness> get readinessStream;
  void recordAnalyticsEvent(AnalyticsCollectionEvent event);

  void close() {}
}

abstract class FeatureRepository {
  void registerAnalyticsProvider(AnalyticsProvider provider);
  FeatureStateHolder feature(String key);
  Readiness get readiness;
  /// newFeatureStateAvailable triggers after the repository has become ready, some new feature has turned up
  Stream<FeatureRepository> get newFeatureStateAvailableStream;
  Stream<AnalyticsEvent> get analyticsStream;
  Iterable<String> get availableFeatures;
}

