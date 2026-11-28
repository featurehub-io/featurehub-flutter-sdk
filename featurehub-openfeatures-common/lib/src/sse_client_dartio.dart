import 'dart:async';

import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_sse_client/featurehub_sse_client.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import 'transport/api_keys.dart';
import 'transport/edge_request.dart';
import 'transport/featurehub_transport.dart'
    show
        decodeFeatureHubEventData,
        defaultReconnectPolicy,
        featureHubConfigIsStale,
        featureHubEventShowsConnectionWorks;
import 'transport/streaming_limits.dart';
import 'repository.dart';

final _log = Logger('featurehub_io_eventsource');

/// Listens to the FeatureHub event stream and feeds the repository.
///
/// Reconnection is handled by the underlying [EventSource] (see
/// [ReconnectPolicy] and [defaultReconnectPolicy]): by default it reconnects
/// when the server closes the stream, on network errors and on any non-200
/// response but a 4xx, which stops it. Whenever the event source stops for
/// good, the repository is notified of a failure. This listener only closes
/// the connection when the server reports a failure or the edge is stale, and
/// opens a new one when the client context changes, until it is closed.
///
/// With a client-evaluated API key (containing `*`) the server sends every
/// feature's rollout strategies, which the repository applies locally, so the
/// client context is never sent and a context change needs no reconnection.
///
/// Each connection is to `<host>/features/<key>?contextSha=...&sdk_version=2`
/// ([edgeSdkVersion]): the event source keeps the last event id and sends it
/// as `Last-Event-ID` when it reconnects, so Edge may hold the connection
/// with nothing to send and then say `bye`, which ends it cleanly. A new
/// context is a new event source, so it never sends the old context's id. A
/// connection that ends within [shortConnectionThreshold] of opening is a
/// failed attempt, whatever it sent.
class EventSourceRepositoryListener {
  final ClientFeatureRepository _repository;
  StreamSubscription<Event>? _subscription;
  final EdgeHost _host;
  final String _apiKey;
  final bool _clientEvaluated;
  final ReconnectPolicy _reconnectPolicy;
  final Duration? _connectTimeout;
  final Duration? _requestTimeout;
  final Duration? _readTimeout;

  /// Sent when connecting, for example for a proxy or gateway.
  final Map<String, String> _headers;

  /// Makes the connections (null: one is created).
  final http.Client? _client;
  bool _initialized = false;
  bool _closed = false;
  String? _xFeaturehubHeader;
  EventSource? _es;

  /// Incremented whenever the connection is dropped, so a connection still
  /// being opened by an earlier [_init] is discarded rather than kept: two
  /// quick context changes must not leave the first context's stream
  /// running.
  int _generation = 0;

  EventSourceRepositoryListener(
    String url,
    String apiKey,
    ClientFeatureRepository repository, {
    bool? doInit = true,
    this._reconnectPolicy = defaultReconnectPolicy,
    this._connectTimeout,
    this._requestTimeout,
    this._readTimeout,
    this._headers = const {},
    this._client,
  }) : _repository = repository,
       _clientEvaluated = isClientEvaluatedKeys([apiKey]),
       _host = EdgeHost(url),
       _apiKey = apiKey {
    final readTimeout = _readTimeout;
    if (readTimeout != null && readTimeout <= quietConnectionLimit) {
      _log.warning(
        'featurehub: a streaming read timeout of $readTimeout is too short: '
        'FeatureHub Edge may send nothing for up to '
        '${quietConnectionLimit.inMinutes} minutes, and each quiet connection '
        'will be dropped as a failure.',
      );
    }
    if (doInit ?? true) {
      init();
    }
  }

  bool get closed => _closed;

  /// The URL connected to: for a server-evaluated key it carries the
  /// context's `contextSha`.
  String get connectionUrl =>
      _host.streamUrl(_apiKey, xFeatureHubHeader: _xFeaturehubHeader);

  /// True if the API key is client-evaluated.
  bool get clientEvaluated => _clientEvaluated;

