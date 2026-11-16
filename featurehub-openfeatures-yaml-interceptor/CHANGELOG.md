# Changelog

## 1.0.0

- First release: `LocalYamlValueInterceptor` and `LocalYamlFeatureStore`,
  feature values from a local YAML file for the FeatureHub OpenFeature
  providers, reading the same files as the TypeScript SDK's
  `featurehub-yaml-interceptor`. Features loaded from the file have version 0,
  so FeatureHub's own features replace them.
