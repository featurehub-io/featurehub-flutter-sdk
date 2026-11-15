library;

import "dart:async";
import "dart:convert";

import "package:http/http.dart" as http;
import "package:http_parser/http_parser.dart" show MediaType;
import "package:logging/logging.dart";

import "src/decoder.dart";
import "src/event.dart";
import "src/reconnect.dart";

export "src/event.dart";
export "src/reconnect.dart";

final _log = Logger("featurehub_sse_client");

enum EventSourceReadyState {
  connecting,
  open,
  closed;

  @Deprecated("Use EventSourceReadyState.connecting")
  // ignore: constant_identifier_names
  static const CONNECTING = connecting;
  @Deprecated("Use EventSourceReadyState.open")
  // ignore: constant_identifier_names
  static const OPEN = open;
  @Deprecated("Use EventSourceReadyState.closed")
  // ignore: constant_identifier_names
  static const CLOSED = closed;
}

/// Raised (as a stream error, or thrown from [EventSource.connect] /
/// [EventSource.reopen]) when a connection fails.
///
/// [statusCode] is the HTTP status returned by the server, or `0` if no HTTP
/// response was received (e.g. a network error) or the connection was lost.
class EventSourceSubscriptionException extends Event implements Exception {
  int statusCode;
  String message;
  Object? exception;
  StackTrace? stackTrace;

  @override
  String get data => "$statusCode: $message";

  EventSourceSubscriptionException(this.statusCode, this.message)
    : super(event: "error");

  EventSourceSubscriptionException.fromException(
    this.statusCode,
    this.message,
    this.exception,
    this.stackTrace,
  ) : super(event: "error");

  /// True if the server responded with an HTTP error status.
  bool get isHttpError => statusCode != 0;

  @override
  String toString() => "EventSourceSubscriptionException($data)";
}

/// An EventSource client that exposes a [Stream] of [Event]s.
///
/// The event source reconnects automatically according to its
/// [reconnectPolicy]: when the server closes the stream, when the connection
/// fails, or when the server responds with a retryable status (by default
/// 5xx). Each scheduled reconnection is announced to listeners with an
/// [EventSourceReconnect] event (see [onReconnect]). When the policy gives up
/// (a non-retryable status such as 4xx, or [ReconnectPolicy.maxAttempts]
/// exhausted) the final error is added to the stream and [readyState] becomes
/// [EventSourceReadyState.closed].
class EventSource extends Stream<Event> {
  // interface attributes

  final Uri url;
  final Map? headers;

  /// How this event source reconnects.
  final ReconnectPolicy reconnectPolicy;

  EventSourceReadyState get readyState => _readyState;

  Stream<Event> get onOpen => where((e) => e.event == "open");
  Stream<Event> get onMessage => where((e) => e.event == "message");
  Stream<Event> get onError => where((e) => e.event == "error");

  /// Emits each time a reconnection is scheduled, before its delay starts.
  Stream<EventSourceReconnect> get onReconnect =>
      where((e) => e is EventSourceReconnect).cast<EventSourceReconnect>();

  // internal attributes

  late StreamController<Event> _streamController;
  StreamController<EventSourceReadyState> readyStateController;

  EventSourceReadyState _readyState = EventSourceReadyState.closed;

  http.Client client;
  late EventSourceDecoder _decoder;
  final String _body;
  final String _method;
  final bool _openOnlyOnFirstListener;
  final bool _closeOnLastListener;
  http.ByteStream? responseStream;

  /// The subscription to the current connection's decoded event stream.
  StreamSubscription<Event>? _subscription;

  /// The pending reconnection, if one is scheduled.
  Timer? _reconnectTimer;

  /// Consecutive reconnection attempts since the last successful connection.
  int _attempts = 0;

  /// The reconnection time sent by the server in a `retry:` field, if any.
  Duration? _serverRetry;

  /// True once the event source has been closed (explicitly, or because the
  /// reconnect policy gave up). Suppresses any further reconnection.
  bool _stopped = true;

  /// Incremented for every connection attempt and on close, so callbacks from
  /// a superseded connection can be ignored.
  int _generation = 0;

  /// The last event ID received from the server (or supplied to [connect]),
  /// sent as the `Last-Event-ID` header on reconnection. Empty if none.
  String get lastEventId => _decoder.lastEventId;

  /// The number of consecutive reconnection attempts made since the last
  /// successful connection.
  int get reconnectAttempts => _attempts;

