# Changelog

## 1.0.0

- First release: the FeatureHub provider for the OpenFeature Dart client SDK
  (Flutter and browsers), supporting server- and client-evaluated API keys,
  context reconciliation, streaming (native `EventSource` in browsers),
  polling and passive refresh, with optional HTTP connect and request timeouts.
- A `catchAndReleaseMode` option (and `release()`), which can be set when the
  provider is created.
- A `stores` option for feature stores, attached before connecting.
- An `interceptors` option for value interceptors, e.g. local YAML overrides.
