import 'dart:convert';

import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_client_sdk/featurehub.dart';
import 'package:meta/meta.dart';

import 'internal_repository.dart';
import 'log.dart';

import 'sse_client_dartio.dart'
  if (dart.library.html) 'sse_client_darthtml.dart';

@internal
abstract class EdgeStreaming implements EdgeService {
  @protected
  FeatureHub config;
  @protected
  InternalFeatureRepository repository;
  @protected
  String url;
  @protected
  bool connected = false;
  @protected
  bool closed = false;
  @protected
  bool stopped = false;


  factory EdgeStreaming(FeatureHubConfig config, InternalFeatureRepository repository)
    => createEdgeStreaming(config, repository);

  /// Since we use the default constructor as the factory,
  /// a non-factory constructor with any other name is required for subclasses.
  EdgeStreaming.create(this.config, this.repository) :
      url = "${config.baseUrl}/features/${config.apiKey}";

  bool configEvent(dynamic data) {
    if (data != null && jsonDecode(data!)?['edge.stale']) {
      close();
      return true;
    }

    return false;
  }

  @protected
  void process(SSEResultState status, dynamic data) {
    log.fine('Event is ${status} value ${data}');

    switch (status) {
      case SSEResultState.ack:
      case SSEResultState.bye:
        repository.notify(status);
        break;
      case SSEResultState.failure: // we cannot continue, we have failed (e.g no api key)
        repository.notify(status);
        close();
        break;
      case SSEResultState.features:
        if (data != null) {
          repository.updateFeatures(
              FeatureState.listFromJson(jsonDecode(data!)));
        }
        break;
      case SSEResultState.feature:
        if (data != null) {
          repository
              .updateFeature(FeatureState.fromJson(jsonDecode(data!)));
        }
        break;
      case SSEResultState.deleteFeature:
        if (data != null) {
          repository
              .deleteFeature(FeatureState.fromJson(jsonDecode(data!)));
        }
        break;
      case SSEResultState.config:
        configEvent(data);
        break;
      case SSEResultState.error:
        close();
        stopped = true;
        break;
    }

    if (status == SSEResultState.bye &&
        repository.readiness != Readiness.Failed &&
        closed) {
      poll();
    }
  }

  @override
  int get interval => 0;
}