  /// Create a new EventSource by connecting to the specified url.
  ///
  /// If the initial connection fails, an [EventSourceSubscriptionException] is
  /// thrown and no reconnection is attempted. Once connected, the event source
  /// reconnects according to [reconnectPolicy] (default: [ReconnectPolicy]`()`).
  ///
  /// If you want to be able to listen to the state changes you need to provide your
  /// own readyStateController as broadcast controllers do not store state.
  static Future<EventSource> connect(
    Object url, {
    http.Client? client,
    String? lastEventId,
    Map? headers,
    String? body,
    String? method,
    bool? openOnlyOnFirstListener,
    StreamController<EventSourceReadyState>? readyStateController,
    bool? closeOnLastListener,
    ReconnectPolicy? reconnectPolicy,
  }) async {
    // parameter initialization
    final uri = url is Uri ? url : Uri.parse(url as String);
    client = client ?? http.Client();
    lastEventId = lastEventId ?? "";
    body = body ?? "";
    method = method ?? "GET";
    EventSource es = EventSource._internal(
      uri,
      client,
      lastEventId,
      headers,
      body,
      method,
      openOnlyOnFirstListener,
      closeOnLastListener,
      readyStateController,
      reconnectPolicy ?? const ReconnectPolicy(),
    );
    if (!es._openOnlyOnFirstListener) {
      await es._openOrThrow();
    }
    return es;
  }

  EventSource._internal(
    this.url,
    this.client,
    String lastEventId,
    this.headers,
    this._body,
    this._method,
    bool? openOnlyOnFirstStream,
    bool? closeOnLastStreamClosing,
    StreamController<EventSourceReadyState>? _readyStateController,
    this.reconnectPolicy,
  ) : _openOnlyOnFirstListener = openOnlyOnFirstStream ?? false,
      _closeOnLastListener = closeOnLastStreamClosing ?? false,
      readyStateController =
          _readyStateController ?? StreamController.broadcast() {
    // initialize here so we can close the stream
    _streamController = StreamController<Event>.broadcast(
      onCancel: () => _lastStreamDisconnected(),
    );

    readyStateController.add(_readyState);

    _decoder = EventSourceDecoder(
      retryIndicator: _updateRetryDelay,
      lastEventId: lastEventId,
    );
  }

  void _setReadyState(EventSourceReadyState readyState) {
    if (readyState == _readyState) return;
    _log.fine("setting ready state $readyState");
    _readyState = readyState;
    readyStateController.add(_readyState);
  }

  // proxy the listen call to the controller's listen call
  @override
  StreamSubscription<Event> listen(
    void Function(Event event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final subscription = _streamController.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );

    if (_readyState == EventSourceReadyState.closed &&
        _openOnlyOnFirstListener) {
      // nobody to throw to here: failures go through the reconnect policy and
      // surface as stream errors
      _stopped = false;
      _attempts = 0;
      _start().catchError(_handleFailure);
    }

    return subscription;
  }

  void _lastStreamDisconnected() {
    if (_closeOnLastListener) {
      // delay until next cycle, cannot disconnect while triggering this event
      Timer.run(() {
        if (!_streamController.hasListener) {
          _stop();
        }
      });
    }
  }

  /// Reopens a closed event source. Like [connect], throws an
  /// [EventSourceSubscriptionException] if the connection attempt fails.
  Future<void> reopen() async {
    if (_readyState == EventSourceReadyState.closed) {
      return _openOrThrow();
    } else {
      return Future.error("SSE client has not been closed.");
    }
  }

  /// Closes the connection and cancels any pending reconnection. The event
  /// source can be opened again with [reopen].
  Future<void> close() async {
    await _stop();
  }

  Future<void> _openOrThrow() async {
    _stopped = false;
    _attempts = 0;
    try {
      await _start();
    } catch (e) {
      await _stop();
      rethrow;
    }
  }

  Future<void> _stop() async {
    _stopped = true;
    _generation++;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final subscription = _subscription;
    _subscription = null;
    _setReadyState(EventSourceReadyState.closed);
    try {
      await subscription?.cancel();
    } catch (e) {
      // swallow the exception if there is one.
    }
  }

