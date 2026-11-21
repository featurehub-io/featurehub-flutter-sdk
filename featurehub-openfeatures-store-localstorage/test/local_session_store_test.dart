import 'dart:async';
import 'dart:convert';

import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_openfeatures_common/featurehub_openfeatures_common.dart';
import 'package:featurehub_openfeatures_store_localstorage/featurehub_openfeatures_store_localstorage.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

class _MemoryStorage implements FeatureStorage {
  final items = <String, String>{};
  @override
  String? getItem(String key) => items[key];
  @override
  void setItem(String key, String value) => items[key] = value;
}

FeatureState _feature(String id, int version, {String? key, Object? value}) =>
    FeatureState(
      id: id,
      key: key ?? 'key-$id',
      version: version,
      type: FeatureValueType.STRING,
      value: value ?? 'v$version',
    );

const _host = 'http://edge.example.com';
const _apiKey = 'default/env/key*secret';
const _storageKey = '$_host/features/$_apiKey';

Future<void> _pump() => Future<void>.delayed(Duration.zero);

void main() {
  late ClientFeatureRepository repo;
  late _MemoryStorage storage;
  late LocalSessionStore store;

  FeatureStoreTarget target() =>
      FeatureStoreTarget(repository: repo, host: _host, apiKey: _apiKey);

  Map<String, dynamic> stored() =>
      jsonDecode(storage.items[_storageKey]!) as Map<String, dynamic>;

  setUp(() {
    repo = ClientFeatureRepository();
    storage = _MemoryStorage();
    store = LocalSessionStore(storage: storage);
  });

  tearDown(() async {
    await store.close();
    repo.shutdown();
  });

  group('attaching', () {
    test('follows the repository', () async {
      expect(store.connected, false);
      await store.attach(target());
      expect(store.connected, true);
    });

    test('does nothing when storage is empty', () async {
      await store.attach(target());
      expect(repo.readyness, Readyness.NotReady);
      expect(storage.items, isEmpty);
    });

    test('loads the stored features into the repository', () async {
      storage.items[_storageKey] = jsonEncode({
        'a': _feature('a', 3, key: 'colour', value: 'green').toJson(),
      });
      await store.attach(target());

      expect(repo.readyness, Readyness.Ready);
      expect(repo.evaluate('colour').value, 'green');
      // loading them does not write them back
      await _pump();
      expect(stored().keys, ['a']);
    });

    test('ignores malformed data', () async {
      storage.items[_storageKey] = '{not json';
      await store.attach(target());
      expect(repo.readyness, Readyness.NotReady);
    });

    test('keeps environments apart', () async {
      storage.items['$_host/features/other/env/key*x'] = jsonEncode({
        'a': _feature('a', 1).toJson(),
      });
      await store.attach(target());
      expect(repo.readyness, Readyness.NotReady);
    });
  });

  group('updates', () {
    setUp(() => store.attach(target()));

    test('a full set replaces the stored features', () async {
      repo.notify(SSEResultState.features, [
        _feature('a', 1),
        _feature('b', 1),
      ]);
      await _pump();
      expect(stored().keys, unorderedEquals(['a', 'b']));

      repo.notify(SSEResultState.features, [_feature('c', 1)]);
      await _pump();
      expect(stored().keys, ['c']);
    });

    test('a single feature is added or replaced', () async {
      repo.notify(SSEResultState.features, [_feature('a', 1)]);
      repo.notify(SSEResultState.feature, _feature('b', 1).toJson());
      repo.notify(SSEResultState.feature, _feature('a', 2).toJson());
      await _pump();

      expect(stored().keys, unorderedEquals(['a', 'b']));
      expect(stored()['a']['version'], 2);
    });

    test('a deleted feature is removed', () async {
      repo.notify(SSEResultState.features, [
        _feature('a', 1),
        _feature('b', 1),
      ]);
      repo.notify(SSEResultState.deleteFeature, _feature('a', 1).toJson());
      await _pump();
      expect(stored().keys, ['b']);
    });

    test('its own updates are ignored', () async {
      repo.notify(SSEResultState.features, [
        _feature('a', 1),
      ], source: localSessionStoreSource);
      await _pump();
      expect(storage.items, isEmpty);
    });

    test('nothing is stored after closing', () async {
      await store.close();
      repo.notify(SSEResultState.features, [_feature('a', 1)]);
      await _pump();
      expect(storage.items, isEmpty);
    });
  });

  group('browser storage', () {
    for (final (name, storage, make) in [
      ('sessionStorage', web.window.sessionStorage, () => LocalSessionStore()),
      (
        'localStorage',
        web.window.localStorage,
        () => LocalSessionStore.localStorage(),
      ),
    ]) {
      test('$name keeps the features for the next start', () async {
        storage.removeItem(_storageKey);

        final first = make();
        await first.attach(target());
        repo.notify(SSEResultState.features, [
          _feature('a', 7, key: 'colour', value: 'purple'),
        ]);
        await _pump();
        await first.close();
        expect(storage.getItem(_storageKey), isNotNull);

        // a new start, before FeatureHub has answered
        final next = ClientFeatureRepository();
        final second = make();
        await second.attach(
          FeatureStoreTarget(repository: next, host: _host, apiKey: _apiKey),
        );
        expect(next.evaluate('colour').value, 'purple');
        await second.close();
        next.shutdown();
        storage.removeItem(_storageKey);
      });
    }
  });
}
