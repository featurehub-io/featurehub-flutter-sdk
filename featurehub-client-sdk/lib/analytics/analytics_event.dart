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

/// This maps a feature evaluated in a context into an analytics event.
/// It is up to the analytics plugin to filter out fields that shouldn't be included.
class AnalyticsFeature extends AnalyticsEvent {
  final Map<String, List<String>> attributes;
  final String key;
  final String? value;
  final String id;

  AnalyticsFeature(FeatureHubAnalyticsValue val, this.attributes):
    this.key = val.key,
    this.value = val.value,
    this.id = val.id,
    super(name: 'feature');

  @override
  Map<String, dynamic> toMap() {
    return {
      'feature': key,
      'value': value,
      'id': id,
      if (attributes.length > 0)
        'attributes': attributes,
      ...super.toMap()
    };
  }

}

/**
 * This represents a collection of feature states that are passed to the analytics provider
 */
class AnalyticsFeatureCollection extends AnalyticsEvent {
  final Map<String, dynamic> additionalParams;
  late Map<String, dynamic> featureValuePairs;
  final List<FeatureHubAnalyticsValue> featureValues; // ensure this data is visible

  AnalyticsFeatureCollection({required List<FeatureHubAnalyticsValue> this.featureValues, this.additionalParams = const {}, }): super(name: 'featurehub-collection') {
    featureValuePairs =  Map.fromIterable(this.featureValues, key: (e) => e.key, value: (e) => {'value': e.value, 'id': e.id});
  }

  @override
  Map<String, dynamic> toMap() {
    return {
      'keys': featureValues.map((e) => e.key),
      ...featureValuePairs,
      ...additionalParams,
      ...super.toMap()
    };
  }
}
