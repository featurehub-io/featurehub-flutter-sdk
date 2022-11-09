import 'package:dio/dio.dart';
import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_client_sdk/featurehub.dart';
import 'package:logging/logging.dart';
import 'package:openapi_dart_common/openapi.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';

final _log = Logger('FeatureHub');

class FeatureHubConfig {
  final List<String> _apiKeys;
  final FeatureServiceApi _api;
  final ClientFeatureRepository _repository;
  String? xFeatureHubHeader;
  bool _deadConnection = false;
  DateTime _cacheTimeout;
  int _timeoutInSeconds;

  FeatureHubConfig(String host, this._apiKeys, this._repository, { int timeout = 360 })
      : _api = FeatureServiceApi(ApiClient(basePath: host)),
        _timeoutInSeconds = timeout,
        _cacheTimeout = DateTime.now().subtract(Duration(seconds: 1)) // allow for immediate polling
  {
    if (_apiKeys.any((key) => key.contains('*'))) {
      throw Exception(
          'You are using a client evaluated API Key in Dart and this is not supported.');
    }

    _repository.clientContext.registerChangeHandler((header) async {
      xFeatureHubHeader = header;
    });
  }

  bool get isConnectionDead => _deadConnection;
  int get timeoutInSeconds => _timeoutInSeconds;
  DateTime get whenNextPollAllowed => _cacheTimeout;

  void success(List<FeatureEnvironmentCollection> environments) {
    final states = <FeatureState>[];
    environments.forEach((e) {
      e.features.forEach((f) {
        f.environmentId = e.id;
      });
      states.addAll(e.features);
    });

    _repository.notify(SSEResultState.features, states);
  }

  void decodeCacheControl(List<String> cacheControlHeader) {
    final reg = RegExp(r'max-age=(\d+)', caseSensitive: false);

    cacheControlHeader.forEach((header) {
      final match = reg.firstMatch(header);
      if (match != null && match.group(0) != null) {
        try {
          var cacheAge = int.parse(match.group(0).toString().substring(8));
          if (cacheAge > 0) {
            _timeoutInSeconds = cacheAge;
          }
        } catch (e) {
        }
      }
    });
  }

  void checkForCacheControl(ApiResponse response)  {
    if (response.headers.containsKey('cache-control')) {
      decodeCacheControl(response.headers['cache-control']!);
    }
  }

  Future<void> decodeResponse(ApiResponse response) async {
    if (response.statusCode == 200 || response.statusCode == 236) {
      checkForCacheControl(response);

      final environments = await _api.apiDelegate.getFeatureStates_decode(response.body!);

      success(environments);

      if (response.statusCode == 236) {
        _log.warning("featurehub: this environment has gone stale and will not receive further updates.");
        _deadConnection = true;
      }
    } else if (response.statusCode == 400 || response.statusCode == 404) {
      _repository.notify(SSEResultState.failure, null);
    }

    if (_timeoutInSeconds > 0) {
      _cacheTimeout = DateTime.now().add(Duration(seconds: _timeoutInSeconds));
    }
  }

  Future<ClientFeatureRepository> request() async {
    if (_deadConnection) return _repository;
    final bf = DateTime.now();
    if (DateTime.now().isBefore(_cacheTimeout)) return _repository;

    final options = xFeatureHubHeader == null
        ? null
        : (Options()
      ..headers = {'x-featurehub': xFeatureHubHeader});

    // added to break any caching if we change the header on the client side
    final sha = xFeatureHubHeader == null ? '0' :
    sha256.convert(utf8.encode(xFeatureHubHeader!)).toString();

    final response = await _api.apiDelegate
        .getFeatureStates(_apiKeys, options: options, contextSha: sha);

    await decodeResponse(response);

    return _repository;
  }
}
