import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_sse_client/featurehub_sse_client.dart'
    show ReconnectPolicy;
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:web/web.dart' as web;

import '../featurehub_config.dart';
import 'repository.dart';

final _log = Logger('featurehub_web_eventsource');

/// The server-sent event types the repository understands.
const _featureEvents = [
  'ack',
  'bye',
  'failure',
  'features',
  'feature',
  'delete_feature',
];

/// Listens to the FeatureHub event stream in a browser, using the native
/// `EventSource` (the http package cannot stream responses in browsers).
///
/// The browser reconnects by itself after a dropped connection. If it gives
/// up (any non-200 response; browsers do not expose the status code), this
/// listener reconnects after [ReconnectPolicy.serverErrorDelay], up to
/// [ReconnectPolicy.maxAttempts] consecutive times.
///
/// Browsers cannot send headers with `EventSource`, so for server-evaluated
/// API keys the client context is sent as the `xfeaturehub` query parameter.
/// With a client-evaluated API key (containing `*`) the context is never
/// sent and a context change needs no reconnection.
class EventSourceRepositoryListener {
  final ClientFeatureRepository _repository;
  final String _url;
  final bool _clientEvaluated;
  final ReconnectPolicy _reconnectPolicy;
  final Duration? _requestTimeout;
  Timer? _openTimer;
  bool _initialized = false;
  bool _closed = false;
  String? _xFeaturehubHeader;
  web.EventSource? _es;
  Timer? _reconnectTimer;
  int _attempts = 0;

  EventSourceRepositoryListener(
    String url,
    String apiKey,
    ClientFeatureRepository repository, {
    bool? doInit = true,
    this._reconnectPolicy = const ReconnectPolicy(),
    // browsers control the connection timeout themselves
    Duration? connectTimeout,
    this._requestTimeout,
    // a browser's EventSource can send neither headers nor use a client
    Map<String, String> headers = const {},
    http.Client? client,
  }) : _repository = repository,
       _clientEvaluated = FeatureHubConfig.isClientEvaluatedKeys([apiKey]),
       _url = '$url${url.endsWith('/') ? '' : '/'}features/$apiKey' {
    if (headers.isNotEmpty) {
      _log.warning(
        'Browsers cannot send headers with an EventSource: they are not sent '
        'when streaming. Use polling to send them.',
      );
    }
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
        _connect();
      }
      return;
    }

    if (!_initialized) {
      _initialized = true;
      await _repository.clientContext.registerChangeHandler((header) async {
        _xFeaturehubHeader = header;
        // the context is part of the URL, so a change needs a new connection
        _disconnect();
        _connect();
      });
    } else {
      _repository.clientContext.build();
    }
  }

  /// Drops the current connection (if any) and connects again.
  void retry() {
    _disconnect();
    _connect();
  }

  /// The URL connected to, including the context for server-evaluated keys.
  String get connectionUrl => (_clientEvaluated || _xFeaturehubHeader == null)
      ? _url
      : '$_url?xfeaturehub=${Uri.encodeQueryComponent(_xFeaturehubHeader!)}';

  void _connect() {
    _closed = false;
    final url = connectionUrl;
    _log.fine('Connecting to $url');

    final es = web.EventSource(url);
    _es = es;

    for (final type in _featureEvents) {
      es.addEventListener(
        type,
        ((web.MessageEvent msg) => _message(es, type, msg)).toJS,
      );
    }
    es.addEventListener(
      'config',
      ((web.MessageEvent msg) => _config(es, msg)).toJS,
    );
    es.onopen = ((web.Event _) {
      if (!identical(_es, es)) return;
      _openTimer?.cancel();
      _openTimer = null;
      _attempts = 0;
    }).toJS;
    es.onerror = ((web.Event _) => _error(es)).toJS;

    final timeout = _requestTimeout;
    if (timeout != null) {
      _openTimer = Timer(timeout, () {
        _openTimer = null;
        if (!identical(_es, es) || _closed) return;
        if (es.readyState == web.EventSource.OPEN) return;
        _log.fine('The event stream did not open within $timeout');
        _disconnect();
        _scheduleReconnect(_reconnectPolicy.delay);
      });
    }
  }

  static String? _data(web.MessageEvent msg) {
    final data = msg.data;
    return data.isA<JSString>() ? (data as JSString).toDart : null;
  }

  void _message(web.EventSource es, String type, web.MessageEvent msg) {
    if (!identical(_es, es)) return;
    final data = _data(msg);
    _log.fine('Event is $type value $data');

    final state = SSEResultStateExtension.fromJson(type);
    _repository.notify(state, data == null ? null : jsonDecode(data));

    if (state == SSEResultState.failure) {
      // the server has rejected us, don't keep reconnecting
      _log.fine('Failed connection to server, disconnecting');
      close();
    }
  }

  void _config(web.EventSource es, web.MessageEvent msg) {
    if (!identical(_es, es)) return;
    final data = _data(msg);
    _log.fine('Config event $data');
    if (data != null && jsonDecode(data)?['edge.stale'] == true) {
      close();
    }
  }

  void _error(web.EventSource es) {
    if (!identical(_es, es) || _closed) return;

    if (es.readyState != web.EventSource.CLOSED) {
      // the browser is reconnecting by itself
      _log.fine('Lost connection to feature repository, reconnecting');
      if (_repository.readyness != Readyness.Failed) {
        _repository.notify(SSEResultState.bye, null);
      }
      return;
    }

    // the browser has given up on this connection (it does not say why)
    _disconnect();
    _scheduleReconnect(_reconnectPolicy.serverErrorDelay);
  }

  void _scheduleReconnect(Duration base) {
    final maxAttempts = _reconnectPolicy.maxAttempts;
    if (maxAttempts != null && _attempts >= maxAttempts) {
      // TODO(evaluate): running out of attempts after network errors is
      // reported as a failure, which the providers treat as a rejected API
      // key (PROVIDER_FATAL) and never recover from, whereas the dart:io
      // listener reports `bye` in the same case. The browser does not say
      // why an EventSource failed, so a 4xx cannot be told apart here.
      _log.severe('Unable to connect to feature repository, giving up');
      _repository.notify(SSEResultState.failure, null);
      return;
    }

    _attempts++;
    final delay = _reconnectPolicy.delayFor(_attempts, base);
    _log.fine('Unable to connect, reconnecting in $delay (attempt $_attempts)');
    _repository.notify(SSEResultState.bye, null);
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      if (!_closed) _connect();
    });
  }

  void _disconnect() {
    _openTimer?.cancel();
    _openTimer = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _es?.close();
    _es = null;
  }

  void close() {
    _closed = true;
    _disconnect();
  }
}
