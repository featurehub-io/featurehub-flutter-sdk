import 'dart:async';

import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_openfeatures_common/featurehub_openfeatures_common.dart';
import 'package:test/test.dart';

FeatureState _flag(int version, {String id = 'f1', String key = 'flag'}) =>
    FeatureState(
      id: id,
      key: key,
      version: version,
      type: FeatureValueType.BOOLEAN,
      value: version.isEven,
    );

void main() {
  late ClientFeatureRepository repo;
  late List<RawFeatureUpdate> updates;
  late StreamSubscription<RawFeatureUpdate> sub;

  setUp(() {
    repo = ClientFeatureRepository();
    updates = [];
    sub = repo.rawFeatureUpdates.listen(updates.add);
  });

  tearDown(() async {
    await sub.cancel();
    repo.shutdown();
  });

  Future<void> pump() => Future<void>.delayed(Duration.zero);

  test('every kind of change is published with its source', () async {
    repo.notify(SSEResultState.features, [_flag(1)]);
    repo.notify(SSEResultState.feature, _flag(2).toJson());
    repo.notify(SSEResultState.deleteFeature, _flag(2).toJson());
    await pump();

    expect(updates, hasLength(3));
    final all = updates[0] as FeaturesReceived;
    expect(all.features.single.version, 1);
    expect((updates[1] as FeatureReceived).feature.version, 2);
    expect((updates[2] as FeatureDeleted).feature.id, 'f1');
    expect(updates.map((u) => u.source).toSet(), {featureHubEdgeSource});
  });

  test('a given source is passed on', () async {
    repo.notify(SSEResultState.features, [_flag(1)], source: 'my-store');
    await pump();
    expect(updates.single.source, 'my-store');
  });

  test('FeatureState objects are accepted as well as JSON', () async {
    repo.notify(SSEResultState.feature, _flag(3));
    repo.notify(SSEResultState.deleteFeature, _flag(3));
    await pump();
    expect((updates[0] as FeatureReceived).feature.version, 3);
    expect(updates[1], isA<FeatureDeleted>());
    expect(repo.evaluate('flag').exists, false);
  });

  test('updates are published in catch and release mode too', () async {
    repo.notify(SSEResultState.features, [_flag(1)]);
    repo.catchAndReleaseMode = true;
    repo.notify(SSEResultState.feature, _flag(2).toJson());
    await pump();

    // the store sees the update although the repository holds it back
    expect((updates.last as FeatureReceived).feature.version, 2);
    expect(repo.feature('flag').version, 1);
  });

  test('other notifications are not published', () async {
    repo.notify(SSEResultState.ack, null);
    repo.notify(SSEResultState.bye, null);
    repo.notify(SSEResultState.failure, null);
    await pump();
    expect(updates, isEmpty);
  });

  test('the stream closes when the repository shuts down', () async {
    final done = Completer<void>();
    repo.rawFeatureUpdates.listen(null, onDone: done.complete);
    repo.shutdown();
    await done.future.timeout(const Duration(seconds: 1));
  });

  group('FeatureStoreTarget', () {
    test('derives the environment id as the other SDKs do', () {
      expect(environmentIdFromApiKey('default/env-123/abc*def'), 'env-123');
      expect(environmentIdFromApiKey('env-123/abc'), 'env-123');
      expect(
        environmentIdFromApiKey('junk'),
        '3ea0f571-c153-48bf-9543-df76c6f9ca50',
      );
    });

    test('describes the key and feature URL', () {
      final target = FeatureStoreTarget(
        repository: repo,
        host: 'http://edge/',
        apiKey: 'default/env/key*secret',
      );
      expect(target.clientEvaluated, true);
      expect(target.environmentId, 'env');
      expect(target.featureUrl, 'http://edge/features/default/env/key*secret');
    });
  });
}
