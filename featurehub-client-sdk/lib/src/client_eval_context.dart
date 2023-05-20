

import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_client_sdk/featurehub.dart';
import 'package:featurehub_client_sdk/src/internal_context.dart';
import 'package:featurehub_client_sdk/src/internal_repository.dart';
import 'package:meta/meta.dart';

@internal
class ClientEvalContext extends InternalContext {
  final EdgeService edgeService;

  ClientEvalContext(InternalFeatureRepository repo, this.edgeService) : super(repo);

  @override
  FeatureStateHolder feature(String key) => repo.feat(key);

  @override
  Future<ClientContext> build() async {
    await edgeService.poll();
    return this;
  }

  @override
  Future<void> used(String key, String id, dynamic val, FeatureValueType valueType) async {
    await repo.used(key, id, val, valueType, attributes);
    await edgeService.poll();
  }
}