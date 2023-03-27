

import 'config.dart';

abstract class FeatureHubConfig implements FeatureHub {
  List<String> _apiKeys;
  String _featurehubUrl;


  FeatureHubConfig(this._featurehubUrl, this._apiKeys) {
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

  List<String> get apiKeys => _apiKeys;

  String get baseUrl => _featurehubUrl;


}