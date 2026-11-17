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

    // only a 5xx is retried; a 4xx stops
    expect(p.shouldRetryStatus(503), true);
    expect(p.shouldRetryStatus(401), false);
  });
}
