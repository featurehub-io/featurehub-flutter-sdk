import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_openfeatures_common/featurehub.dart';
import 'package:test/test.dart';

FeatureState _f(String id, int version, {String? key, bool value = true}) =>
    FeatureState(
      id: id,
      key: key ?? 'key-$id',
      version: version,
      type: FeatureValueType.BOOLEAN,
      value: value,
    );

String _sha(List<FeatureState> features) =>
    ClientFeatureRepository.computeSha(features);

void main() {
  test('computeSha matches the other SDKs', () {
    // computed by the TypeScript SDK
    expect(
      _sha([
        _f('f3c1a2b4-1d2e-4c5b-9a8b-7c6d5e4f3a2b', 3),
        _f('0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d', 12),
        _f('a0000000-0000-4000-8000-000000000000', 1),
      ]),
      'ffef4b48076b58be67b0abe8baa76b13915242208613701a2d3a8328e3eb4ef1',
    );
    expect(
      _sha([]),
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    );
  });

  group('the repository', () {
    late ClientFeatureRepository repo;

    setUp(() => repo = ClientFeatureRepository());
    tearDown(() => repo.shutdown());

    test('starts with the SHA of no features', () {
      expect(repo.featuresSha, _sha([]));
    });

    test('computes the SHA on every change', () {
      repo.notify(SSEResultState.features, <FeatureState>[]);
      expect(repo.featuresSha, _sha([]));

      repo.notify(SSEResultState.features, [_f('a', 1), _f('b', 1)]);
      expect(repo.featuresSha, _sha([_f('a', 1), _f('b', 1)]));

      repo.notify(SSEResultState.feature, _f('b', 2, value: false));
      expect(repo.featuresSha, _sha([_f('a', 1), _f('b', 2)]));

      repo.notify(SSEResultState.deleteFeature, _f('a', 1));
      expect(repo.featuresSha, _sha([_f('b', 2)]));

      // a full set removes the missing features
      repo.notify(SSEResultState.features, [_f('c', 1)]);
      expect(repo.featuresSha, _sha([_f('c', 1)]));

      // a store's features count too
      repo.notify(SSEResultState.features, [_f('d', 1)], source: 'a-store');
      expect(repo.featuresSha, _sha([_f('d', 1)]));

      repo.shutdownFeatures();
      expect(repo.featuresSha, _sha([]));
    });

    test('in catch and release mode, changes with the release', () async {
      repo.catchAndReleaseMode = true;
      repo.notify(SSEResultState.features, [_f('a', 1)]);
      final before = repo.featuresSha;
      expect(before, _sha([_f('a', 1)]));

      repo.notify(SSEResultState.feature, _f('a', 2, value: false));
      repo.notify(SSEResultState.features, [_f('a', 2), _f('b', 1)]);
      expect(repo.featuresSha, before);

      await repo.release();
      expect(repo.featuresSha, _sha([_f('a', 2), _f('b', 1)]));
    });
  });
}
