import 'dart:convert';
import 'dart:io';

import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_openfeatures_common/featurehub_openfeatures_common.dart';
import 'package:featurehub_openfeatures_yaml_interceptor/featurehub_openfeatures_yaml_interceptor.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late String yamlFile;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('fh_yaml_store');
    yamlFile = '${dir.path}/features.yaml';
  });

  tearDown(() => dir.deleteSync(recursive: true));

  List<FeatureState> features(String content) {
    File(yamlFile).writeAsStringSync(content);
    return LocalYamlFeatureStore(
      filename: yamlFile,
    ).features(environmentId: 'env-1');
  }

  FeatureState feature(String content, String key) =>
      features(content).singleWhere((f) => f.key == key);

  group('the file', () {
    test('is otherwise named by FEATUREHUB_LOCAL_YAML', () {
      File(yamlFile).writeAsStringSync('flagValues:\n  a: true\n');
      final store = LocalYamlFeatureStore(
        environment: {'FEATUREHUB_LOCAL_YAML': yamlFile},
      );
      expect(store.path, yamlFile);
      expect(store.features().single.key, 'a');
    });

    test('gives no features when missing, empty or without flagValues', () {
      expect(
        LocalYamlFeatureStore(filename: '${dir.path}/missing.yaml').features(),
        isEmpty,
      );
      expect(features('otherKey: 1\n'), isEmpty);
      expect(features('flagValues: {}\n'), isEmpty);
    });
  });

  group('each feature', () {
    test('has the key, version 1, unlocked, in the environment', () {
      final f = feature('flagValues:\n  my-feature: true\n', 'my-feature');
      expect(f.key, 'my-feature');
      expect(f.version, 1);
      expect(f.l, false);
      expect(f.environmentId, 'env-1');
    });

    test('has the short SHA-256 of its key as its id, as in TypeScript', () {
      // computed with Node's crypto, as the TypeScript store does
      expect(
        feature('flagValues:\n  my-feature: true\n', 'my-feature').id,
        'fe6e9d24',
      );
      expect(LocalYamlFeatureStore.shortSha256('alpha'), '8ed3f6ad');
    });

    test('one per entry', () {
      expect(
        features(
          'flagValues:\n  a: 1\n  b: 2\n  c: 3\n',
        ).map((f) => f.key).toList(),
        ['a', 'b', 'c'],
      );
    });
  });

  group('types', () {
    test('booleans, also as strings in any case', () {
      for (final (yaml, value) in [
        ('true', true),
        ('false', false),
        ('"true"', true),
        ('"FALSE"', false),
        ('"True"', true),
      ]) {
        final f = feature('flagValues:\n  f: $yaml\n', 'f');
        expect(f.type, FeatureValueType.BOOLEAN, reason: yaml);
        expect(f.value, value, reason: yaml);
      }
    });

    test('null and strings, including numeric ones, are strings', () {
      final fs = features('flagValues:\n  z: ~\n  s: hello\n  n: "42"\n');
      expect(fs.map((f) => f.type), everyElement(FeatureValueType.STRING));
      expect(fs.map((f) => f.value), [null, 'hello', '42']);
    });

    test('numbers are numbers', () {
      final fs = features('flagValues:\n  i: 42\n  d: 3.14\n  m: -7\n');
      expect(fs.map((f) => f.type), everyElement(FeatureValueType.NUMBER));
      expect(fs.map((f) => f.value), [42, 3.14, -7]);
    });

    test('maps and lists are JSON', () {
      final fs = features(
        'flagValues:\n  o:\n    x:\n      y: 99\n  l:\n    - 1\n    - two\n'
        '    - true\n',
      );
      expect(fs.map((f) => f.type), everyElement(FeatureValueType.JSON));
      expect(jsonDecode(fs[0].value as String), {
        'x': {'y': 99},
      });
      expect(jsonDecode(fs[1].value as String), [1, 'two', true]);
    });
  });

  group('loading', () {
    late ClientFeatureRepository repo;

    setUp(() {
      File(yamlFile).writeAsStringSync(
        'flagValues:\n  enabled: true\n  count: 3\n  name: yaml\n',
      );
      repo = ClientFeatureRepository();
    });

    tearDown(() => repo.shutdown());

    test('fills a repository, which is then ready', () async {
      final updates = <RawFeatureUpdate>[];
      final sub = repo.rawFeatureUpdates.listen(updates.add);
      LocalYamlFeatureStore(filename: yamlFile).load(repo);
      expect(repo.readyness, Readyness.Ready);
      expect(repo.evaluate('enabled').value, true);
      expect(repo.evaluate('count').value, 3);
      expect(repo.feature('name').stringValue, 'yaml');
      await Future<void>.delayed(Duration.zero);
      expect(updates.single.source, localYamlStoreSource);
      await sub.cancel();
    });

    test('as a provider store, in the target environment', () async {
      final store = LocalYamlFeatureStore(filename: yamlFile);
      expect(store.connected, false);
      await store.attach(
        FeatureStoreTarget(
          repository: repo,
          host: 'http://edge',
          apiKey: 'default/env-9/key',
        ),
      );
      expect(store.connected, true);
      expect(repo.evaluate('enabled').featureState?.environmentId, 'env-9');
      await store.close();
      expect(store.connected, false);
    });
  });
}
