import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_openfeatures_common/featurehub_openfeatures_common.dart';

import 'yaml_flag_values.dart';

/// The source [LocalYamlFeatureStore] gives the features it loads (the same
/// as the TypeScript SDK's).
const localYamlStoreSource = 'local-yaml-store';

/// Loads the features in a local YAML file (the format
/// [LocalYamlValueInterceptor] reads) into a repository, for development and
/// testing without FeatureHub.
///
/// Each value becomes a feature of the type it implies: `true`/`false` (also
/// as strings, in any case) boolean, numbers number, other strings string,
/// maps and lists JSON, and `~` (null) a string feature without a value.
/// Each feature has version 0, so FeatureHub's features replace them. A
/// feature's id is the first 8 hex digits of the SHA-256 of its key, so it is
/// the same on every run.
///
/// It is normally used together with a [LocalYamlValueInterceptor] reading
/// the same file: the store creates the features, so they exist with a type
/// and a value straight away, and the interceptor supplies their values,
/// picking up edits to the file and continuing to override them once
/// FeatureHub's features arrive and replace the store's.
///
/// The file is read once, when the store is attached (as one of a provider's
/// `stores`) or [load] is called. Without a provider, [load] fills a
/// [ClientFeatureRepository] directly.
///
/// It is the Dart equivalent of the TypeScript SDK's `LocalYamlFeatureStore`.
class LocalYamlFeatureStore implements FeatureStore {
  /// The YAML file read.
  final String path;

  bool _attached = false;

  /// Reads [filename], else the file named by `FEATUREHUB_LOCAL_YAML`, else
  /// `featurehub-features.yaml` in the current directory. [environment]
  /// replaces the process environment (for tests).
  LocalYamlFeatureStore({String? filename, Map<String, String>? environment})
    : path = resolveYamlFile(filename, environment);

  /// The features in the file, in [environmentId] if given.
  List<FeatureState> features({String? environmentId}) => [
    for (final MapEntry(:key, :value) in loadFlagValues(path).entries)
      _feature(key, value, environmentId),
  ];

  static FeatureState _feature(String key, Object? value, String? envId) {
    final type = detectFeatureValueType(value);
    return FeatureState(
      id: shortSha256(key),
      key: key,
      l: false,
      // the lowest version, so any feature from FeatureHub replaces it
      version: 0,
      type: type,
      value: prepareFeatureValue(type, value),
      environmentId: envId,
    );
  }

  /// The first 8 hex digits of the SHA-256 of [key]: the id given to its
  /// feature.
  static String shortSha256(String key) =>
      sha256.convert(utf8.encode(key)).toString().substring(0, 8);

  /// Reads the file and gives its features to [repository], which is then
  /// ready.
  void load(ClientFeatureRepository repository, {String? environmentId}) {
    repository.notify(
      SSEResultState.features,
      features(environmentId: environmentId),
      source: localYamlStoreSource,
    );
  }

  @override
  Future<void> attach(FeatureStoreTarget target) async {
    load(target.repository, environmentId: target.environmentId);
    _attached = true;
  }

  @override
  bool get connected => _attached;

  @override
  Future<void> close() async => _attached = false;
}
