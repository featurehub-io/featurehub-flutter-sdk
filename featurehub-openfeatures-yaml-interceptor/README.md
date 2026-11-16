# FeatureHub YAML interceptor

Feature values from a local YAML file for the FeatureHub OpenFeature
providers
([`featurehub_openfeatures_server_sdk`](../featurehub-openfeatures-server-sdk)
and, outside browsers,
[`featurehub_openfeatures_client_sdk`](../featurehub-openfeatures-client-sdk)),
for development and testing. It is the Dart equivalent of the TypeScript
SDK's `featurehub-yaml-interceptor` and reads the same files.

It is not meant for production: the file is read from the local file system
and is neither authenticated nor versioned by FeatureHub. It needs `dart:io`,
so it does not work in browsers.

## The YAML file

A single top-level `flagValues` map, from feature keys to values:

```yaml
# featurehub-features.yaml
flagValues:
  my-boolean-flag: true
  my-string-flag: "hello world"
  my-number-flag: 42
  my-json-flag:
    warehouse: east
    capacity: 500
  my-null-flag: ~
```

The file is, in order of precedence:

1. the `filename` given;
2. the file named by the `FEATUREHUB_LOCAL_YAML` environment variable;
3. `featurehub-features.yaml` in the current directory.

A missing or malformed file gives no values.

## `LocalYamlValueInterceptor`: override some features

Overrides the features listed in the file. Every other feature still comes
from FeatureHub.

```dart
await OpenFeatureAPI().setProviderAndWait(
  FeatureHubProvider(
    interceptors: [LocalYamlValueInterceptor()],
  ),
);
```

Each value is converted to the type of the feature it overrides:

| Feature type | YAML value gives |
|--------------|------------------|
| Boolean | `true` (also as a string, in any case) is true; anything else, including `~`, is false |
| Number | numbers, and numeric strings (`"99"`); anything else no value |
| String | strings, numbers and booleans as text; maps and lists no value |
| JSON | strings as they are; anything else as JSON |

For every type except boolean, `~` (null) means no value, so the flag
resolves to the default value in your code. The interceptor also overrides
locked features.

With `watchForChanges: true`, the file is checked every `pollInterval`
(500 ms by default) and reread when it changes, so you can edit the values
without restarting:

```dart
LocalYamlValueInterceptor(
  filename: 'config/local-flags.yaml',
  watchForChanges: true,
)
```

The provider closes its interceptors, which stops the watching, when it
shuts down. You can also call `close()` yourself, or `reload()` to reread the
file at any time.

The interceptor only overrides features that FeatureHub has delivered.
OpenFeature resolves a flag FeatureHub doesn't have as *flag not found*, even
if it is in the file. To add such features, use `LocalYamlFeatureStore`.

Without a provider, register the interceptor directly with
`repository.addValueInterceptor(...)`.

## `LocalYamlFeatureStore`: features without FeatureHub

Reads the file once and loads every entry into the repository as a feature.
This is useful for unit tests and for working offline.

```dart
final repository = ClientFeatureRepository();
LocalYamlFeatureStore().load(repository);

repository.feature('my-boolean-flag').booleanValue; // true
```

Each value becomes a feature of the type the value implies:

| YAML value | Feature type |
|------------|--------------|
| `true` / `false` (also as strings, in any case) | Boolean |
| integer or float | Number |
| any other string | String |
| map or list | JSON |
| `~` / `null` | String, with no value |

Each feature has version 1 and is unlocked. Its id is the first 8 hex digits
of the SHA-256 hash of its key, as in the TypeScript SDK, so ids stay the
same across runs.

It is also a `FeatureStore`. If you add it to a provider's `stores`, the
provider is ready with the file's features straight away. When FeatureHub's
features arrive, they replace the file's features.

## Which to use

| | `LocalYamlValueInterceptor` | `LocalYamlFeatureStore` |
|---|---|---|
| Overrides only the listed features | Yes: the others come from FeatureHub | No: it supplies all the features |
| Needs FeatureHub | Yes, for the other features | No |
| Rereads the file when it changes | Yes, with `watchForChanges: true` | No |
| Adds features FeatureHub doesn't have | No | Yes |
