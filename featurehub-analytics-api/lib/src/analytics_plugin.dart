
import 'dart:async';
import 'dart:collection';
import 'package:meta/meta.dart';

import 'analytics_event.dart';

abstract class AnalyticsPlugin {
  AnalyticsEvent? _lastShared;
  AnalyticsEvent? get lastShared => _lastShared;

  final _defaultEventParameters = <String, dynamic>{};
  /// if this is true, then unnamed events will automatically get pushed into the defaultEventParmeters
  final bool unnamedBecomeEventParameters;

  /// The parameters sent with all events.
  ///
  /// Individual event parameters have higher priority on collisions.
  Map<String, dynamic> get defaultEventParameters =>
      UnmodifiableMapView(_defaultEventParameters);

  set defaultEventParameters(Map<String, dynamic> newValue) {
    _defaultEventParameters.clear();
    _defaultEventParameters.addAll(newValue);
  }

  AnalyticsPlugin(this.unnamedBecomeEventParameters);

  @protected
  Future<void> sendProtected(AnalyticsEvent event) async {}

  // so we don't need to have to await it and lint it everywhere
  void send(AnalyticsEvent event) {
    if (event is AnalyticsEventName) {
      sendProtected(event);
    }
    else {
      print("received unnamed event ${event.toMap()} -> ${unnamedBecomeEventParameters}");
      _lastShared = event;
      if (unnamedBecomeEventParameters) {
        defaultEventParameters = event.toMap();
      }
    }
  }
}


