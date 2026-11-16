/// The FeatureHub provider for the OpenFeature Dart server SDK.
///
/// ```dart
/// final api = OpenFeatureAPI();
/// // host and API key from FEATUREHUB_EDGE_URL and FEATUREHUB_CLIENT_API_KEY
/// // (or FEATUREHUB_SERVER_API_KEY), or pass host: and apiKey:
/// await api.setProviderAndWait(FeatureHubProvider());
/// final enabled = await api.getClient('my-app').getBooleanFlag(
///   'new-checkout',
///   defaultValue: false,
///   context: const EvaluationContext(
///     targetingKey: 'user-123',
///     attributes: {'country': 'new_zealand'},
///   ),
/// );
/// ```
library;

export 'package:featurehub_openfeatures_common/featurehub_openfeatures_common.dart'
    show FeatureHubUpdateMode, InvalidContextException;
export 'package:featurehub_sse_client/featurehub_sse_client.dart'
    show ReconnectPolicy;

export 'src/featurehub_provider.dart';
