library;

import "dart:async";
import "dart:convert";

import "package:http/http.dart" as http;
import "package:http_parser/http_parser.dart" show MediaType;
import "package:logging/logging.dart";

import "src/decoder.dart";
import "src/event.dart";
import "src/http/client_factory.dart"
    if (dart.library.io) "src/http/client_factory_io.dart";
import "src/limits.dart";
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
///
/// A 200 response that is not `text/event-stream` (for example an HTML page
/// from a proxy or captive portal) is a failed connection, retried like a
/// network error. Every wait before a reconnection is at least 100ms, and a
/// server's `retry:` field is raised to at least 1 second.
class EventSource extends Stream<Event> {
  // interface attributes

  final Uri url;
  final Map? headers;

  /// How this event source reconnects.
  final ReconnectPolicy reconnectPolicy;

  /// The longest each connection attempt waits for the server to respond
  /// (its status and headers; the event stream then stays open). An attempt
  /// that times out is a network error, retried according to
  /// [reconnectPolicy]. Null waits indefinitely.
  final Duration? requestTimeout;

  /// Decides which events show that a connection works, and so reset the
  /// count of consecutive failed attempts. Null resets it as soon as a
  /// connection opens (a 200). Checked as each event is read, before the end
  /// of the same stream is counted as the next failure, so a server that
  /// accepts connections and drops them at once still backs off and uses up
  /// [ReconnectPolicy.maxAttempts].
  final bool Function(Event event)? resetAttemptsOn;

  /// A connection that opens and ends sooner than this after its request
  /// was sent, cleanly or not, is a failed attempt: a server or cache that
  /// answers with a stream that is already closing must back off, however
  /// well its events look. The reset of the failed attempts that an event
  /// earns ([resetAttemptsOn], or the connection opening) is only made once
  /// this long has passed since the request; if the connection ends first,
  /// the reset is dropped. It is measured from the request, not from the
  /// response, so a server or proxy that is slow to send the response
  /// headers does not make a long connection look short. Null: no minimum,
  /// an event resets the count at once.
  final Duration? shortConnectionThreshold;

  /// The longest an open connection may go without receiving anything (not
  /// even a comment) before it is treated as dropped: a network error,
  /// retried according to [reconnectPolicy]. Null waits indefinitely.
  final Duration? readTimeout;

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

  /// Running until [shortConnectionThreshold] after the current
  /// connection's request was sent.
  Timer? _shortTimer;

  /// True once the current connection has opened (a 200 event stream).
  bool _opened = false;

  /// A reset of [_attempts] earned by the current connection, made once
  /// [_shortTimer] has run out.
  bool _resetDue = false;

  /// Consecutive connections that ended before [shortConnectionThreshold].
  int _shortConnections = 0;

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

  /// The number of consecutive connections that ended before
  /// [shortConnectionThreshold]; reset when one lasts that long.
  int get consecutiveShortConnections => _shortConnections;

  /// Create a new EventSource by connecting to the specified url.
  ///
  /// If the initial connection fails, an [EventSourceSubscriptionException] is
  /// thrown and no reconnection is attempted. Once connected, the event source
  /// reconnects according to [reconnectPolicy] (default: [ReconnectPolicy]`()`).
  ///
  /// [connectTimeout] limits how long establishing a connection may take. It
  /// applies to the client created when [client] is not supplied, and only
  /// on `dart:io` (other platforms control it themselves). [requestTimeout]
  /// limits how long each connection attempt waits for the server to respond.
  /// Both default to waiting indefinitely.
  ///
  /// [resetAttemptsOn] chooses the events that reset the count of failed
  /// attempts (by default, opening a connection does), and
  /// [shortConnectionThreshold] how long a connection must last before that
  /// reset is made. [readTimeout] limits how long an open connection may go
  /// without data.
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
    Duration? connectTimeout,
    Duration? requestTimeout,
    bool Function(Event event)? resetAttemptsOn,
    Duration? shortConnectionThreshold,
    Duration? readTimeout,
  }) async {
    // parameter initialization
    final uri = url is Uri ? url : Uri.parse(url as String);
    client = client ?? createHttpClient(connectTimeout: connectTimeout);
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
      requestTimeout,
      resetAttemptsOn,
      shortConnectionThreshold,
      readTimeout,
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
    this.requestTimeout,
    this.resetAttemptsOn,
    this.shortConnectionThreshold,
    this.readTimeout,
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
    _shortTimer?.cancel();
    _shortTimer = null;
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

    _opened = false;
    _resetDue = false;
    _shortTimer?.cancel();
    _shortTimer = null;
    final threshold = shortConnectionThreshold;
    if (threshold != null) {
      _shortTimer = Timer(threshold, () {
        if (generation != _generation) return;
        if (_opened) _shortConnections = 0;
        if (_resetDue) _attempts = 0;
        _resetDue = false;
      });
    }

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
      response = await _send(request);
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

    final contentType = _contentTypeForHeaders(response.headers).mimeType;
    if (contentType != "text/event-stream") {
      // e.g. an HTML page from a gateway, proxy or captive portal: not a
      // stream that opened, but a failed connection, retried as a network
      // error would be
      response.stream.listen(null).cancel();
      throw EventSourceSubscriptionException(
        0,
        "the response is $contentType, not text/event-stream",
      );
    }

    final reset = resetAttemptsOn;
    // a reset this connection has earned, made once it is old enough
    void earnReset() {
      if (_shortTimer?.isActive ?? false) {
        _resetDue = true;
      } else {
        _attempts = 0;
      }
    }

    _opened = true;
    if (reset == null) earnReset();
    _setReadyState(EventSourceReadyState.open);

    final timeout = readTimeout;
    final Stream<List<int>> body = timeout == null
        ? response.stream
        : response.stream.timeout(
            timeout,
            onTimeout: (sink) {
              sink.addError(
                TimeoutException("No data within $timeout", timeout),
              );
              sink.close();
            },
          );

    _subscription = body
        .transform(_decoder)
        .listen(
          (event) {
            // here, as the stream is read: the end of this stream is counted
            // as the next failure only after its events
            if (reset != null && reset(event)) earnReset();
            _streamController.add(event);
          },
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

  Future<http.StreamedResponse> _send(http.Request request) {
    final sent = client.send(request);
    final timeout = requestTimeout;
    if (timeout == null) return sent;
    return sent.timeout(
      timeout,
      onTimeout: () {
        // don't leak the connection if the response arrives after all
        sent.then((r) => r.stream.listen(null).cancel(), onError: (_) {});
        throw TimeoutException("No response within $timeout", timeout);
      },
    );
  }

  /// Called when a connection is lost ([error] is null if the server closed the
  /// stream) or a connection attempt fails. Schedules a reconnection or gives
  /// up, according to [reconnectPolicy].
  void _handleFailure(Object? error) {
    _subscription = null;
    // a connection that opened but did not last: a failure whatever it sent
    final short = _opened && (_shortTimer?.isActive ?? false);
    _shortTimer?.cancel();
    _shortTimer = null;
    _opened = false;
    _resetDue = false;
    if (short) _shortConnections++;
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
    var delay = reconnectPolicy.delayFor(_attempts, base);
    // whatever the policy says, never a tight reconnect loop
    if (delay < minReconnectDelay) delay = minReconnectDelay;

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
        shortConnection: short,
        consecutiveShortConnections: _shortConnections,
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
    // retry: 10 would otherwise reconnect every 10ms
    _serverRetry = retry < minServerRetryDelay ? minServerRetryDelay : retry;
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
