import 'featurehub.dart';
import 'featurehub_config.dart';

/// will be deprecated, please use FeatureHubConfig instead
class FeatureHubSimpleApi extends FeatureHubConfig {
  FeatureHubSimpleApi(String host, List<String> apiKeys, ClientFeatureRepository repository) : super(host, apiKeys, repository);
}
