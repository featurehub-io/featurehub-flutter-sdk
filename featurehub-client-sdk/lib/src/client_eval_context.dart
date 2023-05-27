

import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_client_sdk/featurehub.dart';
import 'package:featurehub_client_sdk/src/internal_context.dart';
import 'package:featurehub_client_sdk/src/internal_repository.dart';
import 'package:meta/meta.dart';
import 'log.dart';

@internal
class ClientEvalContext extends InternalContext {
  final EdgeService edgeService;

  ClientEvalContext(InternalFeatureRepository repo, this.edgeService) : super(repo);

  @override
  FeatureStateHolder feature(String key) => repo.feat(key);

  @override
  Future<ClientContext> build() async {
    log.fine('SSE: client eval context poll');
    await edgeService.poll();
    repo.recordAnalyticsEvent(
        repo.analyticsProvider.createAnalyticsContextCollectionEvent()
          ..attributes = attributes
          ..userKey=analyticsUserKey());
    return this;
  }

  @override
  Future<void> used(String key, String id, dynamic val, FeatureValueType valueType) async {
    await repo.used(key, id, val, valueType, attributes, analyticsUserKey());
    await edgeService.poll();
  }
}