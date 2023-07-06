import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_client_sdk/featurehub.dart';
import 'package:meta/meta.dart';
import 'package:openapi_dart_common/openapi.dart';

import 'internal_repository.dart';
import 'log.dart';

@internal
class EdgeRest implements EdgeService {
  final FeatureServiceApi _api;
  final InternalFeatureRepository _repository;
  final FeatureHub config;
  String? _featureHubHeader;
  String _shaOfHeader = '0';
  bool _deadConnection = false;
  bool _stopped = false;
  bool _headerChanged = false;
  DateTime _cacheTimeout;
  int _timeoutInSeconds;
  bool _pollDelegate;
  bool _busy = false;

  EdgeRest(this.config, this._repository, { int timeout = 360, pollDelegate = false })
      : _api = FeatureServiceApi(ApiClient(basePath: config.baseUrl)),
        _timeoutInSeconds = timeout,
        _pollDelegate = pollDelegate,
        _cacheTimeout = DateTime.now().subtract(Duration(seconds: 1)); // allow for immediate polling

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

    _repository.updateFeatures(states);
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
        log.warning("featurehub: this environment has gone stale and will not receive further updates.");
        _stopped = true;
      }
    } else if (response.statusCode == 400 || response.statusCode == 404) {
      _repository.notify(SSEResultState.failure);
      _deadConnection = true;
      log.config('Unable to connect to FeatureHub repository, there is a problem with the API KEY');
    } else {
      log.fine("There is a problem with the connection ${response.statusCode}");
    }

    if (_timeoutInSeconds > 0) {
      _cacheTimeout = DateTime.now().add(Duration(seconds: _timeoutInSeconds));
    }
  }

  Future<void> poll() async {
    if (_deadConnection || _stopped ) return;
    // if we are being controlled externally, we have been called and the timeout is 0,
    // the header changed or the cache timeout has expired, we need break our internal cache
    final breakCache = _pollDelegate || _timeoutInSeconds == 0 || _headerChanged || DateTime.now().isBefore(_cacheTimeout);
    // but can we actually ask? if we are already mid-flight, then no, if we are stopped, no
    final ask = !_busy && !_stopped && breakCache;

    if (ask) {
      try {
        _busy = true;
        _headerChanged = false;

        final options = (_featureHubHeader == null || _featureHubHeader!.isEmpty)
            ? null
            : (Options()
          ..headers = {'x-featurehub': _featureHubHeader});

        log.finest("requesting REST api ${config.baseUrl} : ${config.apiKeys}, sha: ${_shaOfHeader},  headers: ${_featureHubHeader}");


        final response = await _api.apiDelegate
            .getFeatureStates(config.apiKeys, options: options, contextSha: _shaOfHeader);

        await decodeResponse(response);
      } finally {
        _busy = false;
      }
    }
  }

  @override
  Future<void> contextChange(String header) async {
    if (header != _featureHubHeader && !_deadConnection) {
      _featureHubHeader = header;
      _shaOfHeader =
      header.isEmpty ? '0' : sha256.convert(utf8.encode(_featureHubHeader!))
          .toString();
      _headerChanged = true;
    }

    await poll();
  }

  @override
  bool get stopped => _deadConnection || _stopped;

  @override
  void close() {
    _deadConnection = true; // won't attempt to update
  }

  @override
  int get interval => _timeoutInSeconds;
}
