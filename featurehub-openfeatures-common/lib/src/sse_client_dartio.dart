import 'dart:async';
import 'dart:convert';

import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_sse_client/featurehub_sse_client.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import '../featurehub_config.dart';
import 'openfeature/featurehub_transport.dart' show defaultReconnectPolicy;
import 'repository.dart';

final _log = Logger('featurehub_io_eventsource');

/// Listens to the FeatureHub event stream and feeds the repository.
///
/// Reconnection is handled by the underlying [EventSource] (see
/// [ReconnectPolicy]): it reconnects when the server closes the stream, on
/// network errors and on 5xx responses, and stops on 4xx responses. This
/// listener only closes the connection when the server reports a failure or
/// the edge is stale, and opens a new one when the client context changes.
///
/// With a client-evaluated API key (containing `*`) the server sends every
/// feature's rollout strategies, which the repository applies locally, so the
/// client context is never sent and a context change needs no reconnection.
class EventSourceRepositoryListener {
  final ClientFeatureRepository _repository;
  StreamSubscription<Event>? _subscription;
  final String _url;
  final bool _clientEvaluated;
  final ReconnectPolicy _reconnectPolicy;
  final Duration? _connectTimeout;
  final Duration? _requestTimeout;

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
    this._headers = const {},
    this._client,
  }) : _repository = repository,
       _clientEvaluated = FeatureHubConfig.isClientEvaluatedKeys([apiKey]),
       _url = '$url${url.endsWith('/') ? '' : '/'}features/$apiKey' {
    if (doInit ?? true) {
      init();
    }
  }

  bool get closed => _closed;

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
    } else {
      _repository.clientContext
          .build(); // trigger shut and restart via the handler above
    }
  }

  /// Drops the current connection (if any) and connects again.
  void retry() {
    _disconnect().then((_) => _init());
  }

  bool configEvent(Event event) {
    if (event.data != null && jsonDecode(event.data!)?['edge.stale'] == true) {
      // the features already delivered are the last: stop, and report it
      _repository.markEnvironmentStale();
      close();
      return true;
    }

    return false;
  }

  Future<void> _init() async {
    final generation = _generation;
    _closed = false;
    _log.fine('Connecting to $_url');

    final eventStream = await connect(_url);
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
          // the connection was lost and the event source is reconnecting
          if (_repository.readyness != Readyness.Failed) {
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
          _repository.notify(
            state,
            event.data == null ? null : jsonDecode(event.data!),
          );
        }

        if (state == SSEResultState.failure) {
          // the server has rejected us, don't keep reconnecting
          _log.fine('Failed connection to server, disconnecting');
          close();
        }
      },
      onError: (e) {
        // the event source has given up reconnecting
        _log.fine('error $e');
        if (e is EventSourceSubscriptionException &&
            e.statusCode >= 400 &&
            e.statusCode < 500) {
          _repository.notify(SSEResultState.failure, null);
        } else {
          _repository.notify(SSEResultState.bye, null);
        }
      },
      onDone: () {
        if (_repository.readyness != Readyness.Failed && !_closed) {
          _repository.notify(SSEResultState.bye, null);
        }
      },
    );
  }

  Future<Stream<Event>> connect(String url) async {
    var sourceHeaders = {'content-type': 'application/json', ..._headers};
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

  void close() {
    _closed = true;
    _disconnect();
  }
}
