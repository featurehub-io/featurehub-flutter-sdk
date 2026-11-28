/// Browser storage for the FeatureHub OpenFeature client provider: a web
/// application starts with the features it last had instead of waiting for
/// FeatureHub.
///
/// ```dart
/// await OpenFeatureAPI.instance.setProviderAndWait(
///   FeatureHubProvider(
///     host: 'https://edge.example.com',
///     apiKey: apiKey,
///     stores: [LocalSessionStore()], // or LocalSessionStore.localStorage()
///   ),
/// );
/// ```
library;

export 'src/local_session_store.dart';
