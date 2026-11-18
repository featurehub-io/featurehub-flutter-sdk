# FeatureHub OpenFeature provider for Dart servers

The [FeatureHub](https://www.featurehub.io) provider for the
[OpenFeature Dart server SDK](https://pub.dev/packages/openfeature_dart_server_sdk),
for servers and command line applications (`dart:io`: Linux, macOS and Windows).
For Flutter and browser applications use
[`featurehub_openfeatures_client_sdk`](../featurehub-openfeatures-client-sdk).

The provider keeps the whole feature bundle of a FeatureHub environment in a
local repository, kept up to date by streaming (server-sent events), polling
or passive refresh, and resolves every flag from it: there is no network call
per flag.

## Usage

```dart
final api = OpenFeatureAPI();
// configured from FEATUREHUB_EDGE_URL and FEATUREHUB_CLIENT_API_KEY (see
// below), or pass host: and apiKey:
await api.setProviderAndWait(FeatureHubProvider());

final client = api.getClient('my-app');
final enabled = await client.getBooleanFlag(
  'new-checkout',
  defaultValue: false,
  context: const EvaluationContext(
    targetingKey: 'user-123',
    attributes: {'country': 'new_zealand', 'version': '2.1.0'},
  ),
);
```

[`example/main.dart`](example/main.dart) is a todo server built with
[Shelf](https://pub.dev/packages/shelf): a Dart version of the
[FeatureHub Python SDK example](https://github.com/featurehub-io/featurehub-python-sdk/tree/main/example),
which evaluates features for the user in each request. It also serves the
features to its own clients from `GET /features`, evaluated for the context
in the query parameters (for example `/features?targetingKey=fred&country=nz`)
with `featureSnapshot`. With no query parameters, what it serves is the
server's choice, set by `serveStrategiesWithoutContext` in the example (the
`includeStrategies` option of `featureSnapshot`): by default the features
evaluated as for an empty context, or, if set, the features as they are,
rollout strategies included, for clients that evaluate them locally (a
provider with `sendContext: false`). That exposes every strategy, so set it
only for trusted clients. The response's ETag is the features' SHA, so a client
that sends it back in `If-None-Match` gets a `304 Not Modified` until the
features change. A provider polls it with `featuresUrl`. Serving features
this way needs a client-evaluated key, so the example refuses to start with a
server-evaluated one.

## Configuration from the environment

Anything not passed to `FeatureHubProvider` is read from the environment:

| Variable | Used for |
|---|---|
| `FEATUREHUB_EDGE_URL` | `host`, the FeatureHub Edge URL |
| `FEATUREHUB_CLIENT_API_KEY` | `apiKey`: a client-evaluated key (preferred if both keys are set) |
| `FEATUREHUB_SERVER_API_KEY` | `apiKey`: a server-evaluated key, used if `FEATUREHUB_CLIENT_API_KEY` is not set |
| `FEATUREHUB_POLL_INTERVAL` | `pollInterval`, in seconds: if set, the provider polls at this interval instead of streaming (0 polls once; otherwise at least 5) |

Arguments take precedence over the environment. The constructor throws an
`ArgumentError` if there is a host but no API key or the reverse, or if
`FEATUREHUB_POLL_INTERVAL` is not a number of seconds: 0, or at least 5.

With a `featuresUrl` instead of a host and API key, the provider gets its
features from another server's API rather than from FeatureHub (see the
client provider's
[README](../featurehub-openfeatures-client-sdk/README.md#features-from-your-own-server)
for the API). It polls, or passively refreshes, every `pollInterval`, which is
then required. FeatureHub settings in the environment are ignored.

By default no context is sent, so the other server must serve the features
with their strategies when there is no context
(`featureSnapshot(context: ..., includeStrategies: true)`). A server that
evaluates them for an empty context instead (the default) gives this
provider every feature's default value, whatever the context. Each
resolution then evaluates them against its own context, as for a
client-evaluated key. With `sendContext: true` the server evaluates the
features for one context, as for a server-evaluated key, which suits a
single-user process only.

With no host, API key or `featuresUrl`, the provider gets its features from
its `stores` alone (it needs at least one, or the constructor throws).

## API keys

- **Client-evaluated keys** (containing `*`) are recommended for servers.
  FeatureHub sends every feature's rollout strategies, and each resolution is
  evaluated locally against its own evaluation context, so concurrent
  requests for different users are independent.
- **Server-evaluated keys** make FeatureHub Edge evaluate the bundle for a
  single context, so **a provider using one serves a single user**. It
  cannot be shared between users. It is intended for apps, browsers and
  batch processes that act for one user, or with one context, at a time.
  **Where the context switches, such as a server handling requests for
  different users, you must use a client-evaluated key.**

  If the context does change, the bundle is fetched again for the new
  context, and resolutions wait for it. If that fetch fails or times out
  (after `waitForReady`), resolutions are answered from the previous
  context's bundle.

## Several connections, with different API keys

One process can hold several providers, each with its own API key. Each
provider has its own connection, repository and transport: separate
streams or polls, separate readiness and stale state. Nothing is shared
between them.

Each API key can give different features, which is a reason to use more
than one. A server that
serves features to its own clients (see
[`example/main.dart`](example/main.dart)) can serve them from one key,
and use another for its own flags. Its clients then see only the features
that key gives, and none of the features the server uses itself.

Bind each provider to its own OpenFeature domain:

```dart
final api = OpenFeatureAPI();

// the server's own flags
final own = FeatureHubProvider(host: edgeUrl, apiKey: serverKey);
await api.setProviderForDomainAndWait('vanilla', own, providerId: 'featurehub-vanilla');

// the features served to the server's clients (GET /features)
final served = FeatureHubProvider(host: edgeUrl, apiKey: browserKey);
await api.setProviderForDomainAndWait('pistachio', served, providerId: 'featurehub-pistachio');

final client = api.getClient('todo-server', domain: 'vanilla');

// in the GET /features handler, snapshot the served provider's repository
final snapshot = served.repository!.featureSnapshot(context: queryContext(request));
```

- **Give each provider a distinct `providerId`.** The OpenFeature SDK
  registers a provider under its metadata name unless told otherwise, and
  every FeatureHub provider is named `featurehub`, so a second one would
  collide with the first.
- **Pass `host` and `apiKey` explicitly.** Anything not passed is read from
  the environment (see above), so two providers left to it get the same key.
- **`setProviderAndWait` sets the default provider:** use it for at most
  one of them. A client with no domain resolves from the default.
- A key whose features are served to other clients must be client-evaluated
  (see [API keys](#api-keys)). The server's own key can be either kind, with
  the restrictions above.

## Evaluation context

The OpenFeature `targetingKey` is FeatureHub's `userkey`, the default key for
percentage rollouts (a `session` attribute takes precedence). FeatureHub's
well-known attributes (`StrategyAttributeWellKnownNames` in the Edge API:
`country`, `device`, `platform`, `version`, `session`) are recognised
case-insensitively; anything else is a custom
attribute. Values may be strings, numbers, booleans, `DateTime`s or lists of
those; anything else resolves with `INVALID_CONTEXT`.

## Resolution

| Situation | Value | Reason | Error code |
|---|---|---|---|
| A rollout strategy matched | the strategy's value | `TARGETING_MATCH` (variant: the strategy id) | |
| A percentage rollout strategy matched locally (client-evaluated key) | the strategy's value | `SPLIT` (variant: the strategy id) | |
| Otherwise | the feature's value | `STATIC` | |
| The feature has no value (or the matched strategy has none) | the default | `DISABLED` | |
| Unknown flag | the default | `ERROR` | `FLAG_NOT_FOUND` |
| Wrong type (e.g. a string flag as boolean, 1.5 as integer) | the default | `ERROR` | `TYPE_MISMATCH` |
| Invalid JSON for an object flag | the default | `ERROR` | `PARSE_ERROR` |
| Before initialization | the default | `ERROR` | `PROVIDER_NOT_READY` |

Flag metadata carries `featureVersion` and `featureType`, plus the feature's
properties (`FeatureState.fp`) when it has any.

## Options

| Option | Default | |
|---|---|---|
| `host` | `FEATUREHUB_EDGE_URL` | |
| `apiKey` | `FEATUREHUB_CLIENT_API_KEY`, then `FEATUREHUB_SERVER_API_KEY` | |
| `mode` | `activePolling` if there is a poll interval (or a `featuresUrl`), otherwise `streaming` | `streaming` (FeatureHub only), `activePolling` (every `pollInterval`) or `passivePolling` (fetch on resolution once older than `pollInterval`) |
| `pollInterval` | `FEATUREHUB_POLL_INTERVAL` (seconds), otherwise none | required for `activePolling` and `passivePolling`. 0 polls once, at start-up, and never again (a context change still fetches); anything else must be at least 5 seconds (an `ArgumentError`), and a FeatureHub `Cache-Control: max-age` below that is raised to it |
| `waitForReady` | 10s | how long initialization, and a server-evaluated context change, wait for features |
| `reconnectPolicy` | `defaultReconnectPolicy`: 3s after a network error, 30s after a 5xx (or an invalid 1xx or 3xx), doubling with each consecutive failure up to 5 minutes; a 200 that is not an event stream (e.g. a proxy's HTML page) is retried as a network error; every wait is at least 100ms, and a server's `retry:` at least 1s; consecutive failures are counted until FeatureHub sends an event, not just until a connection opens, so a server that drops every connection still backs off and uses up `maxAttempts`; a 4xx, 429 included, stops for good. Any stop for good (also an unretried status, or running out of `maxAttempts`) is a failure: before any features the provider fails to initialize, after them it goes `stale` | streaming reconnection; set any value with your own `ReconnectPolicy(delay:, serverErrorDelay:, backoffMultiplier:, maxDelay:, maxAttempts:)` (see `featurehub_sse_client`) |
| `connectTimeout` | none | how long establishing an HTTP connection may take |
| `stores` | none | stores that keep a copy of the features, attached before connecting (see `FeatureStore`): e.g. `featurehub_openfeatures_store_redis`, to share features between processes |
| `interceptors` | none | value interceptors that supply feature values in place of FeatureHub's (see `ValueInterceptor`), overriding locked features too: e.g. `LocalYamlValueInterceptor` from `featurehub_openfeatures_yaml_interceptor`, for local overrides during development |
| `catchAndReleaseMode` | false | hold feature updates back until `release()` is called; takes effect once the initial features have arrived, so it can be set at creation. Released changes are announced as configuration changed events |
| `requestTimeout` | none | how long a polling request may take, or how long a streaming connection attempt waits for the stream to open (an attempt that times out is retried under `reconnectPolicy`) |
| `headers` | none | sent with every request (FeatureHub streaming and polling, and `featuresUrl`): for a gateway, extra authentication or tracing |
| `dio` | created | the `Dio` for polling, e.g. one configured with a proxy |
| `httpClient` | created | the `http.Client` for streaming, e.g. one configured with a proxy |
| `transportFactory` | none | your own transport (WebSockets, another SSE client, ...) in place of the built-in ones |
| `featuresUrl`, `sendContext` | none, false | poll another server instead of FeatureHub (see above) |

See the common package's README for
[headers and proxies](../featurehub-openfeatures-common/README.md#headers-and-proxies)
and [writing your own transport](../featurehub-openfeatures-common/README.md#writing-your-own-transport).

## Events

`PROVIDER_READY` once features have arrived, and
`PROVIDER_CONFIGURATION_CHANGED` (with the changed flag keys) when features
change. A lost connection that is being re-established is not reported: the
provider stays ready, and the features arrive again on reconnection. If
FeatureHub rejects the API key before any features, initialization fails
with `PROVIDER_ERROR` (`PROVIDER_FATAL`).

Any permanent stop after features have arrived (FeatureHub rejecting the key,
or the environment going stale) is reported as `PROVIDER_STALE`, once and for
good; flags keep resolving from the last features.

When the environment goes stale (FeatureHub answers `236`, or sends
`edge.stale`), the provider stops fetching and reports `PROVIDER_STALE` for
good, after `PROVIDER_READY` if it was stale from the start. Flags keep
resolving from the last features, with their usual reasons.
