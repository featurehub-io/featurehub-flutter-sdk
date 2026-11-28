// conformance: feature-snapshot-protocol.yaml 2.0.0 (encoding.snapshot_sha,
// encoding.etag, encoding.clock_boundaries, server.snapshot_store,
// server.snapshot_api) and featurehub-protocol.yaml encoding.sha
import 'dart:convert';

import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_openfeatures_common/featurehub_openfeatures_common.dart'
    show ClientFeatureRepository, RawFeatureUpdate;
import 'package:featurehub_openfeatures_server_sdk/featurehub_openfeatures_server_sdk.dart';
import 'package:test/test.dart';

const _t = '2026-12-01T09:00:00Z';

FeatureRolloutStrategyAttribute _attr(
  String fieldName,
  RolloutStrategyFieldType type,
  RolloutStrategyAttributeConditional conditional,
  List<Object?> values,
) => FeatureRolloutStrategyAttribute(
  fieldName: fieldName,
  type: type,
  conditional: conditional,
  values: values,
);

FeatureState _f(
  String id,
  int version, {
  List<FeatureRolloutStrategy>? strategies,
  Object? value = 'chago',
}) => FeatureState(
  id: id,
  key: 'key-$id',
  version: version,
  type: FeatureValueType.STRING,
  value: value,
  strategies: strategies,
);

FeatureState _colour() => FeatureState(
  id: 'fv-colour',
  key: 'colour',
  version: 2,
  type: FeatureValueType.STRING,
  value: 'blue',
  fp: {'owner': 'ui'},
  environmentId: 'env',
  strategies: [
    FeatureRolloutStrategy(
      id: 'nz',
      value: 'green',
      attributes: [
        _attr(
          'country',
          RolloutStrategyFieldType.STRING,
          RolloutStrategyAttributeConditional.EQUALS,
          ['nz'],
        ),
      ],
    ),
  ],
);

FeatureState _flag() => FeatureState(
  id: 'fv-flag',
  key: 'flag',
  version: 3,
  type: FeatureValueType.BOOLEAN,
  value: true,
  environmentId: 'env',
);

Future<void> _pump() => Future<void>.delayed(Duration.zero);

/// A store attached to a repository holding [features].
Future<(ClientFeatureRepository, FeatureSnapshotStore)> _store(
  List<FeatureState> features, {
  String? apiKey,
}) async {
  final repository = ClientFeatureRepository()
    ..notify(SSEResultState.features, features);
  final store = FeatureSnapshotStore();
  await store.attach(
    FeatureStoreTarget(repository: repository, apiKey: apiKey),
  );
  return (repository, store);
}

