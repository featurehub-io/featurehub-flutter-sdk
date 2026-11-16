/// Feature values from a local YAML file, for development and testing with
/// the FeatureHub OpenFeature providers.
///
/// ```dart
/// await OpenFeatureAPI().setProviderAndWait(
///   FeatureHubProvider(
///     interceptors: [LocalYamlValueInterceptor(watchForChanges: true)],
///   ),
/// );
/// ```
library;

export 'src/local_yaml_feature_store.dart';
export 'src/local_yaml_value_interceptor.dart';
export 'src/yaml_flag_values.dart'
    show defaultYamlFile, localYamlVariable, loadFlagValues;
