library;

import "dart:math" as math;

import "event.dart";

/// Controls how an `EventSource` reconnects after its connection is lost or a
/// connection attempt fails.
///
/// Reconnection happens when:
/// * the server closes the stream (normal end of response),
/// * the connection fails with a network/stream error, or
/// * the server responds with a status code for which [shouldRetryStatus]
///   returns true (by default, any 5xx).
///
/// Any other non-200 status (by default 1xx-4xx) stops the event source.
class ReconnectPolicy {
  /// The delay before reconnecting after a dropped connection or a network
  /// error. If [honourServerRetry] is true, a `retry:` field sent by the server
  /// replaces this value, as described by the SSE specification.
  final Duration delay;

  /// The delay before reconnecting after the server responded with a status
  /// that [shouldRetryStatus] accepted (by default, a 5xx). This is not affected
  /// by a server's `retry:` field.
  final Duration serverErrorDelay;

  /// The maximum number of consecutive reconnection attempts before the event
  /// source gives up and closes. The count resets whenever a connection is
  /// successfully opened. `null` means retry forever.
  final int? maxAttempts;

  /// Each consecutive failed attempt multiplies the delay by this factor.
  /// `1.0` (the default) keeps the delay constant.
  final double backoffMultiplier;

  /// Upper bound on the delay once [backoffMultiplier] has been applied.
  final Duration? maxDelay;

  /// Whether a server `retry:` field may replace [delay].
  final bool honourServerRetry;

  /// Decides whether a non-200 response status should be retried. Defaults to
  /// retrying 5xx responses only.
  final bool Function(int statusCode) shouldRetryStatus;

  const ReconnectPolicy({
    this.delay = const Duration(seconds: 3),
    this.serverErrorDelay = const Duration(seconds: 30),
    this.maxAttempts,
    this.backoffMultiplier = 1.0,
    this.maxDelay,
    this.honourServerRetry = true,
    this.shouldRetryStatus = defaultShouldRetryStatus,
  }) : assert(backoffMultiplier >= 1.0),
       assert(maxAttempts == null || maxAttempts >= 0);

  /// Never reconnect; the event source closes as soon as the connection ends.
  static const ReconnectPolicy none = ReconnectPolicy(maxAttempts: 0);

  /// Retries 5xx responses; 1xx-4xx (and any other non-200) stop.
  static bool defaultShouldRetryStatus(int statusCode) =>
      statusCode >= 500 && statusCode <= 599;

  /// The delay to wait before reconnection [attempt] (1-based).
  ///
  /// [base] is the delay for this kind of failure (see [delay] and
  /// [serverErrorDelay]).
  Duration delayFor(int attempt, Duration base) {
    final factor = math.pow(backoffMultiplier, attempt - 1);
    var result = Duration(microseconds: (base.inMicroseconds * factor).round());
    if (maxDelay != null && result > maxDelay!) {
      result = maxDelay!;
    }
    return result;
  }
}

/// Emitted on an `EventSource` stream each time a reconnection is scheduled,
/// before the delay starts. Listen with `EventSource.onReconnect`.
class EventSourceReconnect extends Event {
  /// The 1-based number of this reconnection attempt since the last successful
  /// connection.
  final int attempt;

  /// The configured maximum number of attempts, or null for unlimited.
  final int? maxAttempts;

  /// How long the event source will wait before trying to connect.
  final Duration delay;

  /// The HTTP status code that caused the reconnect, if the server responded
  /// with an error status. Null when the stream ended or a network error
  /// occurred.
  final int? statusCode;

  /// The error that caused the reconnect, if any. Null when the server simply
  /// closed the stream.
  final Object? error;

  EventSourceReconnect({
    required this.attempt,
    required this.maxAttempts,
    required this.delay,
    this.statusCode,
    this.error,
    super.id,
  }) : super(event: "reconnect");

  @override
  String get data =>
      "attempt $attempt${maxAttempts == null ? "" : "/$maxAttempts"} in $delay"
      "${statusCode == null ? "" : " (status $statusCode)"}"
      "${error == null || statusCode != null ? "" : " ($error)"}";

  @override
  String toString() => "EventSourceReconnect($data)";
}
