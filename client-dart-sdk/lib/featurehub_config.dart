import 'package:dio/dio.dart';
import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_client_sdk/featurehub.dart';
import 'package:openapi_dart_common/openapi.dart';

class FeatureHubConfig {
  final List<String> _apiKeys;
  final FeatureServiceApi _api;
  final ClientFeatureRepository _repository;
  String? xFeatureHubHeader;

  FeatureHubConfig(String host, this._apiKeys, this._repository)
      : _api = FeatureServiceApi(ApiClient(basePath: host)) {
    if (_apiKeys.any((key) => key.contains('*'))) {
      throw Exception(
          'You are using a client evaluated API Key in Dart and this is not supported.');
    }

    _repository.clientContext.registerChangeHandler((header) async {
      xFeatureHubHeader = header;
    });
  }

  Future<ClientFeatureRepository> request() async {
    final options = xFeatureHubHeader == null
        ? null
        : (Options()..headers = {'x-featurehub': xFeatureHubHeader});

    return _api
        .getFeatureStates(_apiKeys, options: options)
        .then((environments) {
      final states = <FeatureState>[];
      environments.forEach((e) {
        e.features.forEach((f) {
          f.environmentId = e.id;
        });
        states.addAll(e.features);
      });
      _repository.notify(SSEResultState.features, states);
      return _repository;
    }).catchError((e, s) {
      _repository.notify(SSEResultState.failure, null);
      return _repository;
    });
  }
}
