import 'featurehub.dart';

/// will be deprecated, please use FeatureHubRestClient instead
class FeatureHubSimpleApi extends FeatureHubRestClient {
  FeatureHubSimpleApi(super.host, super.apiKeys, super.repository);
}
