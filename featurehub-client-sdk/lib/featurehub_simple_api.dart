import 'featurehub.dart';
import 'featurehub_config.dart';

/// will be deprecated, please use FeatureHubConfig instead
class FeatureHubSimpleApi extends FeatureHubConfig {
  FeatureHubSimpleApi(super.host, super.apiKeys, super.repository);
}
