# FeatureHub Redis store

Redis storage for the FeatureHub OpenFeature server provider
([`featurehub_openfeatures_server_sdk`](../featurehub-openfeatures-server-sdk)),
built on the [`redis`](https://pub.dev/packages/redis) package. It is the Dart
equivalent of the TypeScript SDK's `featurehub-store-redis`.

In a deployment with several instances (containers, serverless functions,
horizontally scaled services), each instance normally keeps its own copy of
the features. With `RedisFeatureStore` they share one copy in Redis:

- updates from FeatureHub reach every instance soon after any one of them
  receives them;
- a new instance starts with the stored features;
- while Redis is available, instances keep receiving updates even if their
  own connection to FeatureHub fails.

The keys and data are the same as every other FeatureHub SDK's Redis store,
so services written in different languages can share them.

## Usage

```dart
final store = await RedisFeatureStore.fromUrl('redis://localhost:6379');

await OpenFeatureAPI().setProviderAndWait(
  FeatureHubProvider(stores: [store]),
);
```

Connect with `RedisFeatureStore.fromUrl`
(`redis://[[username]:password@]host[:port][/database]`, or `rediss://` for
TLS), `RedisFeatureStore.connect(host:, port:, secure:, username:,
password:, database:)`, or give `RedisFeatureStore` your own
`RedisCommands`. The store closes its connection when the provider shuts
down.

**Only client-evaluated API keys** are supported: features FeatureHub has
evaluated for one context must not be shared with others, so with a
server-evaluated key the store logs an error and does nothing. Redis
Cluster is not supported, as the `redis` package has no cluster client.

## Options

| Option | Default | |
|---|---|---|
| `prefix` | `featurehub` | prefix of the Redis keys |
| `backoff` | 500ms | wait before retrying a write another process interrupted |
| `retryUpdateCount` | 10 | attempts before a write is abandoned |
| `refreshInterval` | 5 minutes | how often to check Redis for features other processes wrote (`refresh()` checks at once) |

## How it works

Features are stored as a JSON array under `<prefix>_<environment id>`, with
a SHA-256 of their sorted `id:version`s under `<prefix>_<environment id>_sha`.

- **On start** the stored features, if any, are loaded into the provider.
- **On an update from FeatureHub** the store writes it, unless Redis already
  has it or has newer versions. Writes use optimistic locking
  (`WATCH`/`MULTI`/`EXEC`): if another process wrote first, the two sets are
  merged so that a newer version of a feature is never replaced by an older
  one, and the write is retried.
- **Every `refreshInterval`** the store compares the SHA with the one it last
  saw, and loads the features if another process has changed them.

As in the TypeScript store, a deletion is skipped if another process has
written since this one last read Redis; the other processes receive the same
deletion from FeatureHub.

## Testing

The tests use an in-memory Redis. To also run them against a real Redis:

```
docker run -d --rm -p 16379:6379 redis:7.2-alpine
FEATUREHUB_TEST_REDIS=localhost:16379 dart test
```
