

import 'package:featurehub_analytics_api/analytics.dart';
import 'package:featurehub_google_analytics_plugin/src/analytics_page_view.dart';

import 'g4_analytics_service_io.dart'
  if (dart.library.html) 'src/g4_analytics_service_web.dart';

/// An umbrella class over platform implementations of Google Analytics 4.
abstract class G4AnalyticsService extends AnalyticsPlugin {
  factory G4AnalyticsService({
    String? measurementId,
    String? apiKey,
    bool  debugMode = false
  }) =>
    createGoogleAnalytics4Service(measurementId: measurementId, apiKey: apiKey); // platform specific func

  /// Since we use the default constructor as the factory,
  /// a non-factory constructor with any other name is required for subclasses.
  G4AnalyticsService.create();

  AnalyticsEvent pageView({required String title,
    Map<String, dynamic> additionalParams = const {},
    String? userKey}) => BaseAnalyticsPageView(title: title, additionalParams: additionalParams, userKey: userKey);
}
