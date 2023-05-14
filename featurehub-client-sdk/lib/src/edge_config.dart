

import 'package:featurehub_client_sdk/src/features.dart';

import 'client_context.dart';
import 'internal/client_eval_context.dart';
import 'internal/edge_rest.dart';

import 'config.dart';
import 'internal/internal_repository.dart';
import 'internal/repository.dart';
import 'internal/server_eval_context.dart';
import 'internal/sse_client.dart'
  if (dart.library.io) 'internal/sse_client_dartio.dart'
  if (dart.library.html) 'internal/sse_client_darthtml.dart';

enum EdgeClient { REST, STREAM }

class FeatureHubConfig implements FeatureHub {
  List<String> _apiKeys;
  String _featurehubUrl;
  ServerEvalClientContext? _serverEvalClientContext;
  EdgeClient client = EdgeClient.REST;
  InternalFeatureRepository _repo;
  EdgeService? _edge;
  int _timeout = 300;

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

    if (!_clientEvaluated) {
      if (_serverEvalClientContext != null) {
        return _serverEvalClientContext!;
      }

      // server contexts need a connection each
      _serverEvalClientContext = ServerEvalClientContext(_repo, _createEdgeService());
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
    if (client == EdgeClient.REST) {
      return EdgeRest(this, _repo, timeout: _timeout);
    }

    return EdgeStreaming(this, _repo);
  }

  @override
  FeatureHub streaming() {
    if (apiKeys.length > 1) {
      throw Exception("Cannot have more than one API key for streaming");
    }

    client = EdgeClient.STREAM;
    return this;
  }

  @override
  FeatureHub timeout(int seconds) {
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
}