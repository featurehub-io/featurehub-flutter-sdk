import 'dart:convert';
import 'dart:io';

import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_openfeatures_common/featurehub_openfeatures_common.dart';
import 'package:featurehub_openfeatures_server_sdk/featurehub_openfeatures_server_sdk.dart';
import 'package:openfeature_dart_server_sdk/evaluation_context.dart';
import 'package:openfeature_dart_server_sdk/open_feature_api.dart';
import 'package:openfeature_dart_server_sdk/provider_lifecycle.dart';
import 'package:test/test.dart';
// ignore: implementation_imports
import 'package:featurehub_openfeatures_common/src/transport/polling_limits.dart';

final _colour = FeatureState(
  id: 'fv-colour',
  key: 'colour',
  version: 1,
  type: FeatureValueType.STRING,
  value: 'blue',
  strategies: [
    FeatureRolloutStrategy(
      id: 'nz',
      value: 'green',
      attributes: [
        FeatureRolloutStrategyAttribute(
          conditional: RolloutStrategyAttributeConditional.EQUALS,
          fieldName: 'country',
          values: ['nz'],
          type: RolloutStrategyFieldType.STRING,
        ),
      ],
    ),
  ],
);

/// The server provider getting its features from another server: the
/// features as they are with no query parameters, else evaluated for them.
void main() {
  // these tests poll far faster than applications may
  setUpAll(() => minPollingInterval = const Duration(milliseconds: 1));
  tearDownAll(() => minPollingInterval = defaultMinPollingInterval);

  late HttpServer server;
  late ClientFeatureRepository features;
  late FeatureSnapshotStore snapshots;
  final queries = <String>[];

  String url() => 'http://127.0.0.1:${server.port}/features';

  setUp(() async {
    queries.clear();
    features = ClientFeatureRepository()
      ..notify(SSEResultState.features, [_colour]);
    snapshots = FeatureSnapshotStore();
    await snapshots.attach(FeatureStoreTarget(repository: features));
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      queries.add(request.uri.query);
      final params = request.uri.queryParameters;
      // with no context, the strategies, for local evaluation
      final snapshot = snapshots
          .featureSnapshot(context: params, includeStrategies: true)
          .snapshot;
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(snapshot));
      await request.response.close();
    });
  });

  tearDown(() async {
    await OpenFeatureAPI.resetInstance();
    await server.close(force: true);
    await snapshots.close();
    features.shutdown();
  });

  Future<String> colour(OpenFeatureAPI api, String country) => api
      .getClient('test')
      .getStringFlag(
        'colour',
        defaultValue: '',
        context: EvaluationContext(attributes: {'country': country}),
      );

  test('evaluates the strategies locally for each request', () async {
    final p = FeatureHubProvider(
      featuresUrl: url(),
      pollInterval: const Duration(minutes: 1),
      // ignored with a featuresUrl
      environment: const {
        'FEATUREHUB_EDGE_URL': 'http://edge',
        'FEATUREHUB_CLIENT_API_KEY': 'a/b*c',
      },
    );
    expect(p.connectsToFeatureHub, false);
    expect(p.host, isNull);
    expect(p.mode, FeatureHubUpdateMode.activePolling);
    expect(p.clientEvaluated, true);

    final api = OpenFeatureAPI();
    await api.setProviderAndWait(p);
    expect(await colour(api, 'nz'), 'green');
    expect(await colour(api, 'au'), 'blue');
    expect(queries, ['']);
  });

  test('with sendContext, the server evaluates for each context', () async {
    final p = FeatureHubProvider(
      featuresUrl: url(),
      sendContext: true,
      mode: FeatureHubUpdateMode.passivePolling,
      pollInterval: const Duration(minutes: 1),
      environment: const {},
    );
    expect(p.clientEvaluated, false);

    final api = OpenFeatureAPI();
    await api.setProviderAndWait(p);
    expect(await colour(api, 'nz'), 'green');
    expect(await colour(api, 'au'), 'blue');
    expect(queries.skip(1), ['country=nz', 'country=au']);
  });

  test('a transport of your own, given the headers', () async {
    FeatureHubTransportTarget? given;
    final p = FeatureHubProvider(
      environment: const {},
      headers: {'x-gateway-key': 'k'},
      transportFactory: (target) {
        given = target;
        return _FixedTransport(target, [_colour]);
      },
    );
    expect(p.clientEvaluated, true);
    final api = OpenFeatureAPI();
    await api.setProviderAndWait(p);
    expect(given!.headers, {'x-gateway-key': 'k'});
    expect(given!.sendsContext, false);
    expect(await colour(api, 'nz'), 'green');
    expect(await colour(api, 'au'), 'blue');
  });

  test(
    'a stale environment is ready, then stale, and keeps resolving',
    () async {
      final p = FeatureHubProvider(
        environment: const {},
        transportFactory: (target) =>
            _FixedTransport(target, [_colour], stale: true),
      );
      final events = <ProviderLifecycleEventType>[];
      final sub = p.providerEvents.listen((e) => events.add(e.type));
      final api = OpenFeatureAPI();
      await api.setProviderAndWait(p);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(events, [
        ProviderLifecycleEventType.PROVIDER_READY,
        ProviderLifecycleEventType.PROVIDER_STALE,
      ]);
      expect(await colour(api, 'nz'), 'green');
      await sub.cancel();
    },
  );

  test('a featuresUrl needs a poll interval, and no host or key', () {
    expect(
      () => FeatureHubProvider(featuresUrl: url(), environment: const {}),
      throwsArgumentError,
    );
    expect(
      () => FeatureHubProvider(
        featuresUrl: url(),
        apiKey: 'a/b',
        pollInterval: const Duration(minutes: 1),
        environment: const {},
      ),
      throwsArgumentError,
    );
  });
}

/// A transport of your own that gives a fixed set of features.
class _FixedTransport implements FeatureHubTransport {
  final FeatureHubTransportTarget target;
  final List<FeatureState> features;

  /// Report the environment stale after giving the features.
  final bool stale;

  _FixedTransport(this.target, this.features, {this.stale = false});

  @override
  Future<void> start() async {
    target.repository.notify(SSEResultState.features, features);
    if (stale) target.repository.markEnvironmentStale();
  }

  @override
  Future<void> contextChanged() async {}

  @override
  Future<void> refreshIfStale() async {}

  @override
  Future<void> close() async {}
}
