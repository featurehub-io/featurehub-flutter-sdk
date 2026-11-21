import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:featurehub_client_api/api.dart';
import 'package:logging/logging.dart';
import 'package:openapi_dart_common/openapi.dart';

import '../repository.dart';
import 'api_keys.dart';
import 'featurehub_transport.dart';
import 'polling_limits.dart';
import 'polling_transport.dart';

final _log = Logger('FeatureHub');

/// Polls FeatureHub Edge for an environment's features
/// (`GET <host>/features?apiKey=...`), and loads them into a repository: the
/// HTTP client behind [FeatureHubPollingTransport].
///
/// - `200`: the features, as a full set.
/// - `236`: the last features: the environment is stale
///   ([ClientFeatureRepository.markEnvironmentStale]), and no further
///   requests are made.
/// - Any 4xx: the API key is rejected; the repository is marked failed and
///   no further requests are made.
/// - Anything else (5xx, network errors, timeouts) is thrown, and a later
///   request may succeed.
///
/// A `Cache-Control: max-age` on a `200` or `236` replaces the poll interval
/// (raised to 5 seconds if it is shorter); one on any other response is
/// ignored, so a failing gateway cannot make clients poll faster. For a
/// server-evaluated key the repository's client context is sent as the
/// `x-featurehub` header.
class FeatureHubRestClient {
  final List<String> _apiKeys;
  final bool _clientEvaluated;
  final FeatureServiceApi _api;
  final ClientFeatureRepository _repository;
  String? xFeatureHubHeader;
  bool _deadConnection = false;
  DateTime _cacheTimeout;

  /// How long a response is fresh: the poll interval, or a max-age.
  Duration _freshFor;

  /// The longest a request may take, from sending it to reading the whole
  /// response. A request that takes longer throws a [TimeoutException]. Null
  /// waits indefinitely.
  final Duration? requestTimeout;

  /// Headers sent with every request, for example for a proxy or gateway.
  final Map<String, String> headers;

  /// [timeout] is the polling interval in seconds ([interval], if given,
  /// replaces it). [connectTimeout] limits how
  /// long establishing a connection may take, and [requestTimeout] how long a
  /// whole request may take; both default to waiting indefinitely.
  ///
  /// [dio] makes the requests, for example one configured with a proxy; by
  /// default one is created with [connectTimeout] (which does not apply to a
  /// [dio] given).
  FeatureHubRestClient(
    String host,
    this._apiKeys,
    this._repository, {
    int timeout = 360,
    Duration? interval,
    Duration? connectTimeout,
    this.requestTimeout,
    this.headers = const {},
    Dio? dio,
  }) : _clientEvaluated = isClientEvaluatedKeys(_apiKeys),
       _api = FeatureServiceApi(
         ApiClient(
           basePath: host,
           apiClientDelegate: DioClientDelegate(
             dio ??
                 Dio(
                   BaseOptions(
                     connectTimeout: connectTimeout,
                     receiveTimeout: requestTimeout,
                   ),
                 ),
           ),
         ),
       ),
       _freshFor = interval ?? Duration(seconds: timeout),
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

  Duration? _maxAge;

  /// The last `Cache-Control: max-age` FeatureHub gave, which replaces the
  /// poll interval; null if it has given none.
  Duration? get maxAge => _maxAge;

  bool get isConnectionDead => _deadConnection;
  int get timeoutInSeconds => _freshFor.inSeconds;
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

  /// The features in a FeatureHub polling response body (decoded JSON): an
  /// array of environments, each an object with a `features` array (absent
  /// or null means none). Together they are one full set, with each
  /// feature's `environmentId` filled in from its environment. A null
  /// environment is skipped; features that are not valid are left for the
  /// repository to skip.
  ///
  /// Throws a [FormatException] for anything else, which only something
  /// between the SDK and Edge (a proxy, a gateway) or a fault sends: a top
  /// level that is not an array, an environment that is not an object, or
  /// `features` that is not an array.
  static List<Object?> featuresFromEnvironments(Object? body) {
    if (body is! List) {
      throw FormatException(
        'FeatureHub features are not an array of environments: '
        '${body.runtimeType}',
      );
    }
    final features = <Object?>[];
    for (final environment in body) {
      if (environment == null) continue;
      if (environment is! Map) {
        throw FormatException(
          'FeatureHub sent an environment that is not an object: $environment',
        );
      }
      final states = environment['features'];
      if (states == null) continue;
      if (states is! List) {
        throw FormatException(
          'FeatureHub sent features that are not an array: $states',
        );
      }
      final id = environment['id'];
      for (final f in states) {
        features.add(
          f is Map && id is String && f['environmentId'] == null
              ? {...f, 'environmentId': id}
              : f,
        );
      }
    }
    return features;
  }

