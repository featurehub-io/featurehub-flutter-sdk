import 'dart:async';

import 'package:featurehub_sse_client/featurehub_sse_client.dart'
    show ReconnectPolicy;
import 'package:logging/logging.dart';

import '../../featurehub_config.dart';
import '../repository.dart';
import '../sse_client.dart'
    if (dart.library.io) '../sse_client_dartio.dart'
    if (dart.library.js_interop) '../sse_client_web.dart';
import 'context_mapper.dart';

final _log = Logger('featurehub_connection');

/// How a [FeatureHubConnection] keeps its repository up to date.
enum FeatureHubUpdateMode {
  /// Server-sent events: updates arrive as soon as they are made.
  streaming,

  /// Poll every [FeatureHubConnection.pollInterval].
  polling,

  /// Only fetch when the features are read (see
  /// [FeatureHubConnection.refreshIfStale]) and the previous fetch is older
  /// than [FeatureHubConnection.pollInterval].
  passive,
}

/// Moves features from FeatureHub into a repository.
abstract interface class FeatureHubTransport {
  Future<void> start();

  /// The repository's client context changed (server-evaluated keys only):
  /// fetch the features for the new context.
  Future<void> contextChanged();

  /// Fetch the features if they are stale (passive mode).
  Future<void> refreshIfStale();

  Future<void> close();
}

/// A connection to FeatureHub Edge that keeps a [ClientFeatureRepository] up
/// to date, by streaming or polling, for one API key.
///
/// With a client-evaluated API key (containing `*`) every feature's rollout
/// strategies are delivered and evaluated locally for each context (see
/// [ClientFeatureRepository.evaluate]). With a server-evaluated key, Edge
/// evaluates the features for a single context, set with [setContext].
class FeatureHubConnection {
  final String host;
  final String apiKey;
  final ClientFeatureRepository repository;
  final FeatureHubUpdateMode mode;
  final Duration pollInterval;
  final bool clientEvaluated;
  late final FeatureHubTransport _transport;
  String? _contextHeader;
  bool _started = false;

  /// [connectTimeout] limits how long establishing a connection may take
  /// (in browsers, only for polling: `EventSource` connections are controlled
  /// by the browser). [requestTimeout] limits how long a polling request may
  /// take, or how long a streaming connection attempt waits for the stream to
  /// open (a streaming attempt that times out is retried according to
  /// [reconnectPolicy]). Both default to waiting indefinitely.
  FeatureHubConnection({
    required this.host,
    required this.apiKey,
    ClientFeatureRepository? repository,
    this.mode = FeatureHubUpdateMode.streaming,
    this.pollInterval = const Duration(seconds: 30),
    ReconnectPolicy reconnectPolicy = const ReconnectPolicy(),
    Duration? connectTimeout,
    Duration? requestTimeout,
    FeatureHubTransport? transport,
  }) : repository = repository ?? ClientFeatureRepository(),
       clientEvaluated = FeatureHubConfig.isClientEvaluatedKeys([apiKey]) {
    _transport =
        transport ??
        (mode == FeatureHubUpdateMode.streaming
            ? _StreamingTransport(
                host,
                apiKey,
                this.repository,
                reconnectPolicy,
                connectTimeout,
                requestTimeout,
              )
            : _PollingTransport(
                host,
                apiKey,
                this.repository,
                pollInterval,
                active: mode == FeatureHubUpdateMode.polling,
                connectTimeout: connectTimeout,
                requestTimeout: requestTimeout,
              ));
  }

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

class _StreamingTransport implements FeatureHubTransport {
  final EventSourceRepositoryListener _listener;

  _StreamingTransport(
    String host,
    String apiKey,
    ClientFeatureRepository repository,
    ReconnectPolicy reconnectPolicy,
    Duration? connectTimeout,
    Duration? requestTimeout,
  ) : _listener = EventSourceRepositoryListener(
        host,
        apiKey,
        repository,
        doInit: false,
        reconnectPolicy: reconnectPolicy,
        connectTimeout: connectTimeout,
        requestTimeout: requestTimeout,
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
  final FeatureHubConfig _config;
  final ClientFeatureRepository _repository;
  final Duration _interval;
  final bool _active;
  Timer? _timer;
  Future<void>? _inFlight;

  _PollingTransport(
    String host,
    String apiKey,
    this._repository,
    this._interval, {
    required this._active,
    Duration? connectTimeout,
    Duration? requestTimeout,
  }) : _config = FeatureHubConfig(
         host,
         [apiKey],
         _repository,
         timeout: _interval.inSeconds,
         connectTimeout: connectTimeout,
         requestTimeout: requestTimeout,
       );

  Future<void> _request({bool force = false}) {
    // one request at a time; a forced request waits for the current one
    final previous = _inFlight ?? Future<void>.value();
    final next = previous.then((_) async {
      // a rejected key (4xx) marks the repository failed and the config
      // dead, which stops polling; other errors are retried next time
      try {
        await _config.request(force: force);
      } catch (e) {
        _log.fine('FeatureHub request failed: $e');
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
      unawaited(_request());
    } else {
      await _request();
    }
    if (_active && !_config.isConnectionDead) {
      _timer = Timer.periodic(_interval, (_) {
        if (_config.isConnectionDead) {
          _timer?.cancel();
        } else {
          _request();
        }
      });
    }
  }

  @override
  Future<void> contextChanged() => _request(force: true);

  @override
  Future<void> refreshIfStale() => _active ? Future.value() : _request();

  @override
  Future<void> close() async {
    _timer?.cancel();
    _timer = null;
  }
}
