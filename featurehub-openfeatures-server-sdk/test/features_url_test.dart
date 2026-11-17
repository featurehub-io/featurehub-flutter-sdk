import 'dart:convert';
import 'dart:io';

import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_openfeatures_common/featurehub_openfeatures_common.dart';
import 'package:featurehub_openfeatures_server_sdk/featurehub_openfeatures_server_sdk.dart';
import 'package:openfeature_dart_server_sdk/evaluation_context.dart';
import 'package:openfeature_dart_server_sdk/open_feature_api.dart';
import 'package:test/test.dart';

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
  late HttpServer server;
  late ClientFeatureRepository features;
  final queries = <String>[];

  String url() => 'http://127.0.0.1:${server.port}/features';

  setUp(() async {
    queries.clear();
    features = ClientFeatureRepository()
      ..notify(SSEResultState.features, [_colour]);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      queries.add(request.uri.query);
      final params = request.uri.queryParameters;
      final snapshot = params.isEmpty
          ? features.featureSnapshot()
          : features.featureSnapshot(context: params);
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(snapshot));
      await request.response.close();
    });
  });

  tearDown(() async {
    await OpenFeatureAPI.resetInstance();
    await server.close(force: true);
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
    expect(p.mode, FeatureHubUpdateMode.polling);
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
      mode: FeatureHubUpdateMode.passive,
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

  _FixedTransport(this.target, this.features);

  @override
  Future<void> start() async =>
      target.repository.notify(SSEResultState.features, features);

  @override
  Future<void> contextChanged() async {}

  @override
  Future<void> refreshIfStale() async {}

  @override
  Future<void> close() async {}
}
