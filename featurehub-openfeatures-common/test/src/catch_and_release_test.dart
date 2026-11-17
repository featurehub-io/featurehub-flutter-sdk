import 'dart:async';

import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_openfeatures_common/featurehub_openfeatures_common.dart';
import 'package:test/test.dart';

FeatureState _flag(int version, bool value, {String key = 'flag'}) =>
    FeatureState(
      id: 'id-$key',
      key: key,
      version: version,
      type: FeatureValueType.BOOLEAN,
      value: value,
    );

/// A client-evaluated string feature whose strategy matches country "nz".
FeatureState _colour(int version, String nzValue) => FeatureState(
  id: 'id-colour',
  key: 'colour',
  version: version,
  type: FeatureValueType.STRING,
  value: 'blue',
  strategies: [
    FeatureRolloutStrategy(
      id: 'nz',
      value: nzValue,
      attributes: [
        FeatureRolloutStrategyAttribute(
          conditional: RolloutStrategyAttributeConditional.EQUALS,
          fieldName: 'country',
          values: ['nz'],
          type: RolloutStrategyFieldType.STRING,
        ),
      ],
    ),
  ],
);

/// Lets stream listeners run.
Future<void> _pump() => Future<void>.delayed(Duration.zero);

void main() {
  late ClientFeatureRepository repo;

  setUp(() {
    repo = ClientFeatureRepository();
    repo.notify(SSEResultState.features, [_flag(1, false)]);
    repo.catchAndReleaseMode = true;
  });

  tearDown(() => repo.shutdown());

  test(
    'turning the mode off with the setter releases caught updates',
    () async {
      repo.notify(SSEResultState.feature, _flag(2, true).toJson());
      expect(repo.getFlag('flag'), false);

      repo.catchAndReleaseMode = false;
      await _pump();

      expect(repo.catchAndReleaseMode, false);
      expect(repo.getFlag('flag'), true);
      expect(repo.feature('flag').version, 2);

      // updates now apply immediately
      repo.notify(SSEResultState.feature, _flag(3, false).toJson());
      expect(repo.getFlag('flag'), false);
    },
  );

  test('a caught update is only replaced by a newer version', () async {
    repo.notify(SSEResultState.feature, _flag(3, true).toJson());
    // an older update arriving later must not replace the caught one
    repo.notify(SSEResultState.feature, _flag(2, false).toJson());

    await repo.release();
    expect(repo.getFlag('flag'), true);
    expect(repo.feature('flag').version, 3);
  });

  test('caught updates are announced once, as waiting', () async {
    final available = <ClientFeatureRepository>[];
    final sub = repo.newFeatureStateAvailableStream.listen(available.add);

    repo.notify(SSEResultState.feature, _flag(2, true).toJson());
    await _pump();
    expect(available, hasLength(1), reason: 'an update is waiting');

    // releasing does not announce another waiting update
    await repo.release();
    await _pump();
    expect(available, hasLength(1));
    await sub.cancel();
  });

  test('changes are reported when applied, not when caught', () async {
    final changed = <ClientFeatureRepository>[];
    final sub = repo.featuresChangedStream.listen(changed.add);

    repo.notify(SSEResultState.feature, _flag(2, true).toJson());
    repo.notify(SSEResultState.features, [_flag(3, true)]);
    await _pump();
    expect(changed, isEmpty);

    await repo.release();
    await _pump();
    expect(changed, hasLength(1));

    // releasing with nothing caught changes nothing
    await repo.release();
    await _pump();
    expect(changed, hasLength(1));
    await sub.cancel();
  });

  test('a deleted feature is removed immediately', () async {
    // deletions are not caught
    repo.notify(SSEResultState.deleteFeature, _flag(1, false).toJson());
    expect(repo.feature('flag').exists, false);
    expect(repo.evaluate('flag').exists, false);
  });

  test('evaluation uses the held features until release', () async {
    repo.notify(SSEResultState.features, [
      _flag(1, false),
      _colour(1, 'green'),
    ]);
    // the colour feature is new, so it is caught too
    expect(repo.evaluate('colour').exists, false);
    await repo.release();

    const nz = MapStrategyContext({'country': 'nz'});
    expect(repo.evaluate('colour', context: nz).value, 'green');

    repo.notify(SSEResultState.feature, _colour(2, 'purple').toJson());
    expect(repo.evaluate('colour', context: nz).value, 'green');
    expect(repo.evaluate('colour', context: nz).version, 1);

    await repo.release();
    expect(repo.evaluate('colour', context: nz).value, 'purple');
  });

  group('switched on before the first features', () {
    late ClientFeatureRepository fresh;

    setUp(() {
      fresh = ClientFeatureRepository()..catchAndReleaseMode = true;
    });

    tearDown(() => fresh.shutdown());

    test('the initial features are applied and announced as ready', () async {
      final states = <Readyness>[];
      final sub = fresh.readynessStream.listen(states.add);

      fresh.notify(SSEResultState.features, [_flag(1, true)]);
      await _pump();

      expect(fresh.getFlag('flag'), true);
      expect(fresh.readyness, Readyness.Ready);
      expect(states, [Readyness.NotReady, Readyness.Ready]);

      // from now on, updates are caught
      fresh.notify(SSEResultState.feature, _flag(2, false).toJson());
      expect(fresh.getFlag('flag'), true);
      await fresh.release();
      expect(fresh.getFlag('flag'), false);
      await sub.cancel();
    });

    test('a single feature before the initial set is applied', () {
      fresh.notify(SSEResultState.feature, _flag(1, true).toJson());
      expect(fresh.getFlag('flag'), true);
    });

    test('an initial failure is broadcast', () async {
      final states = <Readyness>[];
      final sub = fresh.readynessStream.listen(states.add);

      fresh.notify(SSEResultState.failure, null);
      await _pump();
      expect(states, [Readyness.NotReady, Readyness.Failed]);

      // after that, catch mode applies: a bye is not broadcast...
      fresh.notify(SSEResultState.bye, null);
      await _pump();
      expect(states, hasLength(2));

      // ...but the first features are still applied, not caught
      fresh.notify(SSEResultState.features, [_flag(1, true)]);
      await _pump();
      expect(fresh.getFlag('flag'), true);
      expect(states.last, Readyness.Ready);
      await sub.cancel();
    });

    test('features from a store do not start catching', () async {
      // e.g. yesterday's features from browser storage
      fresh.notify(SSEResultState.features, [
        _flag(1, false),
      ], source: 'a-store');
      expect(fresh.readyness, Readyness.Ready);
      expect(fresh.getFlag('flag'), false);

      // FeatureHub's first features replace them, not held back
      fresh.notify(SSEResultState.features, [_flag(2, true)]);
      expect(fresh.getFlag('flag'), true);

      // and from then on, updates are caught
      fresh.notify(SSEResultState.feature, _flag(3, false).toJson());
      expect(fresh.getFlag('flag'), true);
    });

    test('a bye before the initial features is broadcast', () async {
      fresh.notify(SSEResultState.feature, _flag(1, true).toJson());
      final states = <Readyness>[];
      final sub = fresh.readynessStream.listen(states.add);
      await _pump();
      states.clear();

      fresh.notify(SSEResultState.bye, null);
      await _pump();
      expect(states, [Readyness.NotReady]);
      await sub.cancel();
    });
  });

  group('readiness', () {
    test('a reconnection makes the repository ready again', () async {
      final states = <Readyness>[];
      final sub = repo.readynessStream.listen(states.add);
      await _pump();
      states.clear(); // the current (ready) state

      repo.notify(SSEResultState.bye, null);
      expect(repo.readyness, Readyness.NotReady);

      // the features after reconnecting are caught, but the connection is
      // back
      repo.notify(SSEResultState.features, [_flag(2, true)]);
      expect(repo.readyness, Readyness.Ready);
      expect(repo.getFlag('flag'), false, reason: 'still caught');
      await _pump();
      expect(states, [Readyness.Ready]);
      await sub.cancel();
    });

    test('bye and failure are not broadcast while catching', () async {
      final states = <Readyness>[];
      final sub = repo.readynessStream.listen(states.add);
      await _pump();
      states.clear();

      repo.notify(SSEResultState.bye, null);
      repo.notify(SSEResultState.failure, null);
      await _pump();

      expect(states, isEmpty);
      expect(repo.readyness, Readyness.Failed);
      await sub.cancel();
    });
  });

  group('ProviderStateTracker', () {
    late List<List<String>> changes;
    late ProviderStateTracker tracker;

    setUp(() {
      changes = [];
      tracker = ProviderStateTracker(
        repo,
        onStale: () {},
        onRecovered: () {},
        onFatal: () {},
        onFlagsChanged: changes.add,
        onEnvironmentStale: () {},
      );
    });

    tearDown(() => tracker.cancel());

    test('announces released flags, not caught ones', () async {
      repo.notify(SSEResultState.feature, _flag(2, true).toJson());
      await _pump();
      expect(changes, isEmpty);

      await repo.release();
      await _pump();
      expect(changes, [
        ['flag'],
      ]);
    });

    test('announces deleted flags', () async {
      repo.notify(SSEResultState.deleteFeature, _flag(1, false).toJson());
      await _pump();
      expect(changes, [
        ['flag'],
      ]);
    });
  });

  group('deleting', () {
    test('a caught update does not bring a deleted feature back', () async {
      repo.notify(SSEResultState.feature, _flag(2, true).toJson());
      repo.notify(SSEResultState.deleteFeature, _flag(2, true).toJson());
      expect(repo.featureStates, isEmpty);
      await repo.release();
      expect(repo.featureStates, isEmpty);
    });

    test('features missing from a caught full set go on release', () async {
      repo.notify(SSEResultState.features, [_flag(1, false, key: 'other')]);
      // held back: flag is still there
      expect(repo.getFlag('flag'), false);
      expect(repo.featureStates.map((f) => f.key), ['flag']);

      // a single feature caught after the set is kept
      repo.notify(SSEResultState.feature, _flag(1, true, key: 'late').toJson());
      await repo.release();
      expect(
        repo.featureStates.map((f) => f.key),
        unorderedEquals(['other', 'late']),
      );
    });
  });
}
