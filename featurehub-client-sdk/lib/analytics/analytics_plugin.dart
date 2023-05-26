
import 'dart:async';
import 'dart:collection';
import 'package:featurehub_client_sdk/config.dart';
import 'package:meta/meta.dart';
import 'analytics_event.dart';

abstract class FeatureHubAnalyticsPlugin {
  AnalyticsEvent? _lastEvent;
  AnalyticsEvent? get lastEvent => _lastEvent;

  final _defaultEventParameters = <String, dynamic>{};

  /// The parameters sent with all events.
  ///
  /// Individual event parameters have higher priority on collisions.
  Map<String, dynamic> get defaultEventParameters =>
      UnmodifiableMapView(_defaultEventParameters);

  Map<String, String> analyticNameMapping = {
    'featurehub-collection': 'featurehub-collection',
    'featurehub-use': 'featurehub-use'
  };

  set defaultEventParameters(Map<String, dynamic> newValue) {
    _defaultEventParameters.clear();
    _defaultEventParameters.addAll(newValue);
  }

  @protected
  Future<void> sendProtected(AnalyticsEvent event) async {}

  // so we don't need to have to await it and lint it everywhere
  void send(AnalyticsEvent event) {
    _lastEvent = event;
    sendProtected(event);
  }
}

class AnalyticsAdapter {
  List<FeatureHubAnalyticsPlugin> _plugins = [];
  FeatureRepository _repository;
  late StreamSubscription<AnalyticsEvent> _analyticsSub;

  AnalyticsAdapter(this._repository) {
    _analyticsSub = this._repository.analyticsStream.listen((event) {
      _plugins.forEach((p) => p.send(event));
    });
  }

  void close() {
    _analyticsSub.cancel();
  }

  registerPlugin(FeatureHubAnalyticsPlugin plugin) {
    _plugins.add(plugin);
  }
}

