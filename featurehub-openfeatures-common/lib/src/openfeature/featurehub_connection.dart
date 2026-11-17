import 'dart:async';

import 'package:dio/dio.dart';
import 'package:featurehub_sse_client/featurehub_sse_client.dart'
    show ReconnectPolicy;
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import '../../featurehub_config.dart';
import '../repository.dart';
import 'feature_snapshot_client.dart';
import 'featurehub_transport.dart';
import '../sse_client.dart'
    if (dart.library.io) '../sse_client_dartio.dart'
    if (dart.library.js_interop) '../sse_client_web.dart';
import 'context_mapper.dart';

final _log = Logger('featurehub_connection');

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
  bool _started = false;

  /// [connectTimeout] limits how long establishing a connection may take
  /// (in browsers, only for polling: `EventSource` connections are controlled
  /// by the browser). [requestTimeout] limits how long a polling request may
  /// take, or how long a streaming connection attempt waits for the stream to
  /// open (a streaming attempt that times out is retried according to
  /// [reconnectPolicy]). Both default to waiting indefinitely.
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
    this.mode = FeatureHubUpdateMode.streaming,
    this.pollInterval = const Duration(seconds: 30),
    ReconnectPolicy reconnectPolicy = const ReconnectPolicy(),
    Duration? connectTimeout,
    Duration? requestTimeout,
    Dio? dio,
    http.Client? httpClient,
    FeatureHubTransportFactory? transportFactory,
    FeatureHubTransport? transport,
  }) : repository = repository ?? ClientFeatureRepository(),
       customTransport = transportFactory != null || transport != null,
       clientEvaluated = apiKey != null
           ? FeatureHubConfig.isClientEvaluatedKeys([apiKey])
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
      if (mode == FeatureHubUpdateMode.streaming && builtIn) {
        throw ArgumentError(
          'Features from a featuresUrl are polled: use the polling or passive '
              'mode',
          'mode',
        );
      }
    }

    final target = FeatureHubTransportTarget(
      repository: this.repository,
      host: host,
      apiKey: apiKey,
      featuresUrl: featuresUrl,
      mode: mode,
      pollInterval: pollInterval,
      headers: headers,
      reconnectPolicy: reconnectPolicy,
      connectTimeout: connectTimeout,
      requestTimeout: requestTimeout,
      dio: dio,
      httpClient: httpClient,
      sendsContext: !clientEvaluated,
    );
    _transport =
        transport ?? transportFactory?.call(target) ?? _builtIn(target);
  }

  static FeatureHubTransport _builtIn(FeatureHubTransportTarget target) {
    final host = target.host;
    final apiKey = target.apiKey;
    final featuresUrl = target.featuresUrl;
    final active = target.mode == FeatureHubUpdateMode.polling;

    if (featuresUrl != null) {
      return _PollingTransport.snapshots(
        FeatureSnapshotClient(
          featuresUrl,
          target.repository,
          sendContext: target.sendsContext,
          headers: target.headers,
          interval: target.pollInterval,
          connectTimeout: target.connectTimeout,
          requestTimeout: target.requestTimeout,
          dio: target.dio,
        ),
        target.repository,
        target.pollInterval,
        active: active,
      );
    }
    if (host == null || apiKey == null) return const _NoTransport();
    if (target.mode == FeatureHubUpdateMode.streaming) {
      return _StreamingTransport(target, host, apiKey);
    }
    return _PollingTransport(target, host, apiKey, active: active);
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
    await _transport.start();
  }

  /// Waits until the repository has features (or has failed), for at most
  /// [timeout]. Returns the readiness at that point.
  Future<Readyness> waitForReady(Duration timeout) async {
    final current = repository.readyness;
    if (current != Readyness.NotReady) return current;
    return repository.readynessStream
        .firstWhere((r) => r != Readyness.NotReady)
        .timeout(timeout, onTimeout: () => repository.readyness);
  }

  /// Server-evaluated keys: fetches the features for [context] (if it differs
  /// from the current one) and waits, for at most [timeout], for them.
  /// Returns the readiness afterwards. Does nothing for client-evaluated keys.
  Future<Readyness> setContext(MappedContext context, Duration timeout) async {
    if (clientEvaluated) return repository.readyness;

    final header = context.header;
    if (header == _contextHeader) return repository.readyness;
    _contextHeader = header;

    // the next ready (or failed) notification is the refreshed bundle
    final refreshed = repository.readynessStream
        .skip(1)
        .firstWhere((r) => r != Readyness.NotReady)
        .timeout(timeout, onTimeout: () => repository.readyness);

    context.applyTo(repository.clientContext);
    repository.clientContext.build();
    await _transport.contextChanged();

    return refreshed;
  }

  /// Passive mode: fetches the features if they are older than
  /// [pollInterval]. Does nothing in the other modes.
  Future<void> refreshIfStale() => _transport.refreshIfStale();

  Future<void> close() async {
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

class _StreamingTransport implements FeatureHubTransport {
  final EventSourceRepositoryListener _listener;

  _StreamingTransport(
    FeatureHubTransportTarget target,
    String host,
    String apiKey,
  ) : _listener = EventSourceRepositoryListener(
        host,
        apiKey,
        target.repository,
        doInit: false,
        reconnectPolicy: target.reconnectPolicy,
        connectTimeout: target.connectTimeout,
        requestTimeout: target.requestTimeout,
        headers: target.headers,
        client: target.httpClient,
      );

  @override
  Future<void> start() => _listener.init();

  // the listener reconnects with the new context itself
  @override
  Future<void> contextChanged() async {}

  @override
  Future<void> refreshIfStale() async {}

  @override
  Future<void> close() async => _listener.close();
}

class _PollingTransport implements FeatureHubTransport {
  final Future<void> Function({bool force}) _fetch;
  final bool Function() _isDead;

  /// When the server allows the next request (after a cache-control max-age).
  final DateTime Function() _nextAllowed;
  final ClientFeatureRepository _repository;
  bool _closed = false;
  final Duration _interval;
  final bool _active;
  Timer? _timer;
  Future<void>? _inFlight;

  /// In passive mode, after a failed request: no further (unforced) request
  /// is made before this, so an outage does not cost a request per
  /// evaluation.
  DateTime? _retryAfter;

  _PollingTransport(
    FeatureHubTransportTarget target,
    String host,
    String apiKey, {
    required bool active,
  }) : this._(
         FeatureHubConfig(
           host,
           [apiKey],
           target.repository,
           timeout: target.pollInterval.inSeconds,
           connectTimeout: target.connectTimeout,
           requestTimeout: target.requestTimeout,
           headers: target.headers,
           dio: target.dio,
         ),
         target.repository,
         target.pollInterval,
         active,
       );

  _PollingTransport._(
    FeatureHubConfig config,
    this._repository,
    this._interval,
    this._active,
  ) : _fetch = config.request,
      _isDead = (() => config.isConnectionDead),
      _nextAllowed = (() => config.whenNextPollAllowed);

  /// Polls your own server through [client].
  _PollingTransport.snapshots(
    FeatureSnapshotClient client,
    this._repository,
    this._interval, {
    required this._active,
  }) : _fetch = client.request,
       _isDead = (() => client.isConnectionDead),
       _nextAllowed = (() => client.nextRequestAllowed);

  Future<void> _request({bool force = false}) {
    // one request at a time; a forced request waits for the current one
    final previous = _inFlight ?? Future<void>.value();
    final next = previous.then((_) async {
      final retryAfter = _retryAfter;
      if (!force && retryAfter != null && DateTime.now().isBefore(retryAfter)) {
        return;
      }
      // a rejected key (4xx) marks the repository failed and the config
      // dead, which stops polling; other errors are retried next time
      try {
        await _fetch(force: force);
        _retryAfter = null;
      } catch (e) {
        _log.fine('FeatureHub request failed: $e');
        if (!_active) _retryAfter = DateTime.now().add(_interval);
      }
    });
    _inFlight = next;
    return next.whenComplete(() {
      if (identical(_inFlight, next)) _inFlight = null;
    });
  }

  @override
  Future<void> start() async {
    if (_repository.readyness == Readyness.Ready) {
      // already ready (e.g. from a store's features): fetch in the background
      unawaited(_request().then((_) => _scheduleNext()));
    } else {
      await _request();
      _scheduleNext();
    }
  }

  /// Polling mode: the next poll, the interval after this one (or later, if
  /// the server's cache-control asks for it). Each poll is scheduled once the
  /// previous one has finished, so none is skipped as still fresh.
  void _scheduleNext() {
    if (!_active || _closed || _isDead()) return;
    var wait = _nextAllowed().difference(DateTime.now());
    if (wait < _interval) wait = _interval;
    _timer = Timer(wait, () async {
      _timer = null;
      await _request(force: true);
      _scheduleNext();
    });
  }

  @override
  Future<void> contextChanged() => _request(force: true);

  @override
  Future<void> refreshIfStale() => _active ? Future.value() : _request();

  @override
  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    _timer = null;
  }
}
