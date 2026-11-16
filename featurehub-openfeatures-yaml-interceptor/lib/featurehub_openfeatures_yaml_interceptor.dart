/// Feature values from a local YAML file, for development and testing with
/// the FeatureHub OpenFeature providers.
///
/// [LocalYamlFeatureStore] loads the file's features into the repository
/// when the provider starts, and [LocalYamlValueInterceptor] supplies their
/// values, picking up edits to the file:
///
/// ```dart
/// await OpenFeatureAPI().setProviderAndWait(
///   FeatureHubProvider(
///     stores: [LocalYamlFeatureStore()],
///     interceptors: [LocalYamlValueInterceptor(watchForChanges: true)],
///   ),
/// );
/// ```
library;

export 'src/local_yaml_feature_store.dart';
export 'src/local_yaml_value_interceptor.dart';
export 'src/yaml_flag_values.dart'
    show defaultYamlFile, localYamlVariable, loadFlagValues;
