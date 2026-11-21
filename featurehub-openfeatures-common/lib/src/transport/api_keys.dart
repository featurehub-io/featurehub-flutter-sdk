/// True if [apiKeys] are client-evaluated FeatureHub API keys (they contain
/// `*`): FeatureHub then sends every feature's rollout strategies, which are
/// evaluated locally, and the context is never sent. Throws an
/// [ArgumentError] if client- and server-evaluated keys are mixed.
bool isClientEvaluatedKeys(List<String> apiKeys) {
  final clientEvaluated = apiKeys.where((key) => key.contains('*')).length;
  if (clientEvaluated != 0 && clientEvaluated != apiKeys.length) {
    throw ArgumentError.value(
      apiKeys,
      'apiKeys',
      'Client-evaluated (containing *) and server-evaluated API keys cannot be mixed',
    );
  }
  return clientEvaluated != 0;
}