void main() {
  test('featuresSha matches the other SDKs', () {
    // computed by the TypeScript SDK
    expect(
      featuresSha([
        _f('f3c1a2b4-1d2e-4c5b-9a8b-7c6d5e4f3a2b', 3),
        _f('0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d', 12),
        _f('a0000000-0000-4000-8000-000000000000', 1),
      ]),
      'ffef4b48076b58be67b0abe8baa76b13915242208613701a2d3a8328e3eb4ef1',
    );
    expect(
      featuresSha([]),
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    );
  });

  // encoding.snapshot_sha.test_vectors
  group('a snapshot sha', () {
    final two = [_f('f1', 2), _f('f2', 1)];
    final vectors = <(List<FeatureState>, Map<String, Object?>, bool, String)>[
      (
        two,
        {},
        true,
        '2eb34db18f7d62cee6c8dd3aa234034598a667982b8d9831bee7bba2c4c33852',
      ),
      (
        two,
        {},
        false,
        'e17b012d96433267fa3dc02316845226adbdb7d82bcb69f987617f178be3f482',
      ),
      (
        two,
        {'country': 'nz'},
        true,
        '5da6ce2616ad4cb03d94d3308a7557f2805d2de9624a63985ab267e449641876',
      ),
      (
        two,
        {'userkey': 'fred', 'country': 'nz'},
        true,
        'cb242c4861543ab43fff289ca2bb66b28e379bea6498e139b4f31b76f28e3f25',
      ),
      (
        two,
        {
          'shop': ['a&b', 'c d'],
        },
        true,
        '24cccad437b2d0f6ec32a627612c0186aed1d5642522c8fcdc2ae607cc2394b4',
      ),
      (
        two,
        {'city': 'Zürich', 'greeting': 'สวัสดี'},
        true,
        'c735f8a7f7147bdb607d0c7c84e837fbe5b586150a05a2bd24b84e715e4a7936',
      ),
      (
        [],
        {'userkey': 'fred'},
        true,
        'fa72395ce672552717d0f1124c506bee7489dfc1b08e0e68c7a13bb19ed3687a',
      ),
      (
        [],
        {},
        true,
        '47b4f8c61e15e70436a1debf458dfa0a7d6450d96e8ab384e461f47a6addee8d',
      ),
      (
        two,
        {'userkey': 'fred', 'empty': <String>[], 'gone': null},
        true,
        '75d6c29325aa18ac5255ca4b4d1513249d2d9dc74c5f494dc893884aa87def88',
      ),
    ];
    for (final (features, context, evaluated, sha) in vectors) {
      test('$context ${evaluated ? 'evaluated' : 'as delivered'}', () async {
        final (repository, store) = await _store(features);
        if (features.isEmpty) {
          // an empty full set still makes the store ready
          repository.notify(SSEResultState.features, <FeatureState>[]);
          await _pump();
        }
        final served = store.featureSnapshot(
          context: context,
          includeStrategies: !evaluated,
        );
        expect(served.snapshot.sha, sha);
        await store.close();
        repository.shutdown();
      });
    }
  });

  // encoding.etag.test_vectors
  group('the ETag', () {
    const sha =
        '5da6ce2616ad4cb03d94d3308a7557f2805d2de9624a63985ab267e449641876';

    Future<String> etag(
      List<FeatureState> features,
      Map<String, Object?> context,
      String clock, {
      bool includeStrategies = false,
    }) async {
      final (repository, store) = await _store(features);
      final now = DateTime.parse(clock);
      final served = store.featureSnapshot(
        context: context,
        includeStrategies: includeStrategies,
        now: now,
      );
      // the If-None-Match check gets the same ETag without evaluating
      expect(
        store.etagFor(
          context: context,
          includeStrategies: includeStrategies,
          now: now,
        ),
        served.etag,
      );
      await store.close();
      repository.shutdown();
      return served.etag;
    }

    group('fhubWhenActive', () {
      final features = [
        _f(
          'f1',
          2,
          strategies: [
            FeatureRolloutStrategy(
              id: 's1',
              value: 'tofu',
              attributes: [
                _attr(
                  'fhubWhenActive',
                  RolloutStrategyFieldType.DATETIME,
                  RolloutStrategyAttributeConditional.GREATER_EQUALS,
                  [_t],
                ),
              ],
            ),
          ],
        ),
        _f('f2', 1),
      ];
      const nz = {'country': 'nz'};

      for (final (clock, count) in [
        ('2026-12-01T08:59:59Z', 0),
        ('2026-12-01T09:00:00Z', 1),
        ('2026-12-01T09:00:00.999Z', 1),
        ('2026-12-01T09:00:01Z', 2),
        ('2027-01-01T00:00:00Z', 2),
      ]) {
        test('at $clock', () async {
          expect(await etag(features, nz, clock), '"${sha}_t$count"');
        });
      }

      test('a context fhubWhenActive changes neither sha nor count', () async {
        expect(
          await etag(features, {
            ...nz,
            'fhubWhenActive': '2020-01-01T00:00:00Z',
          }, '2026-12-01T08:59:59Z'),
          '"${sha}_t0"',
        );
      });

      test('no context, evaluated: the count still applies', () async {
        expect(
          await etag(features, {}, '2026-12-01T09:00:00Z'),
          '"2eb34db18f7d62cee6c8dd3aa234034598a667982b8d9831bee7bba2c4c33852_t1"',
        );
      });

      test('served as delivered: another sha, and no count', () async {
        expect(
          await etag(
            features,
            {},
            '2026-12-01T09:00:00Z',
            includeStrategies: true,
          ),
          '"e17b012d96433267fa3dc02316845226adbdb7d82bcb69f987617f178be3f482"',
        );
      });
    });

    group('other date attributes', () {
      final features = [
        _f(
          'f1',
          2,
          strategies: [
            FeatureRolloutStrategy(
              id: 's1',
              value: 'tofu',
              attributes: [
                _attr(
                  'launch',
                  RolloutStrategyFieldType.DATE,
                  RolloutStrategyAttributeConditional.GREATER,
                  ['2026-12-01'],
                ),
                _attr(
                  'expires',
                  RolloutStrategyFieldType.DATETIME,
                  RolloutStrategyAttributeConditional.LESS,
                  [_t],
                ),
              ],
            ),
          ],
        ),
        _f('f2', 1),
      ];

      test('the boundaries', () {
        expect(
          FeatureSnapshotStore.clockBoundaries(
            features,
          ).map((m) => DateTime.fromMicrosecondsSinceEpoch(m, isUtc: true)),
          [
            DateTime.utc(2026, 12, 1),
            DateTime.utc(2026, 12, 1, 9),
            DateTime.utc(2026, 12, 1, 9, 0, 1),
            DateTime.utc(2026, 12, 2),
          ],
        );
      });

      for (final (clock, count) in [
        ('2026-11-30T23:59:59Z', 0),
        ('2026-12-01T09:00:00.999Z', 2),
        ('2026-12-02T00:00:00Z', 4),
      ]) {
        test('at $clock', () async {
          expect(
            await etag(features, {'country': 'nz'}, clock),
            '"${sha}_t$count"',
          );
        });
      }
    });

    test('features without clock boundaries have no count', () async {
      final features = [
        _f(
          'f1',
          2,
          strategies: [
            FeatureRolloutStrategy(
              id: 'nz',
              value: 'tofu',
              attributes: [
                _attr(
                  'country',
                  RolloutStrategyFieldType.STRING,
                  RolloutStrategyAttributeConditional.EQUALS,
                  ['nz'],
                ),
              ],
            ),
            FeatureRolloutStrategy(
              id: 'never',
              value: 'uni',
              attributes: [
                _attr(
                  'fhubWhenActive',
                  RolloutStrategyFieldType.DATETIME,
                  RolloutStrategyAttributeConditional.INCLUDES,
                  [_t],
                ),
              ],
            ),
          ],
        ),
        _f('f2', 1),
      ];
      expect(
        await etag(features, {'country': 'nz'}, '2027-01-01T00:00:00Z'),
        '"$sha"',
      );
    });
  });

  // server.snapshot_api
  group('featureSnapshot', () {
    late ClientFeatureRepository repository;
    late FeatureSnapshotStore store;

    setUp(() async => (repository, store) = await _store([_colour(), _flag()]));
    tearDown(() async {
      await store.close();
      repository.shutdown();
    });

    FeatureState byKey(ServedSnapshot s, String key) =>
        s.snapshot.features.singleWhere((f) => f.key == key);

    test('without a context, evaluates as for an empty one by default', () {
      for (final s in [
        store.featureSnapshot(),
        store.featureSnapshot(context: {}),
      ]) {
        final colour = byKey(s, 'colour');
        expect(colour.value, 'blue');
        expect(colour.v, isNull);
        expect(colour.strategies, isNull);
      }
    });

    test('a context is evaluated even when strategies are asked for', () {
      final colour = byKey(
        store.featureSnapshot(
          context: {'country': 'nz'},
          includeStrategies: true,
        ),
        'colour',
      );
      expect(colour.value, 'green');
      expect(colour.strategies, isNull);
    });

    test('without a context, gives the features as delivered if asked', () {
      final s = store.featureSnapshot(includeStrategies: true);
      expect(s.snapshot.features.map((f) => f.toJson()), [
        _colour().toJson(),
        _flag().toJson(),
      ]);
      // copies: changing them changes nothing held
      byKey(s, 'colour').value = 'red';
      expect(repository.feature('colour').stringValue, 'blue');
      expect(
        byKey(store.featureSnapshot(includeStrategies: true), 'colour').value,
        'blue',
      );
    });

    test('with a context, evaluates the strategies for it', () {
      final s = store.featureSnapshot(context: {'country': 'nz'});
      final colour = byKey(s, 'colour');
      expect(colour.value, 'green');
      expect(colour.v, 'nz');
      expect(colour.strategies, isNull);
      expect(colour.version, 2);
      expect(colour.fp, {'owner': 'ui'});
      expect(colour.environmentId, 'env');
      expect(byKey(s, 'flag').toJson(), _flag().toJson());
    });

    test('ignores value interceptors', () {
      repository.addValueInterceptor(_Override());
      expect(repository.feature('flag').booleanValue, false);
      expect(byKey(store.featureSnapshot(context: {}), 'flag').value, true);
    });

    test('rejects a context FeatureHub cannot represent', () {
      expect(
        () => store.featureSnapshot(
          context: {
            'nested': {'a': 1},
          },
        ),
        throwsA(isA<InvalidContextException>()),
      );
    });

    test('the snapshot serialises as the protocol says', () {
      final json =
          jsonDecode(jsonEncode(store.featureSnapshot().snapshot))
              as Map<String, dynamic>;
      expect(json.keys, unorderedEquals(['sha', 'features']));
    });
  });

  // server.snapshot_store
  group('the store', () {
    test('refuses a server-evaluated key, and is never ready', () async {
      final (repository, store) = await _store([
        _flag(),
      ], apiKey: 'default/lingling/kwong');
      expect(store.connected, false);
      expect(store.ready, false);
      expect(
        () => store.featureSnapshot(),
        throwsA(isA<FeatureSnapshotNotReady>()),
      );
      repository.shutdown();
    });

    test('is not ready before features arrive', () async {
      final repository = ClientFeatureRepository();
      final store = FeatureSnapshotStore();
      await store.attach(
        FeatureStoreTarget(
          repository: repository,
          apiKey: 'default/lingling/kwong*orm',
        ),
      );
      expect(store.ready, false);
      expect(() => store.etagFor(), throwsA(isA<FeatureSnapshotNotReady>()));

      repository.notify(SSEResultState.features, [_flag()]);
      await _pump();
      expect(store.ready, true);
      expect(store.featureSnapshot().snapshot.features, hasLength(1));
      await store.close();
      repository.shutdown();
    });

    test('follows the repository: updates and deletes', () async {
      final (repository, store) = await _store([_colour(), _flag()]);
      final before = store.featureSnapshot().snapshot.sha;

      repository.notify(
        SSEResultState.feature,
        _flag().copyWith(version: 4, value: false),
      );
      await _pump();
      final updated = store.featureSnapshot();
      expect(updated.snapshot.sha, isNot(before));
      expect(
        updated.snapshot.features.singleWhere((f) => f.key == 'flag').value,
        false,
      );

      // an older version changes nothing
      repository.notify(SSEResultState.feature, _flag());
      await _pump();
      expect(store.featureSnapshot().snapshot.sha, updated.snapshot.sha);

      repository.notify(SSEResultState.deleteFeature, _flag());
      await _pump();
      expect(store.featureSnapshot().snapshot.features.map((f) => f.key), [
        'colour',
      ]);
      await store.close();
      repository.shutdown();
    });

    test('reads the clock once, given or its own', () async {
      var reads = 0;
      final repository = ClientFeatureRepository()
        ..notify(SSEResultState.features, [_flag()]);
      final store = FeatureSnapshotStore(
        clock: () {
          reads++;
          return DateTime.utc(2026, 12, 1);
        },
      );
      await store.attach(FeatureStoreTarget(repository: repository));
      store.featureSnapshot(context: {'country': 'nz'});
      expect(reads, 1);
      store.featureSnapshot(now: DateTime.utc(2026));
      expect(reads, 1);
      await store.close();
      repository.shutdown();
    });

    test('never notifies the repository', () async {
      final repository = ClientFeatureRepository();
      final updates = <RawFeatureUpdate>[];
      repository.rawFeatureUpdates.listen(updates.add);
      final store = FeatureSnapshotStore();
      await store.attach(FeatureStoreTarget(repository: repository));
      await _pump();
      expect(updates, isEmpty);
      await store.close();
      repository.shutdown();
    });
  });
}

class _Override extends ValueInterceptor {
  @override
  ValueMatch matched(String key, FeatureState? featureState) =>
      key == 'flag' ? const ValueMatch(true, false) : ValueMatch.none;
}
