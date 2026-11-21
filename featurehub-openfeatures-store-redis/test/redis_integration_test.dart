// Runs against a real Redis when FEATUREHUB_TEST_REDIS is set to host:port,
// e.g.
//
//   docker run -d --rm -p 16379:6379 redis:7.2-alpine
//   FEATUREHUB_TEST_REDIS=localhost:16379 dart test
@TestOn('vm')
library;

import 'dart:io';
import 'dart:math';

import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_openfeatures_common/featurehub_openfeatures_common.dart';
import 'package:featurehub_openfeatures_store_redis/featurehub_openfeatures_store_redis.dart';
import 'package:test/test.dart';

final _server = Platform.environment['FEATUREHUB_TEST_REDIS'];

FeatureState _feature(String id, int version, String value) => FeatureState(
  id: id,
  key: 'key-$id',
  version: version,
  type: FeatureValueType.STRING,
  value: value,
);

void main() {
  group(
    'against Redis',
    () {
      late String host;
      late int port;
      // a fresh environment per test, so tests never share keys
      late String environment;

      setUp(() {
        final parts = _server!.split(':');
        host = parts[0];
        port = int.parse(parts[1]);
        environment = 'test-${Random().nextInt(1 << 32)}';
      });

      Future<PackageRedisCommands> connect() =>
          PackageRedisCommands.connect(host: host, port: port);

      test('commands work against Redis', () async {
        final a = await connect();
        final b = await connect();
        final key = 'featurehub_$environment';

        await a.set(key, 'one');
        expect(await b.get(key), 'one');
        expect(await a.get('${key}_missing'), isNull);

        // a transaction succeeds when the watched key is unchanged...
        await a.watch(key);
        expect(await a.setAll({key: 'two', '${key}_sha': 'x'}), true);
        expect(await b.get(key), 'two');

        // ...and fails when another connection changes it first
        await a.watch(key);
        await b.set(key, 'from b');
        expect(await a.setAll({key: 'three'}), false);
        expect(await b.get(key), 'from b');

        await a.close();
        await b.close();
      });

      test('processes share features through Redis', () async {
        final apiKey = 'default/$environment/key*secret';
        final repoA = ClientFeatureRepository();
        final repoB = ClientFeatureRepository();
        final storeA = await RedisFeatureStore.connect(host: host, port: port);
        final storeB = await RedisFeatureStore.connect(host: host, port: port);
        await storeA.attach(
          FeatureStoreTarget(
            repository: repoA,
            host: 'http://edge',
            apiKey: apiKey,
          ),
        );
        await storeB.attach(
          FeatureStoreTarget(
            repository: repoB,
            host: 'http://edge',
            apiKey: apiKey,
          ),
        );

        // process A receives features from FeatureHub; B picks them up
        repoA.notify(SSEResultState.features, [_feature('a', 1, 'shared')]);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await storeB.refresh();
        expect(repoB.evaluate('key-a').value, 'shared');

        // and a later update to B reaches A
        repoB.notify(SSEResultState.feature, _feature('a', 2, 'updated'));
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await storeA.refresh();
        expect(repoA.evaluate('key-a').value, 'updated');

        // a new process starts with the shared features
        final repoC = ClientFeatureRepository();
        final storeC = await RedisFeatureStore.fromUrl('redis://$host:$port/0');
        await storeC.attach(
          FeatureStoreTarget(
            repository: repoC,
            host: 'http://edge',
            apiKey: apiKey,
          ),
        );
        expect(repoC.readyness, Readyness.Ready);
        expect(repoC.evaluate('key-a').value, 'updated');

        for (final store in [storeA, storeB, storeC]) {
          await store.close();
        }
        for (final repo in [repoA, repoB, repoC]) {
          repo.shutdown();
        }
      });
    },
    skip: _server == null
        ? 'set FEATUREHUB_TEST_REDIS=host:port to test against Redis'
        : false,
  );
}
