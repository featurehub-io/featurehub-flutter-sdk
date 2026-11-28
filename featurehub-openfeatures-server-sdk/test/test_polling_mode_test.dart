// conformance: environment-test-polling. Test mode lasts for the process, so
// it has a file (an isolate) of its own.
import 'package:featurehub_openfeatures_server_sdk/featurehub_openfeatures_server_sdk.dart';
import 'package:test/test.dart';

void main() {
  FeatureHubProvider provider(Map<String, String> environment) =>
      FeatureHubProvider(
        host: 'http://localhost:8085',
        apiKey: 'default/kwong/orm*ling',
        environment: environment,
      );

  test('without it, 500ms is refused', () {
    for (final value in ['false', 'yes', '']) {
      expect(
        () => provider({
          'FEATUREHUB_CONNECT_INTERVAL': '500ms',
          'FEATUREHUB_TEST_POLLING': value,
        }),
        throwsArgumentError,
        reason: value,
      );
    }
    expect(
      () => FeatureHubProvider(
        host: 'http://localhost:8085',
        apiKey: 'default/kwong/orm*ling',
        mode: FeatureHubUpdateMode.activePolling,
        pollInterval: const Duration(milliseconds: 500),
        environment: const {},
      ),
      throwsArgumentError,
    );
  });

  test('with it, 500ms is allowed, in the environment and in code', () {
    final fromEnvironment = provider({
      'FEATUREHUB_CONNECT_INTERVAL': '500ms',
      'FEATUREHUB_TEST_POLLING': 'True',
    });
    expect(fromEnvironment.pollInterval, const Duration(milliseconds: 500));
    final inCode = FeatureHubProvider(
      host: 'http://localhost:8085',
      apiKey: 'default/kwong/orm*ling',
      mode: FeatureHubUpdateMode.activePolling,
      pollInterval: const Duration(milliseconds: 500),
      environment: const {},
    );
    expect(inCode.pollInterval, const Duration(milliseconds: 500));
    expect(
      () => provider({
        'FEATUREHUB_CONNECT_INTERVAL': '-1s',
        'FEATUREHUB_TEST_POLLING': 'true',
      }),
      throwsArgumentError,
    );
  });
}
