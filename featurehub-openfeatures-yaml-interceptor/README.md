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

## Usage

The package has two classes, which read the same file and are normally used
together:

- **`LocalYamlFeatureStore`** creates the features. When it is attached, it
  loads every entry in the file into the repository as a feature, with a type
  and a value. The provider is ready straight away, and every flag in the
  file exists and resolves.
- **`LocalYamlValueInterceptor`** supplies the values. When a flag is
  resolved, it gives the flag's value from the file, converted to the
  feature's type. With `watchForChanges: true` it rereads the file when it
  changes, so your edits take effect without a restart. It also overrides
  features that come from FeatureHub, including locked ones.

```dart
await OpenFeatureAPI().setProviderAndWait(
  FeatureHubProvider(
    stores: [LocalYamlFeatureStore()],
    interceptors: [LocalYamlValueInterceptor(watchForChanges: true)],
  ),
);

final client = OpenFeatureAPI().getClient('app');
await client.getBooleanFlag('my-boolean-flag', defaultValue: false); // true
```

Both classes find the file in the same way, so with no `filename` they read
the same file. If you give a `filename`, give it to both.

Together they work like this:

1. **On start**, the store loads the file's features, so every flag in the
   file exists and has a type.
2. **When a flag is resolved**, the interceptor supplies its value from the
   file, converted to the feature's type.
3. **When you edit a value**, the interceptor rereads the file, and the new
   value is used from the next resolution.
4. **When FeatureHub's features arrive** (if the provider can reach
   FeatureHub), they replace the store's features. The interceptor keeps
   overriding the flags in the file, and the other flags take their values
   from FeatureHub.

There are two things to know about how they fit together:

- **A key added to the file while running** gets a value from the
  interceptor, but no feature exists for it until the store loads the file
  again. Until then it resolves as *flag not found*. Restart, or call
  `store.load(repository)` again.
- **Types come from the features.** The interceptor converts each value to
  the type of the feature it overrides. That type comes from the file when
  the store loaded it, or from FeatureHub. If you edit a value so that it
  implies a different type, the feature keeps its type until it is loaded
  again.

The provider closes its interceptors when it shuts down, which stops the
watching. You can also call `close()` yourself, or `reload()` to reread the
file at any time.

### Without a provider

For unit tests, use the same two classes with a repository directly:

```dart
final repository = ClientFeatureRepository();
LocalYamlFeatureStore().load(repository);
repository.addValueInterceptor(LocalYamlValueInterceptor());

repository.feature('my-boolean-flag').booleanValue; // true
```

### Only one of them

Each class also works on its own:

- **The store alone** gives a fixed set of features, read once. This is
  enough for a test that doesn't change the file.
- **The interceptor alone** overrides features that FeatureHub delivers,
  leaving all the others as they are. It can't create features: a flag that
  FeatureHub doesn't have resolves as *flag not found*, even if it is in the
  file.

## Types

The store gives each feature the type its value implies:

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

The interceptor converts each value to the type of the feature it overrides:

| Feature type | YAML value gives |
|--------------|------------------|
| Boolean | `true` (also as a string, in any case) is true; anything else, including `~`, is false |
| Number | numbers, and numeric strings (`"99"`); anything else no value |
| String | strings, numbers and booleans as text; maps and lists no value |
| JSON | strings as they are; anything else as JSON |

For every type except boolean, `~` (null) means no value, so the flag
resolves to the default value in your code.
