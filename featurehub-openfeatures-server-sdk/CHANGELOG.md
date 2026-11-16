# Changelog

## 1.0.0

- First release: the FeatureHub provider for the OpenFeature Dart server SDK,
  supporting client- and server-evaluated API keys, streaming, polling and
  passive refresh, with optional HTTP connect and request timeouts.
- The host, API key and poll interval can come from `FEATUREHUB_EDGE_URL`,
  `FEATUREHUB_CLIENT_API_KEY` (preferred) or `FEATUREHUB_SERVER_API_KEY`, and
  `FEATUREHUB_POLL_INTERVAL`. The provider streams unless there is a poll
  interval.
- A `catchAndReleaseMode` option (and `release()`), which can be set when the
  provider is created.
