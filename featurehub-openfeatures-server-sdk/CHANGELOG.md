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
- A `stores` option for feature stores, attached before connecting.
- An `interceptors` option for value interceptors, e.g. local YAML overrides.
- A failed initialization starts nothing for an invalid context, and closes the
  stores when FeatureHub does not become ready.
- Exports `FeatureSnapshot`. The example serves the features to its own
  clients from `GET /features`, evaluated for the context in the query
  parameters, with the features' SHA as the ETag (`304` on a matching
  `If-None-Match`).
- A `featuresUrl` option, instead of a host and API key: the provider polls
  (or passively refreshes) the features from another server's API, by default
  without a context, evaluating their strategies locally for each request
  (`sendContext: true` has the server evaluate them). With none of these the
  features come from the `stores` alone.
- `headers` sent with every request, `dio` and `httpClient` options to
  replace the HTTP clients (e.g. for a proxy), and `transportFactory` for your
  own transport (WebSockets, another SSE client, ...).
- A stale environment (`236` or `edge.stale`) is reported as stale, for good;
  flags keep resolving from the last features.
- Streaming reconnects back off by default (doubling up to 5 minutes;
  `defaultReconnectPolicy`), and every value is configurable.
- A lost connection is no longer reported as stale. Any permanent stop after
  features have arrived (a rejection, a stale environment) is reported as
  stale, for good, and flags keep resolving from the last features; a
  rejection before any features still fails initialization.
