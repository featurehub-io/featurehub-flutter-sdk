

import 'package:featurehub_analytics_api/analytics.dart';
import 'package:featurehub_client_sdk/analytics/analytics_event.dart';
import 'package:featurehub_client_sdk/features.dart';

import 'analytics/analytics_adapter.dart';
import 'client_context.dart';
import 'src/client_eval_context.dart';
import 'src/edge_rest.dart';

import 'config.dart';
import 'src/internal_repository.dart';
import 'src/log.dart';
import 'src/repository.dart';
import 'src/server_eval_context.dart';
import 'src/sse_client.dart';

enum EdgeClient { REST, STREAM }

class FeatureHubConfig implements FeatureHub {
  List<String> _apiKeys;
  String _featurehubUrl;
  ServerEvalClientContext? _serverEvalClientContext;
  EdgeClient client = EdgeClient.REST;
  InternalFeatureRepository _repo;
  EdgeService? _edge;
  int _timeout = 300;
  List<EdgeService> _edgeConnections = [];
  AnalyticsAdapter? _analyticsAdapter;

  FeatureHubConfig(this._featurehubUrl, this._apiKeys) : _repo = ClientFeatureRepository() {
    if (_apiKeys.isEmpty) {
      throw Exception("Must specify apiKeys");
    }

    if (_apiKeys.where((key) => key.contains('*')).isNotEmpty && _apiKeys.where((key) => !key.contains('*')).isNotEmpty) {
      throw Exception("All keys must be server or client side");
    }

    if (_featurehubUrl.endsWith('/')) {
      this._featurehubUrl = _featurehubUrl.substring(0, _featurehubUrl.length - 1);
    }
  }

  bool get _clientEvaluated => _apiKeys.every((k) => k.contains("*"));

  @override
  List<String> get apiKeys => _apiKeys;

  @override
  String get baseUrl => _featurehubUrl;

  @override
  String get apiKey => _apiKeys[0];

  @override
  ClientContext newContext() {
    if (_featurehubUrl.startsWith("https://app.featurehub.io") && client == EdgeClient.STREAM && !_clientEvaluated) {
      throw Exception("FeatureHub SaaS does not supported streaming for server side evaluation, please use REST");
    }

    log.fine("SSE: ${_clientEvaluated}");
    if (!_clientEvaluated) {
      if (_serverEvalClientContext != null) {
        return _serverEvalClientContext!;
      }

      // server contexts need a connection each
      _serverEvalClientContext = ServerEvalClientContext(_repo, _createEdgeService());

      return _serverEvalClientContext!;
    }

    // client contexts share a single connection
    return ClientEvalContext(_repo, _getOrCreateEdgeService());
  }

  EdgeService _getOrCreateEdgeService() {
    if (_edge == null) {
      _edge = _createEdgeService();
    }

    return _edge!;
  }

  EdgeService _createEdgeService() {
    final edge = (client == EdgeClient.REST) ? EdgeRest(this, _repo, timeout: _timeout) : EdgeStreaming(this, _repo);
    _edgeConnections.add(edge);
    return edge;
  }

  @override
  FeatureHub streaming() {
    if (apiKeys.length > 1) {
      throw Exception("Cannot have more than one API key for streaming");
    }

    if (client != EdgeClient.STREAM) {
      if (_edge != null) {
        _edge!.close();
        _edgeConnections.remove(_edge);
        _edge = null;
      }

      client = EdgeClient.STREAM;
    }

    return this;
  }

  @override
  FeatureHub timeout(int seconds) {
    if (client == EdgeClient.STREAM) {
      throw Exception('Cannot use streaming and set a timeout');
    }

    _timeout = seconds;
    return this;
  }

  @override
  Future<ClientContext> start() async {
    if (_clientEvaluated) {
      throw Exception("method only relevant for server evaluated keys");
    }

    final ctx = newContext();

    await ctx.build();

    return ctx;
  }

  @override
  Stream<Readiness> get readinessStream => _repo.readinessStream;

  @override
  FeatureRepository get repository => _repo;

  @override
  void close() {
    log.finest("FH: closing");
    _analyticsAdapter?.close();
    _analyticsAdapter = null;
    _edgeConnections.forEach((ec) => ec.close());
    _edgeConnections.clear();
    _edge = null;
    _serverEvalClientContext?.close();
    _serverEvalClientContext = null;
  }

  @override
  AnalyticsAdapter get analyticsAdapter {
    if (_analyticsAdapter == null) { // lazy init
      _analyticsAdapter = AnalyticsAdapter(_repo);
    }

    return _analyticsAdapter!;
  }

  @override
  void recordAnalyticsEvent(AnalyticsEvent event) {
    _repo.recordAnalyticsEvent(event);
  }
}