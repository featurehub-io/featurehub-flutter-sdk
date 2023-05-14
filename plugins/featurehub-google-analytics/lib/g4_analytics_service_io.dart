

import 'package:featurehub_client_sdk/featurehub.dart';
import 'g4_analytics_service.dart';

G4AnalyticsService createGoogleAnalytics4Service({
  String? measurementId,
  String? apiKey,
}) {
  if (measurementId == null || apiKey == null) {
    throw Exception("IO based applications must specify the measurement id and apiKey for ga4");
  }

  return GoogleAnalytics4ServiceNonWeb(measurementId, apiKey);
}

/// The required placeholder for non-web builds, e.g. unit tests.
class GoogleAnalytics4ServiceNonWeb extends G4AnalyticsService {
  String measurementId;
  String apiKey;

  GoogleAnalytics4ServiceNonWeb(this.measurementId, this.apiKey) : super.create();

  @override
  Future<void> sendProtected(AnalyticsEvent event) {
    throw UnimplementedError();
  }
}
