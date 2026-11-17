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
- A failed initialization starts nothing for an invalid context, and closes the
  stores when FeatureHub does not become ready.
- A `featuresUrl` option, instead of `host` and `apiKey`: the provider polls
  (or passively refreshes) the features from your own server's API, which by
  default evaluates them for the context sent as query parameters
  (`sendContext`), with `If-None-Match`/`304` handling. With none of these the
  features come from the `stores` alone.
- `headers` sent with every request, `dio` and `httpClient` options to
  replace the HTTP clients (e.g. for a proxy), and `transportFactory` for your
  own transport (WebSockets, another SSE client, ...).
- A stale environment (`236` or `edge.stale`) is reported as stale, for good;
  flags keep resolving from the last features.
