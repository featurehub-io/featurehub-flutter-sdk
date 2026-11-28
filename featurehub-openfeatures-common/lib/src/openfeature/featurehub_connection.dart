import 'dart:async';

import 'package:dio/dio.dart';
import 'package:featurehub_sse_client/featurehub_sse_client.dart'
    show ReconnectPolicy;
import 'package:http/http.dart' as http;
import 'package:rxdart/rxdart.dart';

import '../repository.dart';
import '../transport/api_keys.dart';
import '../transport/featurehub_polling_transport.dart';
import '../transport/featurehub_sse_transport.dart';
import '../transport/featurehub_transport.dart';
import '../transport/polling_limits.dart';
import '../transport/snapshot_transport.dart';
import 'context_mapper.dart';

/// A connection that keeps a [ClientFeatureRepository] up to date, through a
/// [FeatureHubTransport]:
///
/// - With a [host] and [apiKey], it streams or polls FeatureHub Edge. With a
///   client-evaluated API key (containing `*`) every feature's rollout
///   strategies are delivered and evaluated locally for each context (see
///   [ClientFeatureRepository.evaluate]). With a server-evaluated key, Edge
///   evaluates the features for a single context, set with [setContext].
/// - With a [featuresUrl] instead, it never connects to FeatureHub: it polls
///   (or passively refreshes) the features from your own server, through a
///   [FeatureSnapshotClient]. With [sendContext] the server evaluates them
///   for the context, set with [setContext] (as for a server-evaluated key);
///   otherwise their strategies are evaluated locally (as for a
///   client-evaluated key).
/// - With a `transportFactory`, your own transport fetches the features (see
///   [FeatureHubTransport]), from wherever it likes.
/// - With none of these it never fetches features: the repository is filled
///   by other means, such as feature stores, and any rollout strategies the
///   features have are evaluated locally.
class FeatureHubConnection {
  /// The FeatureHub Edge URL, or null if it does not connect to FeatureHub.
  final String? host;

  /// The API key, or null if it does not connect to FeatureHub.
  final String? apiKey;

  /// The URL of your own server's features API, if the features come from
  /// there (see [FeatureSnapshotClient]).
  final String? featuresUrl;

  /// Without an API key (with a [featuresUrl] or a custom transport): true
  /// to send the context, so the source evaluates the features for it.
  final bool sendContext;
  final ClientFeatureRepository repository;

  /// How the features are fetched. By default [FeatureHubUpdateMode.streaming]
  /// from FeatureHub, for a client- or a server-evaluated key alike, and
  /// [FeatureHubUpdateMode.activePolling] from a [featuresUrl] (which is only
  /// polled). The providers always give one: the client provider polls
  /// passively unless told otherwise, and the server provider streams.
  final FeatureHubUpdateMode mode;
  final Duration pollInterval;

  /// Headers sent with every request: to FeatureHub (polling, and streaming
  /// except in browsers, whose `EventSource` cannot send them) and to
  /// [featuresUrl]. Custom transports are given them too.
  final Map<String, String> headers;

  /// True if features are evaluated locally: a client-evaluated [apiKey]; a
  /// [featuresUrl] or custom transport without [sendContext]; or no source.
  final bool clientEvaluated;

  /// True if the transport was given rather than built in.
  final bool customTransport;
  late final FeatureHubTransport _transport;
  String? _contextHeader;

  /// The context whose features the repository holds.
  String? _heldHeader;
  StreamSubscription<Readyness>? _held;
  DateTime? _contextChangedAt;
  bool _started = false;

