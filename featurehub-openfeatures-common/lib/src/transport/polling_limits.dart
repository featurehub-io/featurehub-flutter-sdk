/// The limits on poll intervals. Not exported: the minimum may be lowered by
/// the SDK's own tests (importing this file directly), and by test mode
/// ([enablePollingTestMode], which the server provider turns on from
/// FEATUREHUB_TEST_POLLING), never by applications.
library;

import 'package:logging/logging.dart';

final _log = Logger('featurehub_polling');

/// The shortest poll interval allowed, other than zero (poll once): no
/// configuration may poll a server more often than this.
///
/// Only the SDK's tests (and test mode) change this, to poll quickly.
Duration minPollingInterval = const Duration(seconds: 5);

/// The smallest FeatureHub `pollInterval` that is used: one below it is
/// ignored. 5 seconds, or 1 in test mode.
Duration minServerPollInterval = const Duration(seconds: 5);

bool _testMode = false;

/// True once test mode is on.
bool get pollingTestMode => _testMode;

/// Test mode, for test processes only (featurehub-protocol.yaml
/// polling_transport.interval.test_mode): any poll interval above 0 is
/// allowed, and a FeatureHub pollInterval of at least 1 second is used. It
/// stays on for the life of the process. Never for production.
void enablePollingTestMode() {
  if (_testMode) return;
  _testMode = true;
  minPollingInterval = const Duration(microseconds: 1);
  minServerPollInterval = const Duration(seconds: 1);
  _log.warning(
    'featurehub: polling test mode is on: the 5 second minimum poll interval '
    'is off. Never use it in production.',
  );
}

/// True if [value] (FEATUREHUB_TEST_POLLING) turns test mode on: true, in
/// any case, after trimming. Anything else is off, never an error.
bool pollingTestModeRequested(String? value) =>
    value?.trim().toLowerCase() == 'true';

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
