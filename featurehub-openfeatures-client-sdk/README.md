# FeatureHub OpenFeature provider for Flutter and the web

The [FeatureHub](https://www.featurehub.io) provider for the
[OpenFeature Dart client SDK](https://pub.dev/packages/openfeature_dart_client_sdk),
for Flutter (Android, iOS) and browser applications. For servers and command
line applications use
[`featurehub_openfeatures_server_sdk`](../featurehub-openfeatures-server-sdk).

The provider keeps the whole feature bundle of a FeatureHub environment in a
local repository and resolves every flag synchronously from it. It is kept up
to date by streaming (the browser's native `EventSource` on the web,
`featurehub_sse_client` elsewhere), polling or passive refresh.

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
- **Client-evaluated keys** (containing `*`) deliver every feature's rollout
  strategies, which are evaluated locally, so a context change needs no
  network request.

## Evaluation context, resolution and events

These are the same as for the server provider: see its
[README](../featurehub-openfeatures-server-sdk/README.md#evaluation-context).
Events are `ready`, `configurationChanged` (with the changed flag keys),
`stale` (and `ready` once the connection recovers), `reconciling` and
`contextChanged`, and `error` (`providerFatal`) if FeatureHub rejects the key.

## Options

| Option | Default | |
|---|---|---|
| `mode` | `streaming` | `streaming`, `polling` (every `pollInterval`) or `passive` (a resolution refreshes in the background once the features are older than `pollInterval`) |
| `pollInterval` | 30s | |
| `waitForReady` | 10s | how long initialization and a context change wait for features |
| `reconnectPolicy` | 3s, 30s after a 5xx, stop on a 4xx | streaming reconnection (in browsers the native `EventSource` reconnects; if it gives up, the provider retries after `serverErrorDelay`) |
| `connectTimeout` | none | how long establishing an HTTP connection may take (in browsers, polling only: the browser controls `EventSource` connections) |
| `stores` | none | stores that keep a copy of the features, attached before connecting (see `FeatureStore`): e.g. `featurehub_openfeatures_store_localstorage`, to start web applications with the features they last had |
| `interceptors` | none | value interceptors that supply feature values in place of FeatureHub's (see `ValueInterceptor`), overriding locked features too: e.g. `LocalYamlValueInterceptor` from `featurehub_openfeatures_yaml_interceptor`, for local overrides during development |
| `catchAndReleaseMode` | false | hold feature updates back until `release()` is called; takes effect once the initial features have arrived, so it can be set at creation. Released changes are announced as configuration changed events |
| `requestTimeout` | none | how long a polling request may take, or how long a streaming connection attempt waits for the stream to open (an attempt that times out is retried under `reconnectPolicy`) |

## Web

Browsers need FeatureHub Edge to allow cross-origin requests from the
application (CORS), including the `x-featurehub` header when polling with a
server-evaluated key.
