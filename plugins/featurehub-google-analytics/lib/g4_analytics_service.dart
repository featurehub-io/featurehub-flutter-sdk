

import 'package:featurehub_client_sdk/featurehub.dart';
import 'g4_analytics_service_io.dart'
  if (dart.library.html) 'g4_analytics_service_web.dart';

/// An umbrella class over platform implementations of Google Analytics 4.
abstract class G4AnalyticsService extends FeatureHubAnalyticsPlugin {
  factory G4AnalyticsService({
    String? measurementId,
    String? apiKey,
    bool  debugMode = false
  }) =>
    createGoogleAnalytics4Service(measurementId: measurementId, apiKey: apiKey); // platform specific func

  /// Since we use the default constructor as the factory,
  /// a non-factory constructor with any other name is required for subclasses.
  G4AnalyticsService.create();
}
