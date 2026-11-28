import 'dart:async';
import 'dart:convert';

import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_openfeatures_common/featurehub_openfeatures_common.dart';
import 'package:featurehub_openfeatures_store_redis/featurehub_openfeatures_store_redis.dart';
import 'package:test/test.dart';

/// An in-memory Redis with WATCH semantics.
class FakeRedis implements RedisCommands {
  final data = <String, String>{};
  final _versions = <String, int>{};
  var _clock = 0;
  String? _watched;
  int? _watchedVersion;
  var setAllCalls = 0;
  var closed = false;

  /// Called between WATCH and EXEC, e.g. to simulate another writer.
  void Function()? beforeExec;

  @override
  Future<String?> get(String key) async => data[key];

  @override
  Future<void> set(String key, String value) async {
    data[key] = value;
    _versions[key] = ++_clock;
  }

  @override
  Future<void> watch(String key) async {
    _watched = key;
    _watchedVersion = _versions[key];
  }

  @override
  Future<void> unwatch() async => _watched = null;

  @override
  Future<bool> setAll(Map<String, String> values) async {
    setAllCalls++;
    beforeExec?.call();
    final watched = _watched;
    _watched = null;
    if (watched != null && _versions[watched] != _watchedVersion) {
      return false;
    }
    for (final e in values.entries) {
      await set(e.key, e.value);
    }
    return true;
  }

  @override
  Future<void> close() async => closed = true;
}

FeatureState _feature(String id, int version, {String? value, String? key}) =>
    FeatureState(
      id: id,
      key: key ?? 'key-$id',
      version: version,
      type: FeatureValueType.STRING,
      value: value ?? '$id-v$version',
    );