  /// [connectTimeout] limits how long establishing a connection may take
  /// (in browsers, only for polling: `EventSource` connections are controlled
  /// by the browser). [requestTimeout] limits how long a polling request may
  /// take, or how long a streaming connection attempt waits for the stream to
  /// open (a streaming attempt that times out is retried according to
  /// [reconnectPolicy]). [readTimeout] limits how long an open streaming
  /// connection may go without data before it is dropped and reconnected
  /// (`dart:io` only); FeatureHub may send nothing for up to 5 minutes, so a
  /// shorter one is warned about. All default to waiting indefinitely.
  ///
  /// [dio] makes the polling requests (to FeatureHub or [featuresUrl]) and
  /// [httpClient] the streaming connections (on `dart:io`), for example
  /// configured with a proxy; by default they are created (with
  /// [connectTimeout], which does not apply to those given).
  ///
  /// [transportFactory] replaces the built-in transports with your own (see
  /// [FeatureHubTransport]); [transport] gives one directly (for tests).
  ///
  /// Throws an [ArgumentError] for a [featuresUrl] together with a [host] or
  /// [apiKey], or with [FeatureHubUpdateMode.streaming] for the built-in
  /// transport (your server is polled).
  FeatureHubConnection({
    this.host,
    this.apiKey,
    this.featuresUrl,
    this.sendContext = true,
    this.headers = const {},
    ClientFeatureRepository? repository,
    FeatureHubUpdateMode? mode,
    this.pollInterval = const Duration(seconds: 30),
    ReconnectPolicy reconnectPolicy = defaultReconnectPolicy,
    Duration? connectTimeout,
    Duration? requestTimeout,
    Duration? readTimeout,
    Dio? dio,
    http.Client? httpClient,
    FeatureHubTransportFactory? transportFactory,
    FeatureHubTransport? transport,
  }) : repository = repository ?? ClientFeatureRepository(),
       mode =
           mode ??
           (featuresUrl == null
               ? FeatureHubUpdateMode.streaming
               : FeatureHubUpdateMode.activePolling),
       customTransport = transportFactory != null || transport != null,
       clientEvaluated = apiKey != null
           ? isClientEvaluatedKeys([apiKey])
           : featuresUrl != null ||
                 transportFactory != null ||
                 transport != null
           ? !sendContext
           : true {
    final host = this.host;
    final apiKey = this.apiKey;
    final featuresUrl = this.featuresUrl;
    final builtIn = !customTransport;
    if (featuresUrl != null) {
      if (host != null || apiKey != null) {
        throw ArgumentError(
          'A featuresUrl cannot be used with a host or apiKey',
          'featuresUrl',
        );
      }
      if (this.mode == FeatureHubUpdateMode.streaming && builtIn) {
        throw ArgumentError(
          'Features from a featuresUrl are polled: use activePolling or '
              'passivePolling',
          'mode',
        );
      }
    }

    if (this.mode != FeatureHubUpdateMode.streaming) {
      // zero polls once; otherwise at least 5 seconds
      validatePollInterval(pollInterval);
    }

    final target = FeatureHubTransportTarget(
      repository: this.repository,
      host: host,
      apiKey: apiKey,
      featuresUrl: featuresUrl,
      mode: this.mode,
      pollInterval: pollInterval,
      headers: headers,
      reconnectPolicy: reconnectPolicy,
      connectTimeout: connectTimeout,
      requestTimeout: requestTimeout,
      readTimeout: readTimeout,
      dio: dio,
      httpClient: httpClient,
      sendsContext: !clientEvaluated,
    );
    _transport =
        transport ?? transportFactory?.call(target) ?? _builtIn(target);
  }

  /// The built-in transport for [target]:
  ///
  /// - a host and an API key: FeatureHub, by [FeatureHubSseTransport] when
  ///   streaming, or [FeatureHubPollingTransport] for active or passive
  ///   polling;
  /// - no API key, and a features URL: your own server, by
  ///   [FeatureSnapshotTransport] (active or passive polling only);
  /// - neither: none (the repository is filled by stores).
  static FeatureHubTransport _builtIn(FeatureHubTransportTarget target) {
    if (target.host != null && target.apiKey != null) {
      return target.mode == FeatureHubUpdateMode.streaming
          ? FeatureHubSseTransport(target)
          : FeatureHubPollingTransport(target);
    }
    if (target.featuresUrl != null) return FeatureSnapshotTransport(target);
    return const _NoTransport();
  }

  /// True if this connects to FeatureHub (it has a [host] and an [apiKey]).
  bool get connectsToFeatureHub => host != null && apiKey != null;

  /// What the features are fetched from, for messages: FeatureHub, your
  /// server, your transport, or nothing (the stores).
  String get sourceDescription => customTransport
      ? 'The features transport'
      : connectsToFeatureHub
      ? 'FeatureHub'
      : featuresUrl != null
      ? 'The features server ($featuresUrl)'
      : 'The feature stores';

  /// Starts fetching features. With a server-evaluated key, [context] is the
  /// context to fetch them for.
  Future<void> start({MappedContext? context}) async {
    if (_started) return;
    _started = true;
    if (!clientEvaluated && context != null) {
      context.applyTo(repository.clientContext);
      _contextHeader = context.header;
      repository.clientContext.build();
    }
    // a full set is the current context's (features a store already gave
    // count as the first context's)
    _held = repository.readynessStream
        .where((r) => r == Readyness.Ready)
        .listen((_) => _heldHeader = _contextHeader);
    if (repository.readyness != Readyness.NotReady) {
      _heldHeader = _contextHeader;
    }
    await _transport.start();
  }

