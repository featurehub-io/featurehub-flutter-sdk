import 'package:featurehub_openfeatures_common/featurehub_openfeatures_common.dart';
import 'package:test/test.dart';

void main() {
  test('reconnects back off, doubling up to five minutes', () {
    const p = defaultReconnectPolicy;
    expect(p.delay, const Duration(seconds: 3));
    expect(p.serverErrorDelay, const Duration(seconds: 30));
    expect(p.maxAttempts, isNull);

    expect(
      [
        for (var attempt = 1; attempt <= 8; attempt++)
          p.delayFor(attempt, p.delay).inSeconds,
      ],
      [3, 6, 12, 24, 48, 96, 192, 300],
    );
    expect(
      [
        for (var attempt = 1; attempt <= 5; attempt++)
          p.delayFor(attempt, p.serverErrorDelay).inSeconds,
      ],
      [30, 60, 120, 240, 300],
    );

    // every 4xx stops, 429 included; a 5xx, or an invalid 1xx or 3xx, is
    // retried
    for (final status in [400, 401, 403, 404, 408, 429, 499]) {
      expect(p.shouldRetryStatus(status), false, reason: '$status');
    }
    for (final status in [100, 101, 301, 302, 304, 500, 502, 503, 599]) {
      expect(p.shouldRetryStatus(status), true, reason: '$status');
    }
  });

  // conformance: streaming-attempt-reset (the SSE client resets where the
  // stream is read, for the events this accepts)
  test(
    'only FeatureHub events that show a connection works reset attempts',
    () {
      for (final event in [
        'ack',
        'features',
        'feature',
        'delete_feature',
        'config',
      ]) {
        expect(featureHubEventShowsConnectionWorks(event), true, reason: event);
      }
      for (final event in ['bye', 'error', 'failure', 'message', null]) {
        expect(
          featureHubEventShowsConnectionWorks(event),
          false,
          reason: event,
        );
      }
    },
  );
}
