

import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_client_sdk/featurehub.dart';
import 'package:featurehub_client_sdk/src/internal_repository.dart';
import 'package:meta/meta.dart';

import 'internal_features.dart';

@internal
abstract class InternalContext  extends ClientContext {
  InternalContext(InternalFeatureRepository repo) : super(repo);

  Future<void> used(String key, String id, dynamic val, FeatureValueType valueType);

  @protected
  recordFeatureChangedForUser(FeatureStateBaseHolder feature) {
    repo.recordAnalyticsEvent(AnalyticsFeature(FeatureHubAnalyticsValue(feature.withContext(this) as FeatureStateBaseHolder), attributes, analyticsUserKey()));
  }

  /// Call this method to rebuild Context
  Future<ClientContext> build() async {
    return this;
  }

  void close() {
  }
}
