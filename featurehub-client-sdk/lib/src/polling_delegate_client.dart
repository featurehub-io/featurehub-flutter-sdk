


import 'dart:async';

import 'package:featurehub_client_sdk/config.dart';
import 'package:featurehub_client_sdk/src/internal_repository.dart';
import 'package:featurehub_client_sdk/src/rest_client.dart';
import 'package:meta/meta.dart';

@internal
class PollingDelegateEdge implements EdgeService {
  EdgeRest edgeRest;
  Timer? _timer;

  @override
  void close() {
    _timer?.cancel();
    edgeRest.close();
  }

  @override
  Future<void> contextChange(String header) async {
    _timer?.cancel();
    await edgeRest.contextChange(header);
    _resetTimer();
  }

  _resetTimer() {
    if (!edgeRest.stopped) {
      _timer = Timer(Duration(seconds: edgeRest.interval), () => poll());
    }
  }

  @override
  int get interval => edgeRest.interval;

  @override
  Future<void> poll() async {
    _timer?.cancel();
    await edgeRest.poll();
    _resetTimer();
  }

  _handleTimer() async {
    await edgeRest.poll();
  }

  @override
  bool get stopped => edgeRest.stopped;

  PollingDelegateEdge(FeatureHub config, InternalFeatureRepository repo, {int timeout = 360}) :
      edgeRest = EdgeRest(config, repo, timeout: timeout, pollDelegate: true);
}