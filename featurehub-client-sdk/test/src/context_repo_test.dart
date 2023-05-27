

import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_client_sdk/featurehub.dart';
import 'package:featurehub_client_sdk/src/internal_context.dart';
import 'package:featurehub_client_sdk/src/repository.dart';
import 'package:test/test.dart';

// we use this one because the features are created with the context, which is what we want to test works
class _ProperContext extends InternalContext {
  _ProperContext(super.repo);

  @override
  FeatureStateHolder feature(String key) => repo.feat(key).withContext(this);

  @override
  Future<void> used(String key, String id, val, FeatureValueType valueType) async {
  }
}

main() {
  group("repo features and context features should be the same", () {
    late ClientFeatureRepository repo;
    late _ProperContext ctx;

    setUp(() {
      repo = ClientFeatureRepository();
      ctx = _ProperContext(repo);
    });

    test("bool", () {
      final f = FeatureState(key: 'x', id: '1', version: 1, type: FeatureValueType.BOOLEAN, value: true);
      repo.updateFeatures([f]);
      final rf = repo.feature('x');
      final cf = ctx.feature('x');
      expect(rf.flag, isTrue);
      expect(cf.flag, isTrue);
      expect(rf.enabled, isTrue);
      expect(cf.enabled, isTrue);
      expect(rf.version, 1);
      expect(cf.version, 1);
      expect(rf.locked, isFalse);
      expect(cf.locked, isFalse);
      f.l = true;
      expect(rf.locked, isTrue);
      expect(cf.locked, isTrue);
    });
  });
}