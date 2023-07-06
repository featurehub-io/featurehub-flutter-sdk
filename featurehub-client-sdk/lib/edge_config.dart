

import 'package:featurehub_client_sdk/features.dart';
import 'package:featurehub_client_sdk/src/polling_delegate_client.dart';
import 'package:featurehub_client_sdk/usage/usage_adapter.dart';
import 'package:featurehub_usage_api/usage.dart';

import 'client_context.dart';
import 'config.dart';
import 'src/client_eval_context.dart';
import 'src/rest_client.dart';
import 'src/internal_repository.dart';
import 'src/log.dart';
import 'src/repository.dart';
import 'src/server_eval_context.dart';
import 'src/sse_client.dart';

enum EdgeClient { REST, STREAM, REST_POLL }

class FeatureHubConfig implements FeatureHub {
  List<String> _apiKeys;
  String _featurehubUrl;
  ServerEvalClientContext? _serverEvalClientContext;
  EdgeClient _client = EdgeClient.REST;
  InternalFeatureRepository _repo;
  EdgeService? _edge;
  int _timeout = 300;
  List<EdgeService> _edgeConnections = [];
  UsageAdapter? _usageAdapter;

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
    if (_featurehubUrl.startsWith("https://app.featurehub.io") && _client == EdgeClient.STREAM && !_clientEvaluated) {
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
    final edge = (_client == EdgeClient.REST) ?
        EdgeRest(this, _repo, timeout: _timeout) :
        (_client == EdgeClient.STREAM ? EdgeStreaming(this, _repo) : PollingDelegateEdge(this, _repo));

    _edgeConnections.add(edge);

    return edge;
  }

  @override
  FeatureHub streaming() {
    if (apiKeys.length > 1) {
      throw Exception("Cannot have more than one API key for streaming");
    }

    if (_client != EdgeClient.STREAM) {
      if (_edge != null) {
        _edge!.close();
        _edgeConnections.remove(_edge);
        _edge = null;
      }

      _client = EdgeClient.STREAM;
    }

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
    _usageAdapter?.close();
    _usageAdapter = null;
    _edgeConnections.forEach((ec) => ec.close());
    _edgeConnections.clear();
    _edge = null;
    _serverEvalClientContext?.close();
    _serverEvalClientContext = null;
  }

  @override
  UsageAdapter get usageAdapter {
    if (_usageAdapter == null) { // lazy init
      _usageAdapter = UsageAdapter(_repo);
    }

    return _usageAdapter!;
  }

  @override
  void recordUsageEvent(UsageEvent event) {
    _repo.recordUsageEvent(event);
  }

  @override
  FeatureHub rest({int minUpdateInterval = 180}) {
    _timeout = minUpdateInterval;
    _client = EdgeClient.REST;
    return this;
  }

  @override
  FeatureHub restPoll({int interval = 180}) {
    _timeout = interval;
    _client = EdgeClient.REST_POLL;
    return this;
  }
}