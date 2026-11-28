import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_openfeatures_common/featurehub_openfeatures_common.dart'
    as fh;

/// A transport that delivers [features] (computed from the context header
/// for server-evaluated keys) straight into the repository.
class FakeTransport implements fh.FeatureHubTransport {
  final fh.ClientFeatureRepository repository;
  final List<FeatureState> Function(String? header) features;
  final bool fail;
  final headers = <String?>[];
  bool closed = false;

  /// When set, deliveries wait for it.
  Future<void>? hold;

  FakeTransport(this.repository, this.features, {this.fail = false});

  Future<void> _deliver() async {
    final header = repository.clientContext.generateHeader();
    headers.add(header);
    await Future<void>.delayed(Duration.zero);
    await hold;
    if (fail) {
      repository.notify(SSEResultState.failure, null);
    } else {
      repository.notify(SSEResultState.features, features(header));
    }
  }

  @override
  Future<void> start() => _deliver();

  @override
  Future<void> contextChanged() => _deliver();

  @override
  Future<void> refreshIfStale() async {}

  @override
  Future<void> close() async => closed = true;
}

/// The features used by the tests; `who` is the userkey from the context
/// header, so server-side evaluation is visible.
List<FeatureState> bundle([String? header]) => [
  FeatureState(
    id: 'f-flag',
    key: 'flag',
    version: 1,
    type: FeatureValueType.BOOLEAN,
    value: true,
  ),
  FeatureState(
    id: 'f-colour',
    key: 'colour',
    version: 2,
    type: FeatureValueType.STRING,
    value: 'blue',
    strategies: [
      FeatureRolloutStrategy(
        id: 'nz-users',
        value: 'green',
        attributes: [
          FeatureRolloutStrategyAttribute(
            conditional: RolloutStrategyAttributeConditional.EQUALS,
            fieldName: 'country',
            values: ['new_zealand'],
            type: RolloutStrategyFieldType.STRING,
          ),
        ],
      ),
    ],
  ),
  FeatureState(
    id: 'f-limit',
    key: 'limit',
    version: 1,
    type: FeatureValueType.NUMBER,
    value: 10,
  ),
  FeatureState(
    id: 'f-rate',
    key: 'rate',
    version: 1,
    type: FeatureValueType.NUMBER,
    value: 0.25,
  ),
  FeatureState(
    id: 'f-config',
    key: 'config',
    version: 1,
    type: FeatureValueType.JSON,
    value: '{"retries": 3}',
  ),
  FeatureState(
    id: 'f-empty',
    key: 'empty',
    version: 1,
    type: FeatureValueType.STRING,
  ),
  FeatureState(
    id: 'f-who',
    key: 'who',
    version: 1,
    type: FeatureValueType.STRING,
    value: RegExp(r'userkey=([^,]*)').firstMatch(header ?? '')?[1] ?? 'nobody',
    // the strategy the server applied, if any
    v: header == null ? null : 'by-user',
  ),
];
