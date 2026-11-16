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
which evaluates features for the user in each request.

## Configuration from the environment

Anything not passed to `FeatureHubProvider` is read from the environment:

| Variable | Used for |
|---|---|
| `FEATUREHUB_EDGE_URL` | `host`, the FeatureHub Edge URL |
| `FEATUREHUB_CLIENT_API_KEY` | `apiKey`: a client-evaluated key (preferred if both keys are set) |
| `FEATUREHUB_SERVER_API_KEY` | `apiKey`: a server-evaluated key, used if `FEATUREHUB_CLIENT_API_KEY` is not set |
| `FEATUREHUB_POLL_INTERVAL` | `pollInterval`, in seconds: if set, the provider polls at this interval instead of streaming |

Arguments take precedence over the environment. The constructor throws an
`ArgumentError` if there is no host or API key, or if
`FEATUREHUB_POLL_INTERVAL` is not a positive number of seconds.

## API keys

- **Client-evaluated keys** (containing `*`) are recommended for servers.
  FeatureHub sends every feature's rollout strategies, and each resolution is
  evaluated locally against its own evaluation context, so concurrent
  requests for different users are independent.
- **Server-evaluated keys** make FeatureHub Edge evaluate the bundle for a
  single context. When a resolution's context differs from the current one,
  the bundle is fetched again for it, and resolutions are serialised so that
  none sees another context's bundle. Use a client-evaluated key for
  multi-user workloads.

## Evaluation context

The OpenFeature `targetingKey` is FeatureHub's `userkey`, the default key for
percentage rollouts (a `session` attribute takes precedence). FeatureHub's
well-known attributes (`country`, `device`, `platform`, `version`, `email`,
`session`) are recognised case-insensitively; anything else is a custom
attribute. Values may be strings, numbers, booleans, `DateTime`s or lists of
those; anything else resolves with `INVALID_CONTEXT`.

## Resolution

| Situation | Value | Reason | Error code |
|---|---|---|---|
| A rollout strategy matched | the strategy's value | `TARGETING_MATCH` (variant: the strategy id) | |
| Otherwise | the feature's value | `STATIC` | |
| The feature has no value | the default | `DEFAULT` | |
| Unknown flag | the default | `ERROR` | `FLAG_NOT_FOUND` |
| Wrong type (e.g. a string flag as boolean, 1.5 as integer) | the default | `ERROR` | `TYPE_MISMATCH` |
| Invalid JSON for an object flag | the default | `ERROR` | `PARSE_ERROR` |
| Before initialization | the default | `ERROR` | `PROVIDER_NOT_READY` |

Flag metadata carries `featureVersion` and `featureType`.

## Options

| Option | Default | |
|---|---|---|
| `host` | `FEATUREHUB_EDGE_URL` | |
| `apiKey` | `FEATUREHUB_CLIENT_API_KEY`, then `FEATUREHUB_SERVER_API_KEY` | |
| `mode` | `polling` if there is a poll interval, otherwise `streaming` | `streaming`, `polling` (every `pollInterval`) or `passive` (fetch on resolution once older than `pollInterval`) |
| `pollInterval` | `FEATUREHUB_POLL_INTERVAL` (seconds), otherwise none | required for `polling` and `passive` |
| `waitForReady` | 10s | how long initialization, and a server-evaluated context change, wait for features |
| `reconnectPolicy` | 3s, 30s after a 5xx, stop on a 4xx | streaming reconnection, see `featurehub_sse_client` |
| `connectTimeout` | none | how long establishing an HTTP connection may take |
| `catchAndReleaseMode` | false | hold feature updates back until `release()` is called; takes effect once the initial features have arrived, so it can be set at creation. Released changes are announced as configuration changed events |
| `requestTimeout` | none | how long a polling request may take, or how long a streaming connection attempt waits for the stream to open (an attempt that times out is retried under `reconnectPolicy`) |

## Events

`PROVIDER_READY` once features have arrived, `PROVIDER_CONFIGURATION_CHANGED`
(with the changed flag keys) when features change, `PROVIDER_STALE` when the
connection is lost (and `PROVIDER_READY` once it recovers), and
`PROVIDER_ERROR` (`PROVIDER_FATAL`) if FeatureHub rejects the API key.
