
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
}

abstract class FeatureRepository {
  FeatureStateHolder feature(String key);
  Readiness get readiness;
}

