import '../transport/api_keys.dart';
import '../repository.dart';

/// What a [FeatureStore] is attached to: a repository, and the FeatureHub
/// environment it holds features for.
///
/// [host] and [apiKey] are null when the provider does not connect to
/// FeatureHub: it gets its features from your own server ([featuresUrl]), or
/// from its stores alone.
class FeatureStoreTarget {
  final ClientFeatureRepository repository;

  /// The FeatureHub Edge URL, or null if the provider does not connect to
  /// FeatureHub.
  final String? host;

  /// The environment's SDK API key, or null if the provider does not connect
  /// to FeatureHub.
  final String? apiKey;

  /// The URL of your own server's features API, if the provider gets its
  /// features from there rather than from FeatureHub.
  final String? featuresUrl;

  const FeatureStoreTarget({
    required this.repository,
    this.host,
    this.apiKey,
    this.featuresUrl,
  });

  /// True if the provider connects to FeatureHub (it has a [host] and an
  /// [apiKey]).
  bool get connectsToFeatureHub => host != null && apiKey != null;

  /// True if [apiKey] is client-evaluated (contains `*`). False if there is no
  /// API key.
  bool get clientEvaluated =>
      apiKey != null && isClientEvaluatedKeys([apiKey!]);

  /// The environment id from [apiKey] (see [environmentIdFromApiKey]); with
  /// no API key, the placeholder id.
  String get environmentId => environmentIdFromApiKey(apiKey);

  /// The streaming feature URL, `<host>/features/<apiKey>`, unique to the
  /// environment and key, so suitable as a storage key; or, without a
  /// FeatureHub connection, [featuresUrl]. Null if there is neither.
  String? get featureUrl {
    final host = this.host;
    if (host == null || apiKey == null) return featuresUrl;
    return '${host.endsWith('/') ? host.substring(0, host.length - 1) : host}'
        '/features/$apiKey';
  }
}

/// The environment id from an API key, as every FeatureHub SDK derives it:
/// the middle part of `portfolio/environment/key`, or the first part of
/// `environment/key`. No key (null), or any other form, gives a fixed
/// placeholder id.
///
/// Every provider without an API key (one using a `featuresUrl`, or stores
/// alone) therefore has the same id: stores that several such providers
/// share must be kept apart some other way, for example by giving each its
/// own prefix.
String environmentIdFromApiKey(String? apiKey) {
  if (apiKey == null) return _placeholderEnvironmentId;
  final parts = apiKey.split('/');
  if (parts.length >= 3) return parts[1];
  if (parts.length == 2) return parts[0];
  return _placeholderEnvironmentId;
}

/// The TypeScript SDK's placeholder for an unrecognised key.
const _placeholderEnvironmentId = '3ea0f571-c153-48bf-9543-df76c6f9ca50';

/// Keeps a copy of a repository's features outside it: for example in
/// browser storage, so an application starts with the features it last had,
/// or in Redis, so several processes share them (and keep receiving updates
/// if their own connection to FeatureHub fails).
///
/// The FeatureHub providers attach their stores (see their `stores` option)
/// before connecting to FeatureHub, so features a store holds are available
/// straight away. A store loads its features into the repository with
/// [ClientFeatureRepository.notify], giving its own source, and follows the
/// repository's [ClientFeatureRepository.rawFeatureUpdates], ignoring the
/// updates from its own source.
abstract interface class FeatureStore {
  /// Loads any features this store holds into [target]'s repository, then
  /// keeps the store up to date with the repository's updates.
  Future<void> attach(FeatureStoreTarget target);

  /// True if the store is attached and operational.
  bool get connected;

  /// Stops following updates and releases any resources.
  Future<void> close();
}
