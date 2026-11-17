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
  late StreamQueue<Object?> fromEdge;
  late String host;
  final api = OpenFeatureAPI.instance;

  setUp(() async {
    edge = spawnHybridUri('edge_server.dart');
    fromEdge = StreamQueue(edge.stream);
    host = 'http://127.0.0.1:${await fromEdge.next}';
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

  group('your own server (featuresUrl)', () {
    Future<List<Map<String, Object?>>> requestLog() async {
      edge.sink.add('log');
      return [
        for (final r in await fromEdge.next as List<Object?>)
          Map<String, Object?>.from(r as Map),
      ];
    }

    for (final mode in [
      FeatureHubUpdateMode.polling,
      FeatureHubUpdateMode.passive,
    ]) {
      test('gets the features for each context (${mode.name})', () async {
        await api.setEvaluationContextAndWait(
          EvaluationContext(
            targetingKey: 'fred',
            attributes: {'country': 'new_zealand'},
          ),
        );
        final p = FeatureHubProvider(
          featuresUrl: '$host/api/features',
          mode: mode,
          pollInterval: const Duration(milliseconds: 300),
        );
        await api.setProviderAndWait(p);
        final client = api.getClient();
        expect(client.getStringValue('who', ''), 'fred');
        final colour = client.getStringDetails('colour', '');
        expect(colour.value, 'green');
        expect(colour.variant, 'nz-users');

        // polled (or, passively, refreshed when read) with the ETag
        await Future<void>.delayed(const Duration(milliseconds: 450));
        client.getStringValue('who', '');
        await Future<void>.delayed(const Duration(milliseconds: 100));

        final events = <ProviderEventType>[];
        final sub = p.events.listen((e) => events.add(e.type));
        await api.setEvaluationContextAndWait(
          EvaluationContext(targetingKey: 'mary'),
        );
        expect(client.getStringValue('who', ''), 'mary');
        expect(client.getStringValue('colour', ''), 'blue');
        expect(events, [
          ProviderEventType.reconciling,
          ProviderEventType.contextChanged,
        ]);
        await sub.cancel();

        final log = await requestLog();
        expect(log.first['query'], 'userkey=fred&country=new_zealand');
        expect(log.first['ifNoneMatch'], isNull);
        final revalidated = log.where((r) => r['status'] == 304);
        expect(revalidated, isNotEmpty);
        expect(revalidated.first['query'], 'userkey=fred&country=new_zealand');
        expect(log.last['query'], 'userkey=mary');
        expect(log.last['status'], 200);
      });
    }
  });
}
