
import 'dart:async';

import 'package:featurehub_client_sdk/config.dart';
import 'package:featurehub_usage_api/usage.dart';

class UsageAdapter {
  List<UsagePlugin> _plugins = [];
  FeatureRepository _repository;
  late StreamSubscription<UsageEvent> _usageSub;

  UsageAdapter(this._repository) {
    _usageSub = this._repository.usageStream.listen((event) {
      _plugins.forEach((p) => p.send(event));
    });
  }

  void close() {
    _usageSub.cancel();
  }

  registerPlugin(UsagePlugin plugin) {
    _plugins.add(plugin);
  }
}