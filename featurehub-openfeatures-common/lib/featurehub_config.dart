import 'package:dio/dio.dart';
import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_openfeatures_common/featurehub.dart';
import 'package:logging/logging.dart';
import 'package:openapi_dart_common/openapi.dart';
import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';

final _log = Logger('FeatureHub');

class FeatureHubConfig {
  final List<String> _apiKeys;
  final bool _clientEvaluated;
  final FeatureServiceApi _api;
  final ClientFeatureRepository _repository;
  String? xFeatureHubHeader;
  bool _deadConnection = false;
  DateTime _cacheTimeout;
  int _timeoutInSeconds;

  /// The longest a request may take, from sending it to reading the whole
  /// response. A request that takes longer throws a [TimeoutException]. Null
  /// waits indefinitely.
  final Duration? requestTimeout;

  /// [timeout] is the polling interval in seconds. [connectTimeout] limits how
  /// long establishing a connection may take, and [requestTimeout] how long a
  /// whole request may take; both default to waiting indefinitely.
  FeatureHubConfig(
    String host,
    this._apiKeys,
    this._repository, {
    int timeout = 360,
    Duration? connectTimeout,
    this.requestTimeout,
  }) : _clientEvaluated = isClientEvaluatedKeys(_apiKeys),
       _api = FeatureServiceApi(
         ApiClient(
           basePath: host,
           apiClientDelegate: DioClientDelegate(
             Dio(
               BaseOptions(
                 connectTimeout: connectTimeout,
                 receiveTimeout: requestTimeout,
               ),
             ),
           ),
         ),
       ),
       _timeoutInSeconds = timeout,
       _cacheTimeout = DateTime.now()
           .subtract(Duration(seconds: 1)) // allow for immediate polling
           {
    // with client-evaluated keys the server sends every strategy and they are
    // applied locally, so the context is never sent to the server
    if (!_clientEvaluated) {
      _repository.clientContext.registerChangeHandler((header) async {
        xFeatureHubHeader = header;
      });
    }
  }

  /// True if the API keys are client-evaluated (contain `*`): the server sends
  /// each feature's rollout strategies and they are evaluated locally.
  bool get clientEvaluated => _clientEvaluated;

  /// True if [apiKeys] are client-evaluated keys. Throws an [ArgumentError] if
  /// client- and server-evaluated keys are mixed.
  static bool isClientEvaluatedKeys(List<String> apiKeys) {
    final clientEvaluated = apiKeys.where((key) => key.contains('*')).length;
    if (clientEvaluated != 0 && clientEvaluated != apiKeys.length) {
      throw ArgumentError.value(
        apiKeys,
        'apiKeys',
        'Client-evaluated (containing *) and server-evaluated API keys cannot be mixed',
      );
    }
    return clientEvaluated != 0;
  }

  bool get isConnectionDead => _deadConnection;
  int get timeoutInSeconds => _timeoutInSeconds;
  DateTime get whenNextPollAllowed => _cacheTimeout;

  void success(List<FeatureEnvironmentCollection> environments) {
    final states = <FeatureState>[];
    for (var e in environments) {
      for (var f in e.features) {
        f.environmentId = e.id;
      }
      states.addAll(e.features);
    }

    _repository.notify(SSEResultState.features, states);
  }

  void decodeCacheControl(List<String> cacheControlHeader) {
    final reg = RegExp(r'max-age=(\d+)', caseSensitive: false);

    for (var header in cacheControlHeader) {
      final match = reg.firstMatch(header);
      if (match != null && match.group(0) != null) {
        try {
          var cacheAge = int.parse(match.group(0).toString().substring(8));
          if (cacheAge > 0) {
            _timeoutInSeconds = cacheAge;
          }
        } catch (e) {
          // ignore an unparseable max-age, keep the existing timeout
        }
      }
    }
  }

  void checkForCacheControl(ApiResponse response) {
    if (response.headers.containsKey('cache-control')) {
      decodeCacheControl(response.headers['cache-control']!);
    }
  }

  Future<void> decodeResponse(ApiResponse response) async {
    if (response.statusCode == 200 || response.statusCode == 236) {
      checkForCacheControl(response);

      final environments = await _api.apiDelegate.getFeatureStates_decode(
        response.body!,
      );

      success(environments);

      if (response.statusCode == 236) {
        _log.warning(
          "featurehub: this environment has gone stale and will not receive further updates.",
        );
        _deadConnection = true;
      }
    } else if (_isRejection(response.statusCode)) {
      _rejected(response.statusCode);
    }

    if (_timeoutInSeconds > 0) {
      _cacheTimeout = DateTime.now().add(Duration(seconds: _timeoutInSeconds));
    }
  }

  /// A 4xx response: FeatureHub has rejected the API key (or the environment
  /// does not exist), so asking again will not help.
  static bool _isRejection(int status) => status >= 400 && status < 500;

  /// Marks the repository failed and stops further requests.
  void _rejected(int status) {
    _log.warning(
      'featurehub: the API key was rejected ($status); no further requests '
      'will be made.',
    );
    _deadConnection = true;
    _repository.notify(SSEResultState.failure, null);
  }

  /// Requests the features, unless the previous response is still fresh
  /// (see [whenNextPollAllowed]) or [force] is true.
  ///
  /// A 4xx response means FeatureHub has rejected the API key: the repository
  /// is marked failed, [isConnectionDead] becomes true and no further
  /// requests are made (this does not throw). Other errors, such as network
  /// errors, 5xx responses and timeouts, are thrown and a later request may
  /// succeed.
  Future<ClientFeatureRepository> request({bool force = false}) async {
    if (_deadConnection) return _repository;
    if (!force && DateTime.now().isBefore(_cacheTimeout)) return _repository;

    final options = xFeatureHubHeader == null
        ? null
        : (Options()..headers = {'x-featurehub': xFeatureHubHeader});

    // added to break any caching if we change the header on the client side
    final sha = xFeatureHubHeader == null
        ? '0'
        : sha256.convert(utf8.encode(xFeatureHubHeader!)).toString();

    Future<void> fetch() async {
      try {
        final response = await _api.apiDelegate.getFeatureStates(
          _apiKeys,
          options: options,
          contextSha: sha,
        );
        await decodeResponse(response);
      } on ApiException catch (e) {
        // the client throws for error statuses
        if (!_isRejection(e.code)) rethrow;
        _rejected(e.code);
      }
    }

    final limit = requestTimeout;
    await (limit == null ? fetch() : fetch().timeout(limit));

    return _repository;
  }
}
