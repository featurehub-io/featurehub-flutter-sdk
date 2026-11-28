# Changelog

## 1.0.0

- First release: the FeatureHub provider for the OpenFeature Dart server SDK,
  supporting client- and server-evaluated API keys, streaming, polling and
  passive refresh, with optional HTTP connect and request timeouts.
- The host, API key, mode and poll interval can come from
  `FEATUREHUB_EDGE_URL`, `FEATUREHUB_CLIENT_API_KEY` (preferred) or
  `FEATUREHUB_SERVER_API_KEY`, `FEATUREHUB_CONNECT_TYPE` (`active`, `passive`
  or `streaming`) and `FEATUREHUB_CONNECT_INTERVAL` (a duration such as `30s`).
  The provider streams unless there is a mode or a poll interval. A poll
  interval of 0 polls once; any other must be at least 5 seconds. Polling
  takes its request timeout from `FEATUREHUB_POLLING_REQ_TIMEOUT`; streaming
  its connect and read timeouts from `FEATUREHUB_SSE_CONNECT_TIMEOUT` and
  `FEATUREHUB_SSE_READ_TIMEOUT`, and, without a `reconnectPolicy`, its delays
  from `FEATUREHUB_SSE_INITIAL_RETRY_DELAY`, `FEATUREHUB_SSE_MAX_RETRY_DELAY`
  and `FEATUREHUB_SSE_BACKOFF_MULTIPLIER`. Every duration is one number and a
  unit (`ms`, `s`, `m`, `h`); an invalid value is an `ArgumentError`.
- A `readTimeout` option for streaming connections.
- Initialisation succeeds with readiness Stale only when the source has
  stopped for good (READY, then STALE); Stale only because a context change is
  in progress is a timeout (ERROR, GENERAL).
- Shutting down closes the stores and interceptors, so a provider that has
  been shut down cannot be initialized again: it reports a fatal error.
- The example has `/health/liveness`, stops cleanly on `SIGTERM` as well as
  Ctrl-C, and is built into an image by the repository's `Dockerfile`.
- Without a mode or a poll interval, the provider streams, for a client- or a
  server-evaluated key alike.
- A server-evaluated key has one active context. A resolution with a new
  context, and every resolution after it, waits for the new context's
  features; none is answered from the previous context's. If they do not
  arrive within `waitForReady`, the resolution returns its default with
  `PROVIDER_NOT_READY`, and the next waits again. Once FeatureHub has stopped
  for good, the last features serve only the context they belong to: any
  other context gets its default with `PROVIDER_NOT_READY`.
- Exports `FeatureHubFeatureUpdater` (with `FeatureUpdate` and `FeatureUpdateResult`), which changes features' values
  and locks through FeatureHub Edge, for tests.
- A `catchAndReleaseMode` option (and `release()`), which can be set when the
  provider is created.
- A `stores` option for feature stores, attached before connecting.
- An `interceptors` option for value interceptors, e.g. local YAML overrides.
- A failed initialization starts nothing for an invalid context, and closes the
  stores when FeatureHub does not become ready.
- `FeatureSnapshotStore`, a feature store that serves the provider's features
  to your own server's clients (`featureSnapshot`, `etagFor`): evaluated for
  each request's context, without value interceptors, or with no context, as
  your code chooses with `includeStrategies` (by default evaluated as for an
  empty context; with `includeStrategies: true` as delivered, strategies
  included, for clients that evaluate locally). Each snapshot's sha covers its
  features, its form and its context; its ETag adds a count of the moments a
  value can change with the clock (`"<sha>_t<count>"`), so a client never
  keeps a value after its time. It refuses to attach to a server-evaluated
  key. The example serves `GET /features` from one.
- `featuresSha`, the SHA of features' ids and versions that every FeatureHub
  SDK computes (the Redis store's), and `snapshotSha`.
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
- `mode` is `streaming`, `activePolling` or `passivePolling` (previously
  `streaming`, `polling` or `passive`).
- A context change is not a reason to report stale: only a permanent failure
  (the repository's `connectionFailed`) or a stale environment are. The
  provider initializes if the source stopped for good with its first features
  (READY, then STALE).
