/// The limits on poll intervals. Not exported: the minimum may be lowered by
/// the SDK's own tests only (importing this file directly), never by
/// applications.
library;

/// The shortest poll interval allowed, other than zero (poll once): no
/// configuration may poll a server more often than this. A FeatureHub
/// Cache-Control max-age below it is raised to it.
///
/// Only the SDK's tests change this, to poll quickly.
Duration minPollingInterval = const Duration(seconds: 5);

/// The default [minPollingInterval], to restore after a test lowers it.
const defaultMinPollingInterval = Duration(seconds: 5);

/// Throws an [ArgumentError] unless [interval] is a valid poll interval:
/// zero (poll once, then never again) or at least [minPollingInterval].
/// [name] is the argument it came from.
void validatePollInterval(Duration interval, [String name = 'pollInterval']) {
  if (interval.isNegative) {
    throw ArgumentError.value(interval, name, 'must not be negative');
  }
  if (interval > Duration.zero && interval < minPollingInterval) {
    throw ArgumentError.value(
      interval,
      name,
      'must be 0 (poll once) or at least ${minPollingInterval.inSeconds} '
      'seconds',
    );
  }
}

/// [maxAge] (a server's Cache-Control max-age), raised to
/// [minPollingInterval].
Duration atLeastMinimum(Duration maxAge) =>
    maxAge < minPollingInterval ? minPollingInterval : maxAge;
