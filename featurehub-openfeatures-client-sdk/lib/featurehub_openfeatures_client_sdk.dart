/// The FeatureHub provider for the OpenFeature Dart client SDK, for Flutter
/// (Android, iOS) and browser applications.
///
/// ```dart
/// await OpenFeatureAPI.instance.setEvaluationContextAndWait(
///   EvaluationContext(targetingKey: 'user-123'),
/// );
/// await OpenFeatureAPI.instance.setProviderAndWait(
///   FeatureHubProvider(host: 'https://edge.example.com', apiKey: apiKey),
/// );
/// final enabled = OpenFeatureAPI.instance
///     .getClient()
///     .getBooleanValue('new-checkout', false);
/// ```
library;

export 'package:featurehub_openfeatures_common/featurehub_openfeatures_common.dart'
    show
        FeatureHubUpdateMode,
        FeatureStore,
        FeatureStoreTarget,
        ValueInterceptor,
        ValueMatch,
        InvalidContextException;
export 'package:featurehub_sse_client/featurehub_sse_client.dart'
    show ReconnectPolicy;

export 'src/featurehub_provider.dart';
