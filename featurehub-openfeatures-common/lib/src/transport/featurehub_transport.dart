import 'package:dio/dio.dart';
import 'package:featurehub_sse_client/featurehub_sse_client.dart'
    show ReconnectPolicy;
import 'package:http/http.dart' as http;

import '../repository.dart';

/// How a [FeatureHubConnection] keeps its repository up to date.
enum FeatureHubUpdateMode {
  /// Server-sent events from FeatureHub Edge ([FeatureHubSseTransport]):
  /// updates arrive as soon as they are made. FeatureHub only: your own
  /// server's features API is polled.
  streaming,

  /// Fetch only when features are read (see
  /// [FeatureHubConnection.refreshIfStale]) and the previous fetch is older
  /// than [FeatureHubConnection.pollInterval]; no polls of its own.
  passivePolling,

  /// Poll every [FeatureHubConnection.pollInterval] (or a FeatureHub
  /// Cache-Control max-age, which replaces it).
  activePolling,
}

/// Moves features into a repository: the built-in transports stream or poll
/// FeatureHub, or poll your own server, and you can write your own (over
/// WebSockets, another SSE client, a message queue, ...) and give it to a
/// provider's or connection's `transportFactory`.
///
/// A transport is created with a [FeatureHubTransportTarget], and gives the
/// features to its [FeatureHubTransportTarget.repository] with
/// [ClientFeatureRepository.notify]:
///
/// - `notify(SSEResultState.features, features)`: the full set of features
///   (a `List<FeatureState>`, or their JSON). The first makes the repository
///   ready, which is what initialization waits for; features missing from a
///   later set are removed.
/// - `notify(SSEResultState.feature, feature)`: one feature added or
///   updated (a newer version, or a new value for the context).
/// - `notify(SSEResultState.deleteFeature, feature)`: one feature deleted.
/// - `notify(SSEResultState.bye, null)`: the connection was lost and is
///   being re-established. Providers stay ready (they do not report stale):
///   the features arrive again on reconnection.
/// - `notify(SSEResultState.failure, null)`: the source rejected the
///   connection for good (for example, an invalid API key); stop trying.
///   Before any features, the provider's initialization fails; after them,
///   the provider reports stale for good and keeps resolving from the last
///   features.
/// - [ClientFeatureRepository.markEnvironmentStale]: the source says the
///   environment is stale (FeatureHub's `236`, or `edge.stale`), after giving
///   the last features. Providers report stale for good, and keep resolving
///   from those features; stop.
///
/// FeatureHub's own event stream sends exactly these, as `event:` names
/// (`features`, `feature`, `delete_feature`, `bye`, `failure`) with JSON
/// `data:`, so a transport carrying them can pass each on with
/// `notify(SSEResultStateExtension.fromJson(name), jsonDecode(data))`. A
/// `config` event with `{"edge.stale": true}` means the environment will
/// not change again: call [ClientFeatureRepository.markEnvironmentStale]
/// and stop.
///
/// [FeatureSnapshot.from] reads the snapshots your own server serves (see
/// [ClientFeatureRepository.featureSnapshot]).
abstract interface class FeatureHubTransport {
  /// Starts fetching features. The returned future may complete before any
  /// arrive: initialization waits (up to its timeout) for the repository to
  /// become ready.
  Future<void> start();

  /// The context changed, when the context is sent to the source (see
  /// [FeatureHubTransportTarget.sendsContext]): fetch the features for the
  /// new one, [FeatureHubTransportTarget.contextAttributes] or
  /// [FeatureHubTransportTarget.contextHeader], and notify them as a full
  /// set. The caller waits (up to its timeout) for that notification.
  Future<void> contextChanged();

  /// Passive polling: fetch the features if they are older than
  /// [FeatureHubTransportTarget.pollInterval]. Called as features are read
  /// (by the server provider before each resolution); do nothing if the
  /// transport has no passive polling.
  Future<void> refreshIfStale();

