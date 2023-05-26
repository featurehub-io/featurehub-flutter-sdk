import 'dart:convert';

import 'package:meta/meta.dart';

import 'analytics.dart';

abstract class AnalyticsEvent {
  AnalyticsEvent({
    required this.name,
    this.userKey
  });

  final String name;
  String? userKey;

  /// this is just a convenience function, all data should be made available so any appropriate
  /// analytics providers can grab the requisite information.
  Map<String, dynamic> toMap() {
    return {
    };
  }
}

/// This is the base class for an individual feature being evaluated. Users can descend from
/// this class and add custom features of their own if they wish.
class AnalyticsFeature extends AnalyticsEvent {
  final Map<String, List<String>> attributes;
  final String? userKey;
  FeatureHubAnalyticsValue feature;

  AnalyticsFeature(FeatureHubAnalyticsValue val, this.attributes, this.userKey):
    this.feature = val,
    super(name: 'feature');

  @override
  Map<String, dynamic> toMap() {
    return {
      'feature': feature.key,
      'value': feature.value,
      'id': feature.id,
      if (attributes.length > 0)
        ...attributes,
      ...super.toMap()
    };
  }
}

/**
 * This represents a collection of feature states that are passed to the analytics provider. It is
 * triggered when there is an update for one or more features or contexts from the user. Something can
 * request the recording of one of these events and it will be filled by the context then the repository
 *
 */
class AnalyticsCollectionEvent extends AnalyticsEvent {
  final Map<String, dynamic> additionalParams;
  /// these represent the attributes from the context of the user
  Map<String, List<String>> attributes = {};

  /// these represent the features at the time of the collection event
  List<FeatureHubAnalyticsValue> featureValues = [];

  AnalyticsCollectionEvent({this.additionalParams = const {}, String? name}): super(name: name ?? 'feature-collection');

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

/// use this as an interface and create your own to override the events
class AnalyticsProvider {
  /// This is the event created when an individual feature is used or evaluated within a context
  AnalyticsFeature createAnalyticsFeatureEvent(FeatureHubAnalyticsValue val, Map<String, List<String>> attributes, String? userKey) => AnalyticsFeature(val, attributes, userKey);

  /// This is the event created when "build" is called on the context (server or client).
  AnalyticsCollectionEvent createAnalyticsCollectionEvent({Map<String, dynamic>? additionalParams, String? name }) => AnalyticsCollectionEvent(additionalParams: additionalParams ?? const {}, name: name);
}
