# Changelog

## 1.0.0

- First release: `LocalSessionStore`, browser storage for the FeatureHub
  OpenFeature client provider.
- With features from your own server, they are stored under its
  `featuresUrl`; with neither that nor FeatureHub, under
  `featurehub-features`.
- With a server-evaluated key (or a features server sent the context), each
  context's features are stored apart (the key ends `?contextSha=<sha>`),
  and a start loads only those of its own context.
