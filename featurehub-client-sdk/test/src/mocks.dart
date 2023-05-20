

import 'package:featurehub_client_sdk/featurehub.dart';
import 'package:featurehub_client_sdk/src/internal/internal_features.dart';
import 'package:featurehub_client_sdk/src/internal/internal_repository.dart';
import 'package:mocktail/mocktail.dart';

class MockFeatureStateBaseHolder extends Mock implements FeatureStateBaseHolder {

}

class MockInternalFeatureRepository extends Mock implements InternalFeatureRepository {
  MockFeatureStateBaseHolder fe = MockFeatureStateBaseHolder();
  Readiness r = Readiness.NotReady;

  Readiness get readiness => r;

  @override
  FeatureStateHolder feature(String key) {
    return feat(key);
  }

  feat(String key) {
    when(() => fe.key).thenReturn(key);
    return fe;
  }
}