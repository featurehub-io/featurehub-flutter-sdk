import 'dart:convert';

import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_openfeatures_server_sdk/featurehub_openfeatures_server_sdk.dart';
import 'package:openfeature_dart_server_sdk/evaluation_context.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../example/main.dart' as example;

FeatureState _pastry() => FeatureState(
  id: 'fv-pastry',
  key: 'kwong_pastry',
  version: 1,
  type: FeatureValueType.STRING,
  value: 'egg tart',
  strategies: [
    FeatureRolloutStrategy(
      id: 'th',
      value: 'mango sticky rice',
      attributes: [
        FeatureRolloutStrategyAttribute(
          conditional: RolloutStrategyAttributeConditional.EQUALS,
          fieldName: 'country',
          values: ['thailand'],
          type: RolloutStrategyFieldType.STRING,
        ),
      ],
    ),
  ],
);

/// Gives the provider its features, as FeatureHub would.
class _Store implements FeatureStore {
  @override
  bool get connected => true;

  @override
  Future<void> attach(FeatureStoreTarget target) async =>
      target.repository.notify(SSEResultState.features, [_pastry()]);

  @override
  Future<void> close() async {}
}

void main() {
  late FeatureHubProvider provider;

  setUp(() async {
    // the environment is not read, so only the store gives features
    provider = FeatureHubProvider(environment: const {}, stores: [_Store()]);
    await provider.initializeProvider(const EvaluationContext(attributes: {}));
  });
  tearDown(() => provider.shutdownProvider());

  Future<Map<String, dynamic>> get(
    String query, {
    bool includeStrategies = false,
  }) async {
    final response = example.features(
      Request('GET', Uri.parse('http://localhost/features$query')),
      provider,
      includeStrategies: includeStrategies,
    );
    expect(response.statusCode, 200);
    final body = jsonDecode(await response.readAsString());
    return (body['features'] as List).single as Map<String, dynamic>;
  }

  test('by default, no query is evaluated as an empty context', () async {
    expect(example.serveStrategiesWithoutContext, false);
    final pastry = await get('');
    expect(pastry['value'], 'egg tart');
    expect(pastry['v'], isNull);
    expect(pastry.containsKey('strategies'), false);
  });

  test('if chosen, no query serves the features with strategies', () async {
    final pastry = await get('', includeStrategies: true);
    expect(pastry['value'], 'egg tart');
    expect(pastry['strategies'], hasLength(1));
  });

  test('with a query, they are evaluated for it', () async {
    for (final includeStrategies in [false, true]) {
      final pastry = await get(
        '?targetingKey=lingling&country=thailand',
        includeStrategies: includeStrategies,
      );
      expect(pastry['value'], 'mango sticky rice');
      expect(pastry['v'], 'th');
      expect(pastry.containsKey('strategies'), false);
    }

    final elsewhere = await get('?targetingKey=orm&country=china');
    expect(elsewhere['value'], 'egg tart');
    expect(elsewhere['v'], isNull);
  });
}
