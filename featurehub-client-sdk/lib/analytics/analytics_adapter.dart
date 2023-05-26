
import 'dart:async';

import 'package:featurehub_client_sdk/config.dart';
import 'package:featurehub_analytics_api/analytics.dart';

class AnalyticsAdapter {
  List<AnalyticsPlugin> _plugins = [];
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

  registerPlugin(AnalyticsPlugin plugin) {
    _plugins.add(plugin);
  }
}