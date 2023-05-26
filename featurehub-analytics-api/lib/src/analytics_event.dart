
abstract class AnalyticsEventName {
  String get eventName;
}


/// this represents data that should be attached to all analytics events,
/// it can be paired with an individual user depending on how it is used. Usually
/// this is only done with single-user platforms like mobile, web and desktop.
/// It also forms the base of all events (which simply add an event name)
class AnalyticsEvent {
  String? userKey;
  Map<String, dynamic> additionalParams;

  AnalyticsEvent({
    this.userKey,
    this.additionalParams = const {}
  });

  /// this is just a convenience function, all data should be made available so any appropriate
  /// analytics providers can grab the requisite information.
  Map<String, dynamic> toMap() {
    return {
      ...additionalParams
    };
  }
}