const _apiKey = 'default/env-1/key*secret';
const _featuresKey = 'featurehub_env-1';
const _shaKey = 'featurehub_env-1_sha';

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  late FakeRedis redis;
  late ClientFeatureRepository repo;
  late RedisFeatureStore store;

  FeatureStoreTarget target([String apiKey = _apiKey]) =>
      FeatureStoreTarget(repository: repo, host: 'http://edge', apiKey: apiKey);

  /// Writes features to Redis as another process would.
  void external(List<FeatureState> features) {
    redis.set(
      _featuresKey,
      jsonEncode(features.map((f) => f.toJson()).toList()),
    );
    redis.set(_shaKey, ClientFeatureRepository.computeSha(features));
  }

  List<FeatureState> stored() =>
      FeatureState.listFromJson(jsonDecode(redis.data[_featuresKey]!));

  setUp(() {
    redis = FakeRedis();
    repo = ClientFeatureRepository();
    store = RedisFeatureStore(
      redis,
      backoff: const Duration(milliseconds: 1),
      retryUpdateCount: 3,
    );
  });

  tearDown(() async {
    await store.close();
    repo.shutdown();
  });

  group('the SHA', () {
    // computed by the TypeScript SDK's store
    test('matches the other SDKs', () {
      expect(
        ClientFeatureRepository.computeSha([
          FeatureState(
            id: 'f3c1a2b4-1d2e-4c5b-9a8b-7c6d5e4f3a2b',
            key: 'a',
            version: 3,
            type: FeatureValueType.BOOLEAN,
          ),
          FeatureState(
            id: '0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d',
            key: 'b',
            version: 12,
            type: FeatureValueType.BOOLEAN,
          ),
          FeatureState(
            id: 'a0000000-0000-4000-8000-000000000000',
            key: 'c',
            version: 1,
            type: FeatureValueType.BOOLEAN,
          ),
        ]),
        'ffef4b48076b58be67b0abe8baa76b13915242208613701a2d3a8328e3eb4ef1',
      );
      expect(
        ClientFeatureRepository.computeSha([
          FeatureState(
            id: 'only',
            key: 'o',
            version: 0,
            type: FeatureValueType.BOOLEAN,
          ),
        ]),
        '03a55f20ac287349c236160cf813e321e0084e7c2cdef7cabf43374a85a971a8',
      );
      expect(
        ClientFeatureRepository.computeSha([]),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
    });
  });

  group('attaching', () {
    test('is connected afterwards', () async {
      expect(store.connected, false);
      await store.attach(target());
      expect(store.connected, true);
    });

    test('refuses server-evaluated keys', () async {
      await store.attach(target('default/env-1/server-key'));
      expect(store.connected, false);
      repo.notify(SSEResultState.features, [_feature('a', 1)]);
      await _settle();
      expect(redis.data, isEmpty);
    });

    test('does nothing when Redis is empty', () async {
      await store.attach(target());
      expect(repo.readyness, Readyness.NotReady);
    });

    test('loads the stored features into the repository', () async {
      external([_feature('a', 2, value: 'stored')]);
      await store.attach(target());
      expect(repo.readyness, Readyness.Ready);
      expect(repo.evaluate('key-a').value, 'stored');
      await _settle();
      expect(redis.setAllCalls, 0, reason: 'its own features are not written');
    });
  });

  group('a full set of features', () {
    setUp(() => store.attach(target()));

    test('is written with its SHA', () async {
      repo.notify(SSEResultState.features, [
        _feature('a', 1),
        _feature('b', 1),
      ]);
      await _settle();
      expect(stored().map((f) => f.id), unorderedEquals(['a', 'b']));
      expect(redis.data[_shaKey], ClientFeatureRepository.computeSha(stored()));
    });

    test('is not written when Redis already has it', () async {
      external([_feature('a', 1)]);
      repo.notify(SSEResultState.features, [_feature('a', 1)]);
      await _settle();
      expect(redis.setAllCalls, 0);
    });

    test('is not written when Redis has newer features', () async {
      external([_feature('a', 5)]);
      repo.notify(SSEResultState.features, [_feature('a', 4)]);
      await _settle();
      expect(stored().single.version, 5);
      expect(redis.setAllCalls, 0);
    });

    test('is merged with features another process wrote', () async {
      external([_feature('a', 5), _feature('b', 1)]);
      repo.notify(SSEResultState.features, [
        _feature('a', 4),
        _feature('b', 2),
      ]);
      await _settle();
      final versions = {for (final f in stored()) f.id: f.version};
      expect(versions, {'a': 5, 'b': 2});
    });

    test('missing a feature removes it, though no version changed', () async {
      repo.notify(SSEResultState.features, [
        _feature('a', 1),
        _feature('b', 1),
      ]);
      await _settle();
      repo.notify(SSEResultState.features, [_feature('b', 1)]);
      await _settle();
      expect(stored().map((f) => f.id), ['b']);
      expect(redis.data[_shaKey], ClientFeatureRepository.computeSha(stored()));
    });

    test('missing one another process added since keeps it', () async {
      repo.notify(SSEResultState.features, [_feature('a', 1)]);
      await _settle();
      // a newer process wrote a feature this one has not heard of yet
      external([_feature('a', 1), _feature('kwong', 1)]);
      repo.notify(SSEResultState.features, [_feature('a', 2)]);
      await _settle();
      final versions = {for (final f in stored()) f.id: f.version};
      expect(versions, {'a': 2, 'kwong': 1});
    });

    test('is retried when another process writes during the write', () async {
      var interrupted = false;
      redis.beforeExec = () {
        if (!interrupted) {
          interrupted = true;
          external([_feature('c', 1)]);
        }
      };
      repo.notify(SSEResultState.features, [_feature('a', 1)]);
      await _settle();
      expect(redis.setAllCalls, 2);
      expect(stored().map((f) => f.id), unorderedEquals(['a', 'c']));
    });

    test('gives up after retryUpdateCount attempts', () async {
      var n = 0;
      redis.beforeExec = () => external([_feature('other', ++n)]);
      repo.notify(SSEResultState.features, [_feature('a', 1)]);
      await _settle();
      expect(redis.setAllCalls, 3);
      expect(stored().map((f) => f.id), ['other']);
    });

    test('its own updates are ignored', () async {
      repo.notify(SSEResultState.features, [
        _feature('a', 1),
      ], source: redisStoreSource);
      await _settle();
      expect(redis.data, isEmpty);
    });
  });

  group('a single feature', () {
    setUp(() => store.attach(target()));

    test('is added', () async {
      external([_feature('a', 1)]);
      repo.notify(SSEResultState.feature, _feature('b', 1));
      await _settle();
      expect(stored().map((f) => f.id), unorderedEquals(['a', 'b']));
    });

    test('replaces an older version', () async {
      external([_feature('a', 1)]);
      repo.notify(SSEResultState.feature, _feature('a', 2));
      await _settle();
      expect(stored().single.version, 2);
    });

    test('does not replace the same or a newer version', () async {
      external([_feature('a', 3)]);
      repo.notify(SSEResultState.feature, _feature('a', 3));
      repo.notify(SSEResultState.feature, _feature('a', 2));
      await _settle();
      expect(stored().single.version, 3);
      expect(redis.setAllCalls, 0);
    });

    test('is written when Redis is empty', () async {
      repo.notify(SSEResultState.feature, _feature('a', 1));
      await _settle();
      expect(stored().single.id, 'a');
    });
  });

  group('a deleted feature', () {
    setUp(() => store.attach(target()));

    test('is removed', () async {
      external([_feature('a', 1), _feature('b', 1)]);
      await store.refresh(); // the store has seen Redis's features
      repo.notify(SSEResultState.deleteFeature, _feature('a', 1));
      await _settle();
      expect(stored().map((f) => f.id), ['b']);
    });

    test('is removed even if another process wrote first', () async {
      // the deletion comes from FeatureHub: it holds whatever else was
      // written
      external([_feature('a', 1), _feature('b', 1)]);
      repo.notify(SSEResultState.deleteFeature, _feature('a', 1));
      await _settle();
      expect(stored().map((f) => f.id), ['b']);
    });

    test('leaves a feature made again with the same key', () async {
      external([_feature('juad', 1, key: 'chago')]);
      await store.refresh();
      external([_feature('tofu', 1, key: 'chago')]);
      repo.notify(
        SSEResultState.deleteFeature,
        _feature('juad', 1, key: 'chago'),
      );
      await _settle();
      expect(stored().map((f) => f.id), ['tofu']);
    });

    test('that is not stored changes nothing', () async {
      external([_feature('a', 1)]);
      repo.notify(SSEResultState.deleteFeature, _feature('x', 1));
      await _settle();
      expect(redis.setAllCalls, 0);
    });
  });

  group('refreshing', () {
    test('loads features another process wrote', () async {
      await store.attach(target());
      external([_feature('a', 9, value: 'from elsewhere')]);
      await store.refresh();
      expect(repo.evaluate('key-a').value, 'from elsewhere');
    });

    test('does nothing when Redis has not changed', () async {
      external([_feature('a', 1)]);
      await store.attach(target());
      final updates = <RawFeatureUpdate>[];
      final sub = repo.rawFeatureUpdates.listen(updates.add);
      await store.refresh();
      await _settle();
      expect(updates, isEmpty);
      await sub.cancel();
    });

    test('happens every refreshInterval', () async {
      final timed = RedisFeatureStore(
        redis,
        refreshInterval: const Duration(milliseconds: 20),
      );
      await timed.attach(target());
      external([_feature('a', 1, value: 'timed')]);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(repo.evaluate('key-a').value, 'timed');
      await timed.close();
    });
  });

  test('closing stops following updates and closes Redis', () async {
    await store.attach(target());
    await store.close();
    expect(store.connected, false);
    expect(redis.closed, true);
    repo.notify(SSEResultState.features, [_feature('a', 1)]);
    await _settle();
    expect(redis.data, isEmpty);
  });
}
