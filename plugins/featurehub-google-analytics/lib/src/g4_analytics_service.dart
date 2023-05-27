

import 'package:featurehub_analytics_api/analytics.dart';

import 'analytics_page_view_io.dart'
  if (dart.library.html)  'analytics_page_view_web.dart';
import 'g4_analytics_service_io.dart'
  if (dart.library.html) 'g4_analytics_service_web.dart';


/// An umbrella class over platform implementations of Google Analytics 4.
abstract class G4AnalyticsService extends AnalyticsPlugin {
  factory G4AnalyticsService({
    String? measurementId,
    String? apiKey,
    bool  debugMode = false,
    bool unnamedBecomeEventParameters = false
  }) =>
    createGoogleAnalytics4Service(debugMode: debugMode, measurementId: measurementId, apiKey: apiKey, unnamedBecomeEventParameters: unnamedBecomeEventParameters); // platform specific func

  /// Since we use the default constructor as the factory,
  /// a non-factory constructor with any other name is required for subclasses.
  G4AnalyticsService.create({bool unnamedBecomeEventParameters = false}): super(unnamedBecomeEventParameters);

  AnalyticsEvent pageView({required String title,
    Map<String, dynamic> additionalParams = const {},
    String? userKey}) => createPageView(title: title, additionalParams: additionalParams, userKey: userKey);
}
