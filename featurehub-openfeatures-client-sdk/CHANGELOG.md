# Changelog

## 1.0.0

- First release: the FeatureHub provider for the OpenFeature Dart client SDK
  (Flutter and browsers), supporting server- and client-evaluated API keys,
  context reconciliation, streaming (native `EventSource` in browsers),
  polling and passive refresh, with optional HTTP connect and request timeouts.
- A poll interval of 0 polls once; any other must be at least 5 seconds.
- A `readTimeout` option for streaming connections (`dart:io` only).
- The default mode is `activePolling` (every `pollInterval`, 30 seconds by
  default), for a client- or a server-evaluated key alike.
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
- Streaming reconnects back off by default (doubling up to 5 minutes;
  `defaultReconnectPolicy`), and every value is configurable.
  In browsers, a connection error is final.
- A lost connection is no longer reported as stale. Any permanent stop after
  features have arrived (a rejection, a browser connection error, a stale
  environment) is reported as stale, for good, and flags keep resolving from
  the last features; a rejection before any features still fails
  initialization.
- `mode` is `streaming`, `activePolling` or `passivePolling` (previously
  `streaming`, `polling` or `passive`).
- A context change is not a reason to report stale: only a permanent failure
  (the repository's `connectionFailed`) or a stale environment are. The
  provider initializes if the source stopped for good with its first features
  (READY, then STALE).
