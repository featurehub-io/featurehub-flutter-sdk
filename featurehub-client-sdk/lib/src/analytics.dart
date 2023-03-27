class AnalyticsEvent {
  final String action;
  final Map<String, Object>? other;
  final List<FeatureStateHolder> features;

  AnalyticsEvent(this.action, this.features, this.other);
}


/// allows us to log an analytics event with this set of features
void logAnalyticsEvent(String action, {Map<String, Object>? other}) {
  final featureStateAtCurrentTime =
  _features.values.where((f) => f.exists).map((f) => f.copy()).toList();

  _analyticsCollectors
      .add(AnalyticsEvent(action, featureStateAtCurrentTime, other));
}
