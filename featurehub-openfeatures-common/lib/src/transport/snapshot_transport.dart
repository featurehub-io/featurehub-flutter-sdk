import 'dart:async';

import 'package:dio/dio.dart';
import 'package:featurehub_client_api/api.dart';
import 'package:logging/logging.dart';

import '../feature_snapshot.dart';
import '../repository.dart';
import 'featurehub_transport.dart';
import 'polling_transport.dart';

final _log = Logger('featurehub_snapshot_client');

/// Fetches the features from your own server rather than from FeatureHub:
/// from an API that serves a [FeatureSnapshot], such as the server SDK
/// example's `GET /features` (see [ClientFeatureRepository.featureSnapshot]).
/// [FeatureSnapshotTransport] polls (or passively refreshes) through it.
///
/// - With [sendContext], the repository's client context is sent as query
///   parameters (`userkey`, and the other attributes; a list is a repeated
///   parameter), added to any already in [url], so the server evaluates the
///   features for it. Otherwise no context is sent, and the server is
///   expected to give the features as they are, rollout strategies included,
///   to be evaluated locally.
/// - The response is a snapshot, `{"sha": ..., "features": [...]}` (or just
///   the list of features), loaded as a full set of features.
/// - Its `ETag` is sent back as `If-None-Match` (for the same URL), so the
///   server can answer `304 Not Modified` while the features are unchanged.
/// - A 4xx response (other than 429) means the server has rejected
///   the request: the repository is marked failed and no further requests
///   are made. Other errors are thrown, and a later request may succeed.
class FeatureSnapshotClient {
  /// The API serving the features.
  final Uri url;

  final ClientFeatureRepository repository;

  /// True to send the client context as query parameters.
  final bool sendContext;

  /// Headers sent with each request, for example for authentication.
  final Map<String, String> headers;

  /// How long a response is fresh: [request] does nothing (unless forced)
  /// until this long after the previous request started.
  final Duration interval;

  /// How long a whole request may take (null: indefinitely).
  final Duration? requestTimeout;

  final Dio _dio;
  String? _etag;
  Uri? _etagUrl;
  DateTime _nextRequest = DateTime.fromMillisecondsSinceEpoch(0);
  bool _dead = false;

  FeatureSnapshotClient(
    String url,
    this.repository, {
    this.sendContext = true,
    this.headers = const {},
    this.interval = Duration.zero,
    Duration? connectTimeout,
    this.requestTimeout,
    Dio? dio,
  }) : url = Uri.parse(url),
       _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: connectTimeout,
               receiveTimeout: requestTimeout,
             ),
           );

  /// True once the server has rejected a request (a 4xx response).
  bool get isConnectionDead => _dead;

  /// When [request] next fetches without being forced.
  DateTime get nextRequestAllowed => _nextRequest;

  /// The `ETag` of the features last loaded.
  String? get etag => _etag;

  /// The URL requested: [url], with the client context if [sendContext].
  Uri get requestUrl {
    if (!sendContext) return url;
    final attributes = repository.clientContext.attributes;
    if (attributes.isEmpty) return url;
    return url.replace(
      queryParameters: {...url.queryParametersAll, ...attributes},
    );
  }

  /// Fetches the features, unless the previous response is still fresh (see
  /// [interval]) or [force] is true.
  Future<void> request({bool force = false}) async {
    if (_dead) return;
    final started = DateTime.now();
    if (!force && started.isBefore(_nextRequest)) return;

    final uri = requestUrl;
    final etag = uri == _etagUrl ? _etag : null;

    Future<Response<String>> fetch() => _dio.getUri<String>(
      uri,
      options: Options(
        headers: {
          'accept': 'application/json',
          ...headers,
          'if-none-match': ?etag,
        },
        responseType: ResponseType.plain,
        validateStatus: (_) => true,
      ),
    );

    final limit = requestTimeout;
    final response = await (limit == null ? fetch() : fetch().timeout(limit));

    // the context changed while waiting: these features are for the old one
    if (requestUrl != uri) return;

    final status = response.statusCode ?? 0;
    if (status == 304) {
      _nextRequest = started.add(interval);
      return;
    }
    if (status == 200) {
      final snapshot = repository.loadFeatureSnapshot(response.data);
      _etag = response.headers.value('etag') ?? '"${snapshot.sha}"';
      _etagUrl = uri;
      _nextRequest = started.add(interval);
      return;
    }
    // every 4xx but 429 (rate limiting, which your server or a gateway may
    // do) is permanent
    if (status >= 400 && status < 500 && status != 429) {
      _log.warning(
        'featurehub: $uri rejected the request ($status); no further '
        'requests will be made.',
      );
      _dead = true;
      repository.notify(SSEResultState.failure, null);
      return;
    }
    throw StateError('Fetching features from $uri gave $status');
  }
}

/// Polls your own server's features API (see [FeatureSnapshotClient]),
/// actively or passively (see [PollingTransport]): the transport a
/// connection with a `featuresUrl` and no API key uses. It never connects to
/// FeatureHub, and does not stream: only [FeatureHubUpdateMode.activePolling]
/// and [FeatureHubUpdateMode.passivePolling] are supported.
class FeatureSnapshotTransport extends PollingTransport {
  /// The client making the requests.
  final FeatureSnapshotClient client;

  /// Polls [FeatureHubTransportTarget.featuresUrl], which must be set,
  /// sending the context if [FeatureHubTransportTarget.sendsContext]. Throws an
  /// [ArgumentError] for [FeatureHubUpdateMode.streaming].
  FeatureSnapshotTransport(FeatureHubTransportTarget target)
    : client = FeatureSnapshotClient(
        _url(target),
        target.repository,
        sendContext: target.sendsContext,
        headers: target.headers,
        interval: target.pollInterval,
        connectTimeout: target.connectTimeout,
        requestTimeout: target.requestTimeout,
        dio: target.dio,
      ),
      super(
        target.repository,
        target.pollInterval,
        active: target.mode == FeatureHubUpdateMode.activePolling,
      );

  static String _url(FeatureHubTransportTarget target) {
    final url = target.featuresUrl;
    if (url == null) {
      throw ArgumentError(
        'The snapshot transport requires a featuresUrl',
        'featuresUrl',
      );
    }
    if (target.mode == FeatureHubUpdateMode.streaming) {
      throw ArgumentError(
        'Features from a featuresUrl are polled: use activePolling or '
            'passivePolling',
        'mode',
      );
    }
    return url;
  }

  @override
  Future<void> fetch({bool force = false}) => client.request(force: force);

  @override
  bool get isDead => client.isConnectionDead;

  @override
  Duration get currentInterval => interval;
}