  /// Makes a single connection attempt. Throws an
  /// [EventSourceSubscriptionException] if it fails.
  Future<void> _start() async {
    final generation = ++_generation;
    _setReadyState(EventSourceReadyState.connecting);

    var request = http.Request(_method, url);
    request.headers["Cache-Control"] = "no-cache";
    request.headers["Accept"] = "text/event-stream";
    if (_decoder.lastEventId.isNotEmpty) {
      request.headers["Last-Event-ID"] = _decoder.lastEventId;
    }
    if (headers != null) {
      headers!.forEach((k, v) {
        request.headers[k] = v;
      });
    }
    request.body = _body;

    final http.StreamedResponse response;
    try {
      response = await client.send(request);
    } catch (e, s) {
      if (generation != _generation) return; // superseded, nothing to report
      throw EventSourceSubscriptionException.fromException(
        0,
        e.toString(),
        e,
        s,
      );
    }

    if (generation != _generation) {
      // closed (or superseded) while we were connecting
      response.stream.listen(null).cancel();
      return;
    }

    if (response.statusCode != 200) {
      // server returned an error
      String body = "";
      try {
        final bodyBytes = await response.stream.toBytes();
        body = _encodingForHeaders(response.headers).decode(bodyBytes);
      } catch (e) {
        // the status code is what matters
      }
      if (generation != _generation) return; // superseded, nothing to report
      throw EventSourceSubscriptionException(response.statusCode, body);
    }

    _attempts = 0;
    _setReadyState(EventSourceReadyState.open);

    _subscription = response.stream
        .transform(_decoder)
        .listen(
          _streamController.add,
          cancelOnError: true,
          onError: (Object e, StackTrace s) {
            if (generation == _generation) {
              _handleFailure(
                EventSourceSubscriptionException.fromException(
                  0,
                  e.toString(),
                  e,
                  s,
                ),
              );
            }
          },
          onDone: () {
            if (generation == _generation) {
              _handleFailure(null);
            }
          },
        );
  }

  /// Called when a connection is lost ([error] is null if the server closed the
  /// stream) or a connection attempt fails. Schedules a reconnection or gives
  /// up, according to [reconnectPolicy].
  void _handleFailure(Object? error) {
    _subscription = null;
    if (_stopped) return;

    final statusCode =
        (error is EventSourceSubscriptionException && error.isHttpError)
        ? error.statusCode
        : null;

    if (statusCode != null && !reconnectPolicy.shouldRetryStatus(statusCode)) {
      _log.fine("status $statusCode is not retryable, closing");
      _fail(error!);
      return;
    }

    final maxAttempts = reconnectPolicy.maxAttempts;
    if (maxAttempts != null && _attempts >= maxAttempts) {
      _log.fine("giving up after $_attempts reconnection attempts");
      _fail(
        error ??
            EventSourceSubscriptionException(
              0,
              "connection closed and reconnection attempts exhausted",
            ),
      );
      return;
    }

    _attempts++;

    final Duration base;
    if (statusCode != null) {
      base = reconnectPolicy.serverErrorDelay;
    } else if (reconnectPolicy.honourServerRetry && _serverRetry != null) {
      base = _serverRetry!;
    } else {
      base = reconnectPolicy.delay;
    }
    final delay = reconnectPolicy.delayFor(_attempts, base);

    _setReadyState(EventSourceReadyState.connecting);
    _log.fine("reconnecting in $delay (attempt $_attempts)");
    _streamController.add(
      EventSourceReconnect(
        attempt: _attempts,
        maxAttempts: maxAttempts,
        delay: delay,
        statusCode: statusCode,
        error: error,
        id: lastEventId,
      ),
    );

    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      if (_stopped) return;
      _start().catchError(_handleFailure);
    });
  }

  void _fail(Object error) {
    _stop();
    _streamController.addError(error);
  }

  void _updateRetryDelay(Duration retry) {
    _serverRetry = retry;
  }
}

/// Returns the encoding to use for a response with the given headers. This
/// defaults to [latin1] if the headers don't specify a charset or
/// if that charset is unknown.
Encoding _encodingForHeaders(Map<String, String> headers) {
  final charset = _contentTypeForHeaders(headers).parameters['charset'];
  return (charset == null ? null : Encoding.getByName(charset)) ?? latin1;
}

/// Returns the [MediaType] object for the given headers's content-type.
///
/// Defaults to `application/octet-stream`.
MediaType _contentTypeForHeaders(Map<String, String> headers) {
  var contentType = headers['content-type'];
  if (contentType != null) return MediaType.parse(contentType);
  return MediaType("application", "octet-stream");
}
