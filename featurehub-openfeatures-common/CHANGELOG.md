featurehub_openfeatures_common 1.0.0
====================================
This package replaces `featurehub_client_sdk` (whose history follows) as the common basis of the FeatureHub
OpenFeature providers for Dart.

* `FeatureHubConfig` is renamed `FeatureHubRestClient`, and the transports are split out (`lib/src/transport/`):
  `FeatureHubSseTransport` and `FeatureHubPollingTransport` (FeatureHub, with a host and API key) and
  `FeatureSnapshotTransport` (your own server, with a `featuresUrl` and no API key), sharing `PollingTransport`.
  `isClientEvaluatedKeys` is a top-level function. `FeatureHubUpdateMode` is `streaming`, `passivePolling` and
  `activePolling` (previously `streaming`, `passive` and `polling`)
* Streaming: the default reconnect policy retries every status but a 4xx (`featureHubShouldRetryStatus`): a 5xx, or
  an invalid 1xx or 3xx, is retried with the 5xx backoff; every 4xx, 429 included, stops for good. Whenever the event
  source stops for good (also a status a custom policy does not retry, or running out of `maxAttempts`) the
  repository is notified of a failure, not a `bye`, so the provider goes stale after features (or fails to
  initialize before them) rather than waiting for a reconnection that never comes
* `FeatureHubConnection`'s `mode` defaults to `activePolling` with a `featuresUrl` (as the providers do), and to
  `streaming` otherwise
* `ClientFeatureRepository.loadFeatureSnapshot` replaces `FeatureHubRestClient.loadFeatureSnapshot`, for custom
  transports too; `FeatureHubRestClient.featuresSha` is removed (use `ClientFeatureRepository.featuresSha`)
* `environmentIdFromApiKey` accepts a null key (giving the placeholder id)
* Requires Dart 3.12.2 or later
* Removed analytics: `logAnalyticsEvent`, the `analyticsEvent` stream, `AnalyticsEvent` and the Google Analytics
  listener (`GoogleAnalyticsListener`, `GoogleAnalyticsApiClient`, `insertGoogleAnalyticsEvValue`)
* Support for client-evaluated API keys (containing `*`): rollout strategies are evaluated locally, matching the
  TypeScript SDK (murmur3 percentage rollouts, string, number, date, date-time, semantic version, IP address and
  boolean matchers). `ClientFeatureRepository.evaluate(key, context:)` evaluates for any `StrategyContext`, and the
  feature holders apply strategies for the repository's `clientContext`. For these keys the context is never sent
  to FeatureHub and a context change does not reconnect
* `EvaluatedFeature.strategyId` is the strategy that matched locally for client-evaluated keys, and the strategy the
  server applied (`FeatureState.v`) for server-evaluated keys. A feature update that changes only the applied
  strategy (same version and value, e.g. after a context change) is now picked up
* New `ClientFeatureRepository.featuresChangedStream`, which emits whenever feature changes are applied: updates,
  updates applied by `release()` in catch and release mode, and deletions. (`newFeatureStateAvailableStream` still
  announces caught updates as waiting, and still does not emit on `release()` or deletion)
* Catch and release mode: features arriving after a reconnection make the repository ready again (they are still
  held until `release()`); previously it stayed not ready
* Catch and release mode takes effect only once the initial features (or a failure) have arrived, so it can be
  switched on when the repository is created: the initial features are applied and the initial readiness (or failure)
  is broadcast as normal. Previously a single feature update arriving first was held back, and an initial `bye` or
  `failure` was not broadcast
* `ClientContext` implements `StrategyContext`; `MapStrategyContext` evaluates against a map of attributes
* `FeatureHubRestClient` rejects a mix of client- and server-evaluated keys, and `request` takes `force`
* The OpenFeature flag metadata includes the feature's properties (`FeatureState.fp`), alongside `featureVersion`
  and `featureType`
* `FeatureHubConnection` takes a `featuresUrl` instead of a `host` and `apiKey`: it polls (or passively refreshes)
  your own server's features API through the new `FeatureSnapshotClient`, sending the context as query parameters
  (unless `sendContext` is false) and the last `ETag` as `If-None-Match`. With none of these it fetches nothing and
  the repository is filled by feature stores. `FeatureStoreTarget.host` and `apiKey` are then null, and it has
  `featuresUrl` and `connectsToFeatureHub`