  Future<void> init() async {
    if (_clientEvaluated) {
      if (!_initialized) {
        _initialized = true;
        await _init();
      }
      return;
    }

    if (!_initialized) {
      _initialized = true;
      await _repository.clientContext.registerChangeHandler((header) async {
        _xFeaturehubHeader = header;
        // closed for good: a context change must not reconnect
        if (_closed) return;
        // the header is sent when connecting, so a context change needs a
        // new connection
        if (_subscription != null || _es != null) {
          await _disconnect();
        } else {
          // a connection may still be opening: discard it
          _generation++;
        }
        // ignore: unawaited_futures
        _init();
      });
    } else if (!_closed) {
      _repository.clientContext
          .build(); // trigger shut and restart via the handler above
    }
  }

  /// Drops the current connection (if any) and connects again, unless it has
  /// been closed.
  void retry() {
    if (_closed) return;
    _disconnect().then((_) {
      if (!_closed) _init();
    });
  }

  bool configEvent(Event event) {
    if (featureHubConfigIsStale(event.data)) {
      // the features already delivered are the last: stop, and report it
      _repository.markEnvironmentStale();
      close();
      return true;
    }

    return false;
  }

  Future<void> _init() async {
    if (_closed) return;
    final generation = _generation;
    final url = connectionUrl;
    _log.fine('Connecting to $url');

    final eventStream = await connect(url);
    if (generation != _generation) {
      // dropped (by a newer context, a retry or close) while connecting:
      // the stream has not been listened to, so it has not opened
      if (eventStream is EventSource) await eventStream.close();
      return;
    }

    _subscription = eventStream.listen(
      (event) {
        _log.fine('Event is ${event.event} value ${event.data}');

        if (event is EventSourceReconnect) {
          if (event.consecutiveShortConnections ==
              shortConnectionWarningAfter) {
            _log.warning(
              shortConnectionsWarning(event.consecutiveShortConnections),
            );
          }
          // the connection was lost and the event source is reconnecting
          if (!_repository.connectionFailed) {
            _repository.notify(SSEResultState.bye, null);
          }
          return;
        }

        if (event.event == 'config') {
          configEvent(event);
          return;
        }

        final state = SSEResultStateExtension.fromJson(event.event);
        if (state != null) {
          _repository.notify(state, decodeFeatureHubEventData(event.data));
        }

        if (state == SSEResultState.failure) {
          // the server has rejected us, don't keep reconnecting
          _log.fine('Failed connection to server, disconnecting');
          close();
        }
      },
      onError: (e) {
        // the event source has stopped for good (a 4xx, a status the policy
        // does not retry, or no attempts left): nothing will reconnect, so
        // it is a permanent failure, not a lost connection
        _log.fine('error $e');
        _repository.notify(SSEResultState.failure, null);
      },
      onDone: () {
        if (!_repository.connectionFailed && !_closed) {
          _repository.notify(SSEResultState.bye, null);
        }
      },
    );
  }

  Future<Stream<Event>> connect(String url) async {
    var sourceHeaders = {
      'content-type': 'application/json',
      ...withoutProtocolHeaders(_headers),
    };
    if (_xFeaturehubHeader != null) {
      sourceHeaders['x-featurehub'] = _xFeaturehubHeader!;
    }

    // connect when we start listening, so that a failure to connect is
    // retried according to the reconnect policy rather than thrown
    final generation = _generation;
    final es = await EventSource.connect(
      url,
      client: _client,
      openOnlyOnFirstListener: true,
      closeOnLastListener: true,
      headers: sourceHeaders,
      reconnectPolicy: _reconnectPolicy,
      connectTimeout: _connectTimeout,
      requestTimeout: _requestTimeout,
      readTimeout: _readTimeout,
      // the failed attempts start again only once FeatureHub has sent
      // something, not when a connection merely opens, and only once the
      // connection has lasted: a short one is a failure whatever it sent
      resetAttemptsOn: (event) =>
          featureHubEventShowsConnectionWorks(event.event),
      shortConnectionThreshold: shortConnectionThreshold,
    );
    // only keep it if it has not been dropped while connecting
    if (generation == _generation) _es = es;
    return es;
  }

  Future<void> _disconnect() async {
    _generation++;
    final subscription = _subscription;
    final es = _es;
    _subscription = null;
    _es = null;
    await subscription?.cancel();
    await es?.close();
  }

  /// Closes the connection for good: nothing (a context change, [retry] or
  /// [init]) opens another.
  void close() {
    _closed = true;
    _disconnect();
  }
}