  /// Waits until the repository has features (readiness [Readyness.Ready],
  /// or [Readyness.Stale] if the source stopped for good with them) or has
  /// failed, for at most [timeout]. Returns the readiness at that point.
  Future<Readyness> waitForReady(Duration timeout) async {
    final current = repository.readyness;
    if (current != Readyness.NotReady) return current;
    return repository.readynessStream
        .firstWhere((r) => r != Readyness.NotReady)
        .timeout(timeout, onTimeout: () => repository.readyness);
  }

  /// True while a context change is in progress: the features are sent the
  /// context ([clientEvaluated] is false), the context has changed, and the
  /// new context's features have not arrived yet. The features held are then
  /// the previous context's, and MUST NOT be resolved as the new one's (see
  /// [setContext]). False once the source has stopped for good, as nothing
  /// more can be fetched (see [contextUnavailable]).
  bool get contextChangePending =>
      !clientEvaluated &&
      repository.readyness == Readyness.Stale &&
      !repository.connectionFailed &&
      !repository.environmentStale;

  /// True when the source has stopped for good and the context is not the
  /// one whose features are held: nothing can fetch the features for it, so
  /// they are unavailable, and the held ones MUST NOT be resolved for it.
  /// Changing back to the held context makes it false again.
  bool get contextUnavailable =>
      !clientEvaluated &&
      (repository.connectionFailed || repository.environmentStale) &&
      _contextHeader != _heldHeader;

  /// When the context change in progress ([contextChangePending]) started,
  /// or null if there is none.
  DateTime? get contextChangeStartedAt =>
      contextChangePending ? _contextChangedAt : null;

  /// Server-evaluated keys: fetches the features for [context] (if it differs
  /// from the current one) and waits, for at most [timeout], for them.
  /// Returns the readiness afterwards: [Readyness.Ready] once the context's
  /// features have arrived. Does nothing for client-evaluated keys.
  ///
  /// The connection holds features for one context at a time. While a
  /// context change is in progress ([contextChangePending]) readiness is
  /// [Readyness.Stale]: the old context's features are still held, but they
  /// are not the new context's. The new context's features make it
  /// [Readyness.Ready]. Called again for the context whose features are still
  /// awaited, it waits again (for at most [timeout]). It stops waiting if
  /// the source stops for good meanwhile. Once the source has stopped for
  /// good ([ClientFeatureRepository.connectionFailed],
  /// [ClientFeatureRepository.environmentStale]) nothing can be fetched: it
  /// only records the context, and the last features are kept for the
  /// context they belong to ([contextUnavailable] for any other).
  Future<Readyness> setContext(MappedContext context, Duration timeout) async {
    if (clientEvaluated) return repository.readyness;
    final header = context.header;
    if (repository.connectionFailed || repository.environmentStale) {
      _contextHeader = header;
      return repository.readyness;
    }

    if (header == _contextHeader) {
      // still waiting for this context's features: wait again
      return contextChangePending
          ? _contextArrived(timeout)
          : repository.readyness;
    }
    _contextHeader = header;
    _contextChangedAt = DateTime.now();

    repository.contextChanging();
    // readiness is not Ready now, so the next Ready is the new context's
    final refreshed = _contextArrived(timeout);

    context.applyTo(repository.clientContext);
    repository.clientContext.build();
    // a transport may only return once it has the features (a poll): the
    // wait is still bounded by [timeout]
    final changed = _transport.contextChanged();
    try {
      await Future.any<Object?>([changed, refreshed]);
    } finally {
      // an error once the wait is over is not this call's
      changed.ignore();
    }

    return refreshed;
  }

  /// The readiness once the context's features arrive or the source stops
  /// for good, or after [timeout].
  Future<Readyness> _contextArrived(Duration timeout) =>
      Rx.merge<Object>([
            repository.readynessStream.where(
              (r) => r == Readyness.Ready || r == Readyness.Failed,
            ),
            repository.connectionFailedStream.where((failed) => failed),
            repository.environmentStaleStream.where((stale) => stale),
          ]).first
          .then((_) => repository.readyness)
          .timeout(timeout, onTimeout: () => repository.readyness);

  /// Passive polling: fetches the features if they are older than
  /// [pollInterval]. Does nothing in the other modes.
  Future<void> refreshIfStale() => _transport.refreshIfStale();

  Future<void> close() async {
    await _held?.cancel();
    _held = null;
    await _transport.close();
  }
}

/// No connection to FeatureHub: the repository is filled by other means.
class _NoTransport implements FeatureHubTransport {
  const _NoTransport();

  @override
  Future<void> start() async {}

  @override
  Future<void> contextChanged() async {}

  @override
  Future<void> refreshIfStale() async {}

  @override
  Future<void> close() async {}
}
