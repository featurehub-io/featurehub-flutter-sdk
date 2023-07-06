
import 'package:featurehub_usage_api/usage.dart';

import 'usage.dart';

/// This is the base class for an individual feature being evaluated. Users can descend from
/// this class and add custom features of their own if they wish.
class UsageFeature extends UsageEvent implements UsageEventName {
  final Map<String, List<String>>? attributes;
  FeatureHubUsageValue feature;

  UsageFeature(FeatureHubUsageValue val, this.attributes, String? userKey):
    this.feature = val,
    super(userKey: userKey);

  @override
  Map<String, dynamic> toMap() {
    return {
      'feature': feature.key,
      'value': feature.value,
      'id': feature.id,
      if (attributes != null)
        ...attributes!,
      ...super.toMap()
    };
  }

  @override
  String get eventName => 'feature';
}

/**
 * This represents a collection of feature states that are passed to the usage provider. It is
 * triggered when there is an update for one or more features or contexts from the user. Something can
 * request the recording of one of these events and it will be filled by the context then the repository
 *
 */
class UsageFeaturesCollection extends UsageEvent {
  /// these represent the features at the time of the collection event
  List<FeatureHubUsageValue> featureValues = [];

  UsageFeaturesCollection({Map<String, dynamic> additionalParams = const {}, String? userKey}):
        super(userKey: userKey, additionalParams: additionalParams);

  // repo + clientContext have filled with data
  void ready() {}

  @override
  Map<String, dynamic> toMap() {
    return {
      if (featureValues.isNotEmpty)
        ...Map<String, dynamic>.fromIterable(featureValues, key: (e) => e.key, value: (e) => e.value),
      ...additionalParams,
      ...super.toMap()
    };
  }
}

class UsageFeaturesCollectionContext extends UsageFeaturesCollection {
  /// these represent the attributes from the context of the user
  Map<String, List<String>> attributes = {};

  UsageFeaturesCollectionContext({Map<String, dynamic> additionalParams = const {}, String? userKey}):
        super(userKey: userKey, additionalParams: additionalParams);

  @override
  Map<String, dynamic> toMap() {
    return {
      ...attributes,
      ...super.toMap()
    };
  }
}

/// use this as an interface and create your own to override the events
class UsageProvider {
  /// This is the event created when an individual feature is used or evaluated within a context
  UsageFeature createUsageFeatureEvent(FeatureHubUsageValue val, Map<String, List<String>>? attributes, String? userKey) => UsageFeature(val, attributes, userKey);

  /// This is the event created when "build" is called on the context (server or client).
  UsageFeaturesCollection createUsageCollectionEvent({Map<String, dynamic>? additionalParams }) => UsageFeaturesCollection(additionalParams: additionalParams ?? const {});

  /// This is the event created when "build" is called on the context (server or client).
  UsageFeaturesCollectionContext createUsageContextCollectionEvent({Map<String, dynamic>? additionalParams}) => UsageFeaturesCollectionContext(additionalParams: additionalParams ?? const {});
}
