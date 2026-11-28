# Changelog

## 1.0.0

- First release: `RedisFeatureStore`, Redis storage for the FeatureHub
  OpenFeature server provider, compatible with the other FeatureHub SDKs.
- The SHA is computed by `ClientFeatureRepository.computeSha` in
  `featurehub_openfeatures_common`.
- Refuses to attach to a provider without an API key, since the Redis keys
  are named by the environment.
- Removes deleted features from Redis, even if another process wrote first,
  and features missing from a full set that the process last saw there
  (unlike the TypeScript store, which can keep them).