* `ClientContext.attributes` gives the context's attributes
* `headers` on `FeatureHubConnection` (and `FeatureHubRestClient`, the SSE listener and `FeatureSnapshotClient`) are sent
  with every request, and `dio` / `httpClient` replace the HTTP clients, e.g. for a proxy. Browsers' `EventSource`
  cannot send headers, which is logged
* Your own transports: `FeatureHubTransport` is documented as a public contract, `transportFactory` creates one with a
  `FeatureHubTransportTarget` (the repository, the connection's settings, and the context to fetch for), and
  `FeatureHubUpdateMode` moves with it to `featurehub_transport.dart` (still exported)
* Streaming reconnects with `defaultReconnectPolicy` unless given one: 3s after a network error, 30s after a 5xx,
  doubling with each consecutive failure up to 5 minutes (previously a constant delay); every value is configurable
* In browsers, a connection error (the `EventSource` giving up, which hides whether it was a 4xx or 5xx) is final:
  the listener reports a failure and stops. Previously it retried
* `ProviderStateTracker` reports stale only for a permanent stop after features (`onStale(StaleCause)`: the
  environment going stale, or the source failing for good), once, and the providers keep resolving from the last
  features; a lost connection (`bye`) is no longer reported, and nothing is reported as recovered. A failure before
  any features is still an initialization error
* A `Cache-Control: max-age` on a FeatureHub polling response replaces the poll interval, shorter or longer (as the
  TypeScript SDK does); previously it could only lengthen it
* Polling now polls at every interval: each poll was timed from the previous response rather than its request, so
  the next one was taken as still fresh and skipped, and polling happened every other interval
* `ClientFeatureRepository.featureSnapshot({context, includeStrategies})` gives the features and their SHA (a
  `FeatureSnapshot`), for a server to pass on to its own clients: with an OpenFeature context, each feature evaluated
  for it as for a server-evaluated key (no strategies, `v` the matched strategy). Without one (none, or empty), the
  caller chooses: evaluated as for an empty context (the default), or with `includeStrategies: true` as delivered,
  strategies included, for clients that evaluate locally.
  `ClientFeatureRepository.loadFeatureSnapshot(data)` loads a snapshot (or its JSON, or a list of features) into the
  repository as a full set of features
* A percentage rollout strategy matched locally resolves with the reason `SPLIT` (as the Go SDK does); other
  matches stay `TARGETING_MATCH`, including strategies the server applied
* A feature with no value set resolves to the code default with the reason `DISABLED` (as the Go SDK does), rather
  than `DEFAULT`; a matched strategy with no value keeps its id as the variant
* A stale FeatureHub environment (`236` when polling, `edge.stale` when streaming) is reported with
  `ClientFeatureRepository.markEnvironmentStale` (`environmentStale`, `environmentStaleStream`): readiness is
  unchanged, and the providers report STALE for good. Your own
  server's features API is not required to send `236`
* The well-known context keys are taken from the Edge API's `StrategyAttributeWellKnownNames` (device, country,
  platform, userkey, session, version); `email` is no longer treated as one, so it keeps the case it is given
* `ClientFeatureRepository.featuresSha`: a SHA-256 of the repository's features' sorted `id:version`s, computed
  whenever features arrive, are updated or deleted, or are released; it identifies the features for client-evaluated
  API keys. `ClientFeatureRepository.computeSha`
  is the same calculation, as every FeatureHub SDK does it (moved from the Redis store)
* `FeatureHubRestClient`: a 4xx response (FeatureHub rejecting the API key) marks the repository failed and the connection
  dead, so no further requests are made and polling stops, as streaming does. Previously only 400 and 404 were checked,
  and only when errors were returned as responses: by default the request threw and the repository was never marked
  failed. `request` no longer throws for a 4xx; other errors (network, 5xx, timeouts) are still thrown
* The browser SSE listener uses the native `EventSource` through `package:web` (replacing `dart:html`). It also
  fixes two bugs: `failure` events were never handled (it listened for `failed`), and the first context callback
  threw because it closed a connection that did not exist yet
