
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
  FeatureRepository get repository;
  ClientContext newContext();
  FeatureHub streaming();
  Stream<Readiness> get readinessStream;
}

abstract class FeatureRepository {
  FeatureStateHolder feature(String key);
  Readiness get readiness;
  Stream<FeatureRepository> get newFeatureStateAvailableStream;
  Stream<AnalyticsEvent> get analyticsStream;
  Iterable<String> get availableFeatures;
}

