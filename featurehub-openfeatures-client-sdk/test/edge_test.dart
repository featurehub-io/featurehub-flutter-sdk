// Runs on the VM and in a browser (`dart test -p vm,chrome`): streaming uses
// featurehub_sse_client on the VM and the native EventSource in browsers;
// polling uses dio on both.
import 'package:async/async.dart';
import 'package:featurehub_openfeatures_client_sdk/featurehub_openfeatures_client_sdk.dart';
import 'package:openfeature_dart_client_sdk/openfeature_dart_client_sdk.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

void main() {
  late StreamChannel<Object?> edge;
  late String host;
  final api = OpenFeatureAPI.instance;

  setUp(() async {
    edge = spawnHybridUri('edge_server.dart');
    host = 'http://127.0.0.1:${await StreamQueue(edge.stream).next}';
  });

  tearDown(() async {
    await api.shutdown();
    await edge.sink.close();
  });

  test(
    'an unanswered connection is retried after the request timeout',
    () async {
      await api.setProviderAndWait(
        FeatureHubProvider(
          host: host,
          apiKey: 'env/key*slow',
          requestTimeout: const Duration(milliseconds: 300),
          connectTimeout: const Duration(seconds: 2),
          reconnectPolicy: const ReconnectPolicy(
            delay: Duration(milliseconds: 10),
          ),
        ),
      );
      expect(api.getClient().getBooleanValue('flag', false), true);
    },
  );

  for (final mode in [
    FeatureHubUpdateMode.streaming,
    FeatureHubUpdateMode.polling,
  ]) {
    test('client-evaluated key (${mode.name})', () async {
      await api.setEvaluationContextAndWait(
        EvaluationContext(attributes: {'country': 'new_zealand'}),
      );
      await api.setProviderAndWait(
        FeatureHubProvider(host: host, apiKey: 'env/key*secret', mode: mode),
      );
      final details = api.getClient().getStringDetails('colour', '');
      expect(details.value, 'green');
      expect(details.variant, 'nz-users');
    });

    test('server-evaluated key (${mode.name})', () async {
      await api.setEvaluationContextAndWait(
        EvaluationContext(targetingKey: 'fred'),
      );
      await api.setProviderAndWait(
        FeatureHubProvider(host: host, apiKey: 'env/key', mode: mode),
      );
      final client = api.getClient();
      expect(client.getStringValue('who', ''), 'fred');

      await api.setEvaluationContextAndWait(
        EvaluationContext(targetingKey: 'mary'),
      );
      expect(client.getStringValue('who', ''), 'mary');
    });
  }
}
