import 'dart:async';
import 'dart:convert';

import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_sse_client/featurehub_sse_client.dart';
import 'package:logging/logging.dart';

import 'repository.dart';

final _log = Logger('featurehub_io_eventsource');

/// Listens to the FeatureHub event stream and feeds the repository.
///
/// Reconnection is handled by the underlying [EventSource] (see
/// [ReconnectPolicy]): it reconnects when the server closes the stream, on
/// network errors and on 5xx responses, and stops on 4xx responses. This
/// listener only closes the connection when the server reports a failure or
/// the edge is stale, and opens a new one when the client context changes.
class EventSourceRepositoryListener {
  final ClientFeatureRepository _repository;
  StreamSubscription<Event>? _subscription;
  final String _url;
  final ReconnectPolicy _reconnectPolicy;
  bool _initialized = false;
  bool _closed = false;
  String? _xFeaturehubHeader;
  EventSource? _es;

  EventSourceRepositoryListener(
    String url,
    String apiKey,
    ClientFeatureRepository repository, {
    bool? doInit = true,
    ReconnectPolicy reconnectPolicy = const ReconnectPolicy(),
  }) : _repository = repository,
       _reconnectPolicy = reconnectPolicy,
       _url = '$url${url.endsWith('/') ? '' : '/'}features/$apiKey' {
    if (apiKey.contains('*')) {
      throw Exception(
        'You are using a client evaluated API Key in Dart and this is not supported.',
      );
    }

    if (doInit ?? true) {
      init();
    }
  }

  bool get closed => _closed;

  Future<void> init() async {
    if (!_initialized) {
      _initialized = true;
      await _repository.clientContext.registerChangeHandler((header) async {
        _xFeaturehubHeader = header;
        // the header is sent when connecting, so a context change needs a
        // new connection
        if (_subscription != null || _es != null) {
          await _disconnect();
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
      close();
      return true;
    }

    return false;
  }

  Future<void> _init() async {
    _closed = false;
    _log.fine('Connecting to $_url');

    final eventStream = await connect(_url);

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
    var sourceHeaders = {'content-type': 'application/json'};
    if (_xFeaturehubHeader != null) {
      sourceHeaders['x-featurehub'] = _xFeaturehubHeader!;
    }

    // connect when we start listening, so that a failure to connect is
    // retried according to the reconnect policy rather than thrown
    _es = await EventSource.connect(
      url,
      openOnlyOnFirstListener: true,
      closeOnLastListener: true,
      headers: sourceHeaders,
      reconnectPolicy: _reconnectPolicy,
    );

    return _es!;
  }

  Future<void> _disconnect() async {
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
