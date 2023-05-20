

import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_client_sdk/src/internal/internal_context.dart';
import 'package:featurehub_client_sdk/src/internal/internal_repository.dart';
import 'package:meta/meta.dart';

import '../config.dart';
import '../features.dart';

@internal
class ClientEvalContext extends InternalContext {
  final EdgeService edgeService;

  ClientEvalContext(InternalFeatureRepository repo, this.edgeService) : super(repo);

  @override
  FeatureStateHolder feature(String key) => repo.feat(key);

  @override
  Future<void> build() async {
    await edgeService.poll();
  }

  @override
  Future<void> used(String key, String id, dynamic val, FeatureValueType valueType) async {
    await repo.used(key, id, val, valueType, attributes);
    await edgeService.poll();
  }
}