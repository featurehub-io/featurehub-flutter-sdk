featurehub_openfeatures_common 1.0.0
====================================
This package replaces `featurehub_client_sdk` (whose history follows) as the common basis of the FeatureHub
OpenFeature providers for Dart.

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
* `FeatureHubConfig` rejects a mix of client- and server-evaluated keys, and `request` takes `force`
* `FeatureHubConfig`: a 4xx response (FeatureHub rejecting the API key) marks the repository failed and the connection
  dead, so no further requests are made and polling stops, as streaming does. Previously only 400 and 404 were checked,
  and only when errors were returned as responses: by default the request threw and the repository was never marked
  failed. `request` no longer throws for a 4xx; other errors (network, 5xx, timeouts) are still thrown
* The browser SSE listener uses the native `EventSource` through `package:web` (replacing `dart:html`). It also
  fixes two bugs: `failure` events were never handled (it listened for `failed`), and the first context callback
  threw because it closed a connection that did not exist yet
* Optional HTTP `connectTimeout` and `requestTimeout` for `FeatureHubConfig` (dio), the SSE listeners and
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
* OpenFeature support shared by the providers: `FeatureHubConnection` (streaming, polling or passive refresh, with
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
