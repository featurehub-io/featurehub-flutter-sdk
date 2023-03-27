

import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_client_sdk/featurehub.dart';
import 'package:featurehub_client_sdk/src/internal/internal_repository.dart';
import 'package:meta/meta.dart';

@internal
abstract class InternalContext  extends ClientContext {
  InternalContext(InternalFeatureRepository repo) : super(repo);

  Future<void> used(String key, String id, dynamic val, FeatureValueType valueType);
}
