//

import 'analytics.dart';

abstract class AnalyticsEvent {
  const AnalyticsEvent({
    required this.name,
  });

  final String name;

  Map<String, dynamic> toMap() {
    return {};
  }
}

/**
 * This represents a collection of feature states that are passed to the analytics provider
 */
class AnalyticsFeatureCollection extends AnalyticsEvent {
  final Map<String, dynamic> additionalParams;
  late Map<String, String?> featureValuePairs;
  final List<FeatureHubAnalyticsValue> featureValues; // ensure this data is visible

  AnalyticsFeatureCollection({required List<FeatureHubAnalyticsValue> this.featureValues, this.additionalParams = const {}, }): super(name: 'featurehub-collection') {
    featureValuePairs =  Map.fromIterable(this.featureValues, key: (e) => e.key, value: (e) => e.value);
  }

  @override
  Map<String, dynamic> toMap() {
    return {
      ...featureValuePairs,
      ...additionalParams,
      ...super.toMap()
    };
  }
}