* Optional HTTP `connectTimeout` and `requestTimeout` for `FeatureHubRestClient` (dio), the SSE listeners and
  `FeatureHubConnection`. In browsers `EventSource` connections are controlled by the browser, so only the request
  timeout (how long the stream may take to open) applies to streaming
* Raw feature updates for stores (the TypeScript SDK's `RawUpdateFeatureListener`, as a Dart stream):
  `ClientFeatureRepository.rawFeatureUpdates` publishes every features, feature and delete notification with its
  source (`notify` takes a `source`, defaulting to FeatureHub), including while catching. `FeatureStore` and
  `FeatureStoreTarget` define stores, which the providers attach before connecting
* Value interceptors that see the feature (the TypeScript SDK's `FeatureValueInterceptor`): `ValueInterceptor`,
  registered with `ClientFeatureRepository.addValueInterceptor` (and removed with `removeValueInterceptor`), is given
  the key and the feature's state and may supply typed values; `ValueMatch.value` is now an `Object?`. Interceptors
  are closed when the repository shuts down. The feature holders' `booleanValue`, `numberValue` and `jsonValue` now
  convert intercepted strings rather than failing
* OpenFeature support shared by the providers: `FeatureHubConnection` (streaming, active polling or passive polling, with
  readiness and server-evaluated context changes), `mapEvaluationContext`, `resolveFromEvaluation` and
  `ProviderStateTracker`
* Catch and release mode starts only after FeatureHub's own first features: features loaded from a store no longer
  count, so FeatureHub's first features replace them rather than being held back
* A full set of features removes features missing from it (e.g. loaded from a store, or deleted while disconnected);
  in catch and release mode they are removed on `release()`
* Catch and release mode: deleting a feature also discards any update for it being held back, so `release()` no
  longer brings it back
* An update with the same version and value now replaces a feature that has a different id or type (e.g. one loaded
  from a local file)
* The `dart:io` SSE listener: quick successive context changes (server-evaluated keys) no longer leave an earlier
  context's connection open
* Passive mode: after a failed request, no further request is made until the poll interval has passed, rather than
  one per evaluation during an outage
* Documented that a server-evaluated key serves a single user: where the context switches, a client-evaluated key
  must be used

featurehub_client_sdk history
=============================

1.5.0
=====
* Requires Dart 3.10 or later; upgraded to dio 5, openapi_dart_common 5, rxdart 0.28 and the 1.4.0
  featurehub_sse_client
* Reconnection is now handled by featurehub_sse_client rather than by the SDK (dart:io only; browsers use the
  native EventSource, which already reconnects). `EventSourceRepositoryListener` takes an optional
  `reconnectPolicy` to configure it. By default the connection is retried after 3s when lost, after 30s on a
  5xx, and stops on a 4xx.
  * while reconnecting the repository is marked not ready (`bye`)
  * a `failure` event or a stale edge closes the connection
  * if the event source gives up, a 4xx is reported to the repository as `failure`, anything else as `bye`
  * the initial connection is also retried, rather than raising an unhandled error
  * a client context change now drops the connection and reconnects with the new context header (previously
    it attempted to reopen the existing connection with the old header)
* `EventSourceRepositoryListener.closed` is now implemented on dart:io
* `SSEResultState.config` and `SSEResultState.error` are ignored by the repository
* adopted `package:lints` recommended rules and fixed all analyzer issues

1.4.0
=====
* Support for Fastly with GET requests and SSE requests
* Support for server side control of polling intervals
* Support for polling intervals (previous a check always called the server)
* Support for expired environments
* Deprecated jaeger interceptor

1.3.1
=====
* More robust reconnection in the face of disconnection

1.3.0
=====
* Introduce FeatureHubConfig
* Documentation updates
* Examples updates

1.2.0
=====
* null safe version

1.1.4
=====
* documentation updates

1.1.3
=====
* allow the release process for catch & release to turn the catch flag off once released. Ensure turning
  release off also releases caught flags.

1.1.2
=====
* Updated documentation

1.1.1
=====
* Update documentation
* Update for rollout support
* Update for w3c correlation context


1.0.1
=====
* Update to support the GET API and add documentation for the GET and Test APIs.
 
1.0.0
=====
* initial release of API. Dart IO support, with all platform support.
