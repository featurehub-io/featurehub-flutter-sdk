import 'dart:io';

import 'package:featurehub_openfeatures_common/featurehub_openfeatures_common.dart';
import 'package:featurehub_openfeatures_yaml_interceptor/featurehub_openfeatures_yaml_interceptor.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late String yamlFile;
  late ClientFeatureRepository repo;
  late LocalYamlFeatureStore store;
  late LocalYamlValueInterceptor interceptor;

  void write(String content) => File(yamlFile).writeAsStringSync(content);

  FeatureHubResolution<bool> resolve(String key) => resolveFromEvaluation(
    key,
    FeatureKind.boolean,
    false,
    repo.evaluate(key),
  );

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('fh_yaml_together');
    yamlFile = '${dir.path}/features.yaml';
    write('flagValues:\n  flag: true\n  count: 3\n');
    repo = ClientFeatureRepository();
    store = LocalYamlFeatureStore(filename: yamlFile);
    interceptor = LocalYamlValueInterceptor(
      filename: yamlFile,
      watchForChanges: true,
      pollInterval: const Duration(milliseconds: 20),
    );
    await store.attach(
      FeatureStoreTarget(repository: repo, host: 'http://edge', apiKey: 'a/b'),
    );
    repo.addValueInterceptor(interceptor);
  });

  tearDown(() {
    repo.shutdown();
    dir.deleteSync(recursive: true);
  });

  test('the store creates the features, so they resolve straight away', () {
    expect(repo.readyness, Readyness.Ready);
    expect(resolve('flag').value, true);
    expect(resolve('flag').isError, false);
    expect(repo.evaluate('count').value, 3);
  });

  test('edits to the file are picked up through the interceptor', () async {
    write('flagValues:\n  flag: false\n  count: 4\n');
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(resolve('flag').value, false);
    expect(repo.evaluate('count').value, 4);
  });

  test('a key added later exists once the store loads again', () async {
    write('flagValues:\n  flag: true\n  count: 3\n  added: true\n');
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(resolve('added').errorCode, ResolutionErrorCode.flagNotFound);
    store.load(repo);
    expect(resolve('added').value, true);
  });
}
