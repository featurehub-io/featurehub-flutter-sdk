# FeatureHub browser storage

Browser storage for the FeatureHub OpenFeature client provider
([`featurehub_openfeatures_client_sdk`](../featurehub-openfeatures-client-sdk)),
for web applications.

Without it, a web application waits for FeatureHub to deliver the features on
every page load. `LocalSessionStore` keeps the features in the browser's
`sessionStorage` (or `localStorage`) and loads them as soon as the provider
starts, before the connection to FeatureHub is made. It is the Dart
equivalent of the TypeScript SDK's `featurehub-store-localstorage`, and
stores the same data in the same format.

## Usage

```dart
await OpenFeatureAPI.instance.setProviderAndWait(
  FeatureHubProvider(
    host: 'https://edge.example.com',
    apiKey: apiKey,
    stores: [LocalSessionStore()],
  ),
);
```

- `LocalSessionStore()` uses `sessionStorage`: the features are kept for the
  browser tab and discarded when it closes. This is the safest default.
- `LocalSessionStore.localStorage()` keeps them across tabs and browser
  restarts.
- `LocalSessionStore(storage: ...)` takes any `FeatureStorage`.

## How it works

- **On start**, the features stored for the environment (keyed by its
  feature URL, `<host>/features/<api key>`) are loaded into the provider, so
  flags resolve straight away and the provider is ready immediately.
- **While running**, every update from FeatureHub is written to storage:
  a full set replaces the stored features, a single feature is added or
  replaced, and a deleted feature is removed. 
- Malformed stored data is ignored, and if storage is unavailable or full the
  application keeps working without it.

With a server-evaluated API key, the stored features are those FeatureHub
evaluated for the context at the time. Until FeatureHub answers, a later
start with a different context begins with them.

This package only works in browsers.
