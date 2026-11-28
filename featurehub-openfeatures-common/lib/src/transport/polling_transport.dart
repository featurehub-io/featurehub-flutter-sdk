import 'dart:async';

import 'package:logging/logging.dart';

import '../repository.dart';
import 'featurehub_transport.dart';
import 'polling_limits.dart';

final _log = Logger('featurehub_polling');

/// The scheduling shared by the polling transports
/// ([FeatureHubPollingTransport] polling FeatureHub, and
/// [FeatureSnapshotTransport] polling your own server). A subclass makes the
/// requests ([fetch]); this decides when.
///
/// - [FeatureHubUpdateMode.activePolling]: after each poll finishes,
///   successful or not, the next is made the full [currentInterval] (the
///   poll interval, or a Cache-Control max-age from FeatureHub that replaced
///   it) later, measured from the end of the poll: a slow or failing server
///   is never polled faster than that, and a failure never becomes a tight
///   retry loop.
/// - [FeatureHubUpdateMode.passivePolling]: no polls of its own; a request is
///   made when [refreshIfStale] is called (as flags are read) and the
///   features are older than the interval. After a failure, no request is
///   made until the interval has passed.
///
/// Requests are made one at a time; a context change forces one at once.
///
/// An [interval] of zero polls once: the first request is made, and no other
/// (in either mode, whatever a Cache-Control max-age says) except those a
/// context change forces. Any other interval must be at least 5 seconds.
abstract class PollingTransport implements FeatureHubTransport {
  final ClientFeatureRepository repository;

  /// The configured poll interval.
  final Duration interval;

  /// True for [FeatureHubUpdateMode.activePolling], false for passive.
  final bool active;

  bool _closed = false;
  Timer? _timer;
  Future<void>? _inFlight;

  /// Passive polling, after a failed request: no unforced request before this,
  /// so an outage does not cost a request per evaluation.
  DateTime? _retryAfter;

  /// Whether the first request has been made (an interval of zero then
  /// makes no more).
  bool _requested = false;

  /// Throws an [ArgumentError] for a negative [interval], or one between zero
  /// and 5 seconds.
  PollingTransport(this.repository, this.interval, {required this.active}) {
    validatePollInterval(interval);
  }

  /// True if the interval is zero: poll once.
  bool get _once => interval == Duration.zero;

  /// Makes one request, unless (when not [force]d) the features are still
  /// fresh. Throws for errors worth retrying; a permanent rejection is
  /// notified as a failure and makes [isDead] true.
  Future<void> fetch({bool force = false});

  /// True once the source has stopped for good (rejected, or stale).
  bool get isDead;

  /// The wait between active polls: [interval], or what the source asked
  /// for instead (FeatureHub's Cache-Control max-age).
  Duration get currentInterval;

  Future<void> _request({bool force = false}) {
    // one request at a time; a forced request waits for the current one
    final previous = _inFlight ?? Future<void>.value();
    final next = previous.then((_) async {
      // closed: no more requests, whatever asks (a context change, a read)
      if (_closed) return;
      final retryAfter = _retryAfter;
      if (!force && retryAfter != null && DateTime.now().isBefore(retryAfter)) {
        return;
      }
      // poll once: after the first request, only forced ones
      if (!force && _once && _requested) return;
      _requested = true;
      try {
        await fetch(force: force);
        _retryAfter = null;
      } catch (e) {
        _log.fine('Fetching features failed: $e');
        if (!active && !_once) _retryAfter = DateTime.now().add(interval);
      }
    });
    _inFlight = next;
    return next.whenComplete(() {
      if (identical(_inFlight, next)) _inFlight = null;
    });
  }

  @override
  Future<void> start() async {
    if (repository.readyness == Readyness.Ready) {
      // already ready (e.g. from a store's features): fetch in the background
      unawaited(_request().then((_) => _scheduleNext()));
    } else {
      await _request();
      _scheduleNext();
    }
  }

  void _scheduleNext() {
    if (!active || _once || _closed || isDead) return;
    // the full interval (or the max-age that replaced it), from the end of
    // the poll just made
    _timer = Timer(currentInterval, () async {
      _timer = null;
      await _request(force: true);
      _scheduleNext();
    });
  }

  @override
  Future<void> contextChanged() => _request(force: true);

  @override
  Future<void> refreshIfStale() => active ? Future.value() : _request();

  @override
  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    _timer = null;
  }
}
