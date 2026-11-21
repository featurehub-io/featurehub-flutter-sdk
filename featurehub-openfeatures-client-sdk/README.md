# FeatureHub OpenFeature provider for Flutter and the web

The [FeatureHub](https://www.featurehub.io) provider for the
[OpenFeature Dart client SDK](https://pub.dev/packages/openfeature_dart_client_sdk),
for Flutter (Android, iOS) and browser applications. For servers and command
line applications use
[`featurehub_openfeatures_server_sdk`](../featurehub-openfeatures-server-sdk).

The provider keeps the whole feature bundle of a FeatureHub environment in a
local repository and resolves every flag synchronously from it. It is kept up
to date by streaming (the browser's native `EventSource` on the web,
`featurehub_sse_client` elsewhere), active polling or passive polling.

## Usage

```dart
final api = OpenFeatureAPI.instance;
await api.setEvaluationContextAndWait(
  EvaluationContext(
    targetingKey: 'user-123',
    attributes: {'country': 'new_zealand'},
  ),
);
await api.setProviderAndWait(
  FeatureHubProvider(host: 'https://edge.example.com', apiKey: apiKey),
);

final enabled = api.getClient().getBooleanValue('new-checkout', false);
```

See [`example/main.dart`](example/main.dart).

## API keys

- **Server-evaluated keys** are recommended for applications: a
  client-evaluated key sends every rollout strategy (and the values in them)
  to the device. FeatureHub Edge evaluates the bundle for the application's
  evaluation context; when the context changes the provider reports
  `reconciling`, fetches the bundle for the new context, then reports
  `contextChanged`. In browsers the context is sent as the `xfeaturehub`
  query parameter, since `EventSource` cannot send headers.

  A connection with a server-evaluated key serves **a single user** and
  cannot be shared between users. It suits apps, browsers and batch
  processes, where the context changes rarely, such as when a user signs
  in. If the fetch for a new context fails or times out, the provider keeps
  the previous context's features. Where the context switches often, or
  between users, you must use a client-evaluated key.
- **Client-evaluated keys** (containing `*`) deliver every feature's rollout
  strategies, which are evaluated locally, so a context change needs no
  network request.

## Features from your own server

Give a `featuresUrl` instead of `host` and `apiKey`, and the provider gets
its features from your own server's API rather than from FeatureHub. The
server SDK's [example](../featurehub-openfeatures-server-sdk/example/main.dart)
serves that API from `GET /features`. The server evaluates the features for
the application's context, so neither a FeatureHub key nor the rollout
strategies reach the device:

```dart
await api.setProviderAndWait(
  FeatureHubProvider(
    featuresUrl: 'https://my.app/api/features',
    pollInterval: const Duration(seconds: 30),
  ),
);
```

- The context is sent as query parameters: `userkey` (OpenFeature's
  `targetingKey`), then the other attributes. A list becomes a repeated
  parameter.
- The provider polls every `pollInterval`, or with
  `mode: FeatureHubUpdateMode.passivePolling` refreshes when a flag is read once the
  features are older than that. Streaming isn't available. Each request
  sends the last `ETag` as `If-None-Match`, so the server can answer `304`.
- When the context changes the provider reports `reconciling`, fetches the
  features for the new context, then reports `contextChanged`, as for a
  server-evaluated key.
- `headers` are sent with each request, for example for authentication.
  A 4xx response other than 429 is treated as a rejection, and
  polling stops: before any features the provider fails to initialize
  (`providerFatal`), after them it reports `stale` for good.
- With `sendContext: false` no context is sent. The server must then serve
  the features with their strategies when there is no context (on a Dart
  server, `featureSnapshot(includeStrategies: true)`), and they are
  evaluated locally. A server that evaluates them for an empty context
  instead gives every feature's default value.
- A server on another origin must allow the `If-None-Match` header in its
  CORS preflight and expose the `ETag` header. The example does both.

Without a `host`, `apiKey` or `featuresUrl`, the provider gets its features
from its `stores` alone (it needs at least one).

## Evaluation context, resolution and events

These are the same as for the server provider: see its
[README](../featurehub-openfeatures-server-sdk/README.md#evaluation-context).
Events are `ready`, `configurationChanged` (with the changed flag keys),
`reconciling` and `contextChanged`, and `error` (`providerFatal`) if
FeatureHub rejects the key before any features. A lost connection that is
being re-established is not reported: the provider stays ready. Any permanent
stop after features have arrived (a rejection, a browser connection error, or
a stale FeatureHub environment: `236` when polling, `edge.stale` when
streaming) is reported as `stale`, once and for good; flags keep resolving
from the last features, and a context change keeps them.

## Catch and release

Catch and release lets the app control when feature updates reach the UI.
For example, rather than flags changing under someone mid-task, the app can
show a "new features are available" banner. When the user accepts it, the
held-back updates flow through and the app updates.

While `catchAndReleaseMode` is on, the provider keeps receiving updates from
FeatureHub but holds them back: flags keep resolving to their current values
until `release()` is called. The repository's `newFeatureStateAvailableStream`
emits when an update has been caught, which is the moment to show the banner:

```dart
final provider = FeatureHubProvider(
  host: 'https://edge.example.com',
  apiKey: apiKey,
  catchAndReleaseMode: true,
);
await api.setProviderAndWait(provider);

provider.repository?.newFeatureStateAvailableStream.listen((_) {
  // show "New features are available", calling provider.release() on accept
});
```

On `release()`, everything held back is applied at once, and the provider
emits a single configuration changed event naming the flags that changed, so
the UI rebuilds from the new values.

- **The initial features are never held back.** The mode takes effect only
  once the first features (or a failure) have arrived, so it can be set at
  creation and the app still starts with real values. Features loaded from a
  store don't count: FeatureHub's first features replace them as usual.
- **Updates and full sets are held.** A held full set, for example after a
  reconnect, removes the features missing from it when it is released.
- **Deletions are not held**: a deleted feature goes at once, and a held
  update for it is dropped, so a release cannot bring it back.
- **Readiness is not held**: after a reconnect the provider is ready again,
  even while the new features wait for release.
- **Turning the mode off** (`provider.catchAndReleaseMode = false`) releases
  whatever is held, then stops holding updates back.

## Options

| Option | Default | |
|---|---|---|
| `mode` | `streaming` (with a host and a client-evaluated API key), `activePolling` (with a `featuresUrl`); a server-evaluated key (without `*`) has no default, so `mode` must be given (an `ArgumentError` otherwise) | `streaming` (FeatureHub only), `activePolling` (every `pollInterval`) or `passivePolling` (a resolution refreshes in the background once the features are older than `pollInterval`) |
| `pollInterval` | 30s | 0 polls once, at start-up, and never again (a context change still fetches); anything else must be at least 5 seconds (an `ArgumentError`), and a FeatureHub `Cache-Control: max-age` below that is raised to it |
| `waitForReady` | 10s | how long initialization and a context change wait for features |
| `reconnectPolicy` | `defaultReconnectPolicy`: 3s after a network error, 30s after a 5xx (or an invalid 1xx or 3xx), doubling with each consecutive failure up to 5 minutes; a 200 that is not an event stream (e.g. a proxy's HTML page) is retried as a network error; every wait is at least 100ms, and a server's `retry:` at least 1s; consecutive failures are counted until FeatureHub sends an event, not just until a connection opens, so a server that drops every connection still backs off and uses up `maxAttempts`; a 4xx, 429 included, stops for good. Any stop for good (also an unretried status, or running out of `maxAttempts`) is a failure: before any features the provider fails to initialize, after them it goes `stale` | streaming reconnection on Android and iOS; set any value with your own `ReconnectPolicy(delay:, serverErrorDelay:, backoffMultiplier:, maxDelay:, maxAttempts:)`. In browsers the native `EventSource` reconnects after a dropped connection, but a connection error (the browser giving up, which hides whether it was a 4xx or 5xx) stops streaming for good: before any features the provider fails to initialize, after them it goes `stale` |
| `connectTimeout` | none | how long establishing an HTTP connection may take (in browsers, polling only: the browser controls `EventSource` connections) |
| `stores` | none | stores that keep a copy of the features, attached before connecting (see `FeatureStore`): e.g. `featurehub_openfeatures_store_localstorage`, to start web applications with the features they last had |
| `interceptors` | none | value interceptors that supply feature values in place of FeatureHub's (see `ValueInterceptor`), overriding locked features too: e.g. `LocalYamlValueInterceptor` from `featurehub_openfeatures_yaml_interceptor`, for local overrides during development |
| `catchAndReleaseMode` | false | hold feature updates back until `release()` is called; takes effect once the initial features have arrived, so it can be set at creation. Released changes are announced as configuration changed events (see [Catch and release](#catch-and-release)) |
| `requestTimeout` | none | how long a polling request may take, or how long a streaming connection attempt waits for the stream to open (an attempt that times out is retried under `reconnectPolicy`) |
| `headers` | none | sent with every request: FeatureHub polling and streaming (not in browsers, whose `EventSource` cannot send headers) and `featuresUrl`; for a gateway, extra authentication or tracing |
| `dio` | created | the `Dio` for polling, e.g. one configured with a proxy |
| `httpClient` | created | the `http.Client` for streaming on Android and iOS, e.g. one configured with a proxy |
| `transportFactory` | none | your own transport (WebSockets, another SSE client, ...) in place of the built-in ones |
| `featuresUrl`, `sendContext` | none, true | poll your own server instead of FeatureHub (see above) |

See the common package's README for
[headers and proxies](../featurehub-openfeatures-common/README.md#headers-and-proxies)
and [writing your own transport](../featurehub-openfeatures-common/README.md#writing-your-own-transport).

## Web

Browsers need FeatureHub Edge to allow cross-origin requests from the
application (CORS), including the `x-featurehub` header when polling with a
server-evaluated key.
