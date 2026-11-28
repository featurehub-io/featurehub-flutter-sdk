// conformance: environment-test-polling (the common half; the server
// provider reads FEATUREHUB_TEST_POLLING). Test mode lasts for the process,
// so it has a file (an isolate) of its own.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:featurehub_openfeatures_common/featurehub_openfeatures_common.dart';
import 'package:featurehub_openfeatures_common/src/transport/polling_limits.dart';
import 'package:openapi_dart_common/openapi.dart';
import 'package:test/test.dart';

void main() {
  test('only true, in any case, turns it on', () {
    for (final on in ['true', 'TRUE', ' True ']) {
      expect(pollingTestModeRequested(on), true, reason: on);
    }
    for (final off in [null, '', 'false', 'yes', '1']) {
      expect(pollingTestModeRequested(off), false, reason: '$off');
    }
  });

  test('off: the 5 second minimum holds', () {
    expect(pollingTestMode, false);
    expect(
      () => validatePollInterval(const Duration(milliseconds: 500)),
      throwsArgumentError,
    );
  });

  test('on: any interval above 0, and a pollInterval of 1', () async {
    enablePollingTestMode();
    expect(pollingTestMode, true);
    validatePollInterval(const Duration(milliseconds: 500));
    validatePollInterval(Duration.zero);
    expect(
      () => validatePollInterval(const Duration(seconds: -1)),
      throwsArgumentError,
    );

    final client = FeatureHubRestClient(
      'http://localhost',
      ['ling/orm*kwong'],
      ClientFeatureRepository(),
      interval: const Duration(seconds: 60),
    );
    await client.decodeResponse(
      ApiResponse(
        200,
        {},
        Stream.value(
          utf8.encode('[{"id": "env", "features": [], "pollInterval": 1}]'),
        ),
      ),
    );
    expect(client.serverPollInterval, const Duration(seconds: 1));
  });
}
