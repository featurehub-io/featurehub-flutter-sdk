

import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_client_sdk/src/internal/internal_context.dart';
import 'package:featurehub_client_sdk/src/internal/internal_repository.dart';
import 'package:meta/meta.dart';

import '../features.dart';

@internal
class ClientEvalContext extends InternalContext {
  ClientEvalContext(InternalFeatureRepository repo) : super(repo);

  @override
  FeatureStateHolder feature(String key) => repo.feat(key);

  @override
  used(String key, String id, val, FeatureValueType valueType) {
    // TODO: implement used
    throw UnimplementedError();
  }
}