  /// Stops, releasing any connections.
  Future<void> close();
}

/// The reconnect policy FeatureHub's streaming connections use unless one is
/// given: 3 seconds after a network error or a dropped stream, 30 seconds
/// after any other non-200 response but a 4xx (a 5xx, or an invalid 1xx or
/// 3xx), each doubling with every consecutive failure up to a 5 minute cap,
/// retrying indefinitely. A 4xx stops for good (see
/// [featureHubShouldRetryStatus]). Give your own [ReconnectPolicy] (its
/// `delay`, `serverErrorDelay`, `backoffMultiplier`, `maxDelay`,
/// `maxAttempts`, ...) to change any of these.
///
/// Whenever the connection stops for good (a 4xx, a status the policy does
/// not retry, or running out of `maxAttempts`), the repository is notified of
/// a failure: before any features the provider fails to initialize, after
/// them it reports stale.
const defaultReconnectPolicy = ReconnectPolicy(
  backoffMultiplier: 2,
  maxDelay: Duration(minutes: 5),
  shouldRetryStatus: featureHubShouldRetryStatus,
);

/// Which non-200 statuses a FeatureHub streaming connection retries: every
/// one but a 4xx. A 4xx is a rejection (the API key or environment), so it is
/// permanent; a 5xx is a temporary failure; and a 1xx or 3xx is not a valid
/// response, treated as temporary too.
bool featureHubShouldRetryStatus(int statusCode) =>
    statusCode < 400 || statusCode >= 500;

/// Creates a transport for a connection (see [FeatureHubTransport]).
typedef FeatureHubTransportFactory =
    FeatureHubTransport Function(FeatureHubTransportTarget target);

/// What a [FeatureHubTransport] is created with: the repository to fill,
/// and the connection's settings, which a transport uses as it sees fit.
class FeatureHubTransportTarget {
  /// The repository to give the features to.
  final ClientFeatureRepository repository;

  /// The FeatureHub Edge URL, if given.
  final String? host;

  /// The FeatureHub API key, if given.
  final String? apiKey;

  /// Your own server's features API, if given.
  final String? featuresUrl;

  final FeatureHubUpdateMode mode;

  /// How often to poll, or with passive polling how old features may get.
  final Duration pollInterval;

  /// Headers to send with every request, for example for a proxy, gateway or
  /// authentication.
  final Map<String, String> headers;

  final ReconnectPolicy reconnectPolicy;
  final Duration? connectTimeout;
  final Duration? requestTimeout;

  /// The [Dio] given for HTTP requests (for example configured with a
  /// proxy), if any.
  final Dio? dio;

  /// The [http.Client] given for streaming (for example configured with a
  /// proxy), if any.
  final http.Client? httpClient;

  /// True if the source is told the context, so it gives features evaluated
  /// for it: [contextChanged](FeatureHubTransport.contextChanged) must then
  /// fetch them again. False if features are evaluated locally from their
  /// strategies, so the context is never sent.
  final bool sendsContext;

  const FeatureHubTransportTarget({
    required this.repository,
    this.host,
    this.apiKey,
    this.featuresUrl,
    this.mode = FeatureHubUpdateMode.streaming,
    this.pollInterval = const Duration(seconds: 30),
    this.headers = const {},
    this.reconnectPolicy = defaultReconnectPolicy,
    this.connectTimeout,
    this.requestTimeout,
    this.dio,
    this.httpClient,
    this.sendsContext = false,
  });

  /// The context to fetch features for, by attribute (`userkey`, `country`,
  /// ...); empty if the context is not sent.
  Map<String, List<String>> get contextAttributes =>
      sendsContext ? repository.clientContext.attributes : const {};

  /// The context in FeatureHub's `x-featurehub` header form, or null (no
  /// context, or it is not sent).
  String? get contextHeader =>
      sendsContext ? repository.clientContext.generateHeader() : null;
}