  void decodeCacheControl(List<String> cacheControlHeader) {
    final reg = RegExp(r'max-age=(\d+)', caseSensitive: false);

    for (var header in cacheControlHeader) {
      final match = reg.firstMatch(header);
      if (match != null && match.group(0) != null) {
        try {
          var cacheAge = int.parse(match.group(0).toString().substring(8));
          if (cacheAge > 0) {
            // never poll more often than the minimum, whatever it says
            final maxAge = atLeastMinimum(Duration(seconds: cacheAge));
            _freshFor = maxAge;
            _maxAge = maxAge;
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

  /// Loads the features in [response]. The next poll is allowed the timeout
  /// after [requestedAt] (when the request was made; by default now).
  Future<void> decodeResponse(
    ApiResponse response, {
    DateTime? requestedAt,
  }) async {
    if (response.statusCode == 200 || response.statusCode == 236) {
      // only from a response with features: a 304, 4xx or 5xx (perhaps from
      // a proxy or gateway) must not change how often clients poll
      checkForCacheControl(response);

      final body = response.body;
      if (body == null) {
        throw const FormatException('FeatureHub sent no features');
      }
      _repository.notify(
        SSEResultState.features,
        featuresFromEnvironments(jsonDecode(await utf8.decodeStream(body))),
      );

      if (response.statusCode == 236) {
        // the last features: stop polling, and report the environment stale
        _deadConnection = true;
        _repository.markEnvironmentStale();
      }
    } else if (_isRejection(response.statusCode)) {
      _rejected(response.statusCode);
    }

    // from when the request was made, so a poll every timeout is allowed
    if (_freshFor > Duration.zero) {
      _cacheTimeout = (requestedAt ?? DateTime.now()).add(_freshFor);
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

    final options = xFeatureHubHeader == null && headers.isEmpty
        ? null
        : (Options()
            ..headers = {...headers, 'x-featurehub': ?xFeatureHubHeader});

    // added to break any caching if we change the header on the client side
    final sha = xFeatureHubHeader == null
        ? '0'
        : sha256.convert(utf8.encode(xFeatureHubHeader!)).toString();

    final requestedAt = DateTime.now();
    Future<void> fetch() async {
      try {
        final response = await _api.apiDelegate.getFeatureStates(
          _apiKeys,
          options: options,
          contextSha: sha,
        );
        await decodeResponse(response, requestedAt: requestedAt);
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

/// Polls FeatureHub Edge, actively or passively (see [PollingTransport]),
/// through a [FeatureHubRestClient]: the transport a connection with a
/// host and an API key uses for [FeatureHubUpdateMode.activePolling] and
/// [FeatureHubUpdateMode.passivePolling].
class FeatureHubPollingTransport extends PollingTransport {
  /// The client making the requests.
  final FeatureHubRestClient client;

  /// Polls [FeatureHubTransportTarget.host] with
  /// [FeatureHubTransportTarget.apiKey], which must both be set; passively for
  /// [FeatureHubUpdateMode.passivePolling], otherwise actively.
  FeatureHubPollingTransport(FeatureHubTransportTarget target)
    : client = FeatureHubRestClient(
        _required(target.host, 'host'),
        [_required(target.apiKey, 'apiKey')],
        target.repository,
        interval: target.pollInterval,
        connectTimeout: target.connectTimeout,
        requestTimeout: target.requestTimeout,
        headers: target.headers,
        dio: target.dio,
      ),
      super(
        target.repository,
        target.pollInterval,
        active: target.mode != FeatureHubUpdateMode.passivePolling,
      );

  static String _required(String? value, String name) {
    if (value == null) {
      throw ArgumentError('Polling FeatureHub requires a $name', name);
    }
    return value;
  }

  @override
  Future<void> fetch({bool force = false}) => client.request(force: force);

  @override
  bool get isDead => client.isConnectionDead;

  /// FeatureHub's Cache-Control max-age, if it gave one, else the interval
  /// (with an interval of zero, there is no next poll, whatever max-age says).
  @override
  Duration get currentInterval => client.maxAge ?? interval;
}
