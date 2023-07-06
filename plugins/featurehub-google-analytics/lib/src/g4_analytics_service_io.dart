

import 'package:featurehub_analytics_api/analytics.dart';
import 'g4_analytics_service.dart';

G4AnalyticsService createGoogleAnalytics4Service({
  String? measurementId,
  String? apiKey,
  bool  debugMode = false,
  bool unnamedBecomeEventParameters = false
}) {
  if (measurementId == null || apiKey == null) {
    throw Exception("IO based applications must specify the measurement id and apiKey for ga4");
  }

  return GoogleAnalytics4ServiceNonWeb(measurementId, apiKey, debugMode,
      unnamedBecomeEventParameters: unnamedBecomeEventParameters);
}

/// The required placeholder for non-web builds, e.g. unit tests.
class GoogleAnalytics4ServiceNonWeb extends G4AnalyticsService {
  String measurementId;
  String apiKey;
  final bool debugMode;

  GoogleAnalytics4ServiceNonWeb(this.measurementId, this.apiKey, this.debugMode,
      {bool unnamedBecomeEventParameters = false}) : super.create(unnamedBecomeEventParameters: unnamedBecomeEventParameters);

  @override
  Future<void> sendProtected(UsageEvent event) {
    throw UnimplementedError();
  }
}
