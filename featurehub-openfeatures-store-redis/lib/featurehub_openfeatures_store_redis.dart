/// Redis storage for the FeatureHub OpenFeature server provider: features
/// shared between processes, in the format every FeatureHub SDK uses.
///
/// ```dart
/// final store = await RedisFeatureStore.fromUrl('redis://localhost:6379');
/// await OpenFeatureAPI().setProviderAndWait(
///   FeatureHubProvider(stores: [store]),
/// );
/// ```
library;

export 'src/redis_commands.dart';
export 'src/redis_feature_store.dart';
