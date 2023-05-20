import 'dart:async';
import 'dart:convert';

import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_client_sdk/featurehub.dart';
import 'package:featurehub_client_sdk/src/internal/repository.dart';
import 'package:test/test.dart';

void main() {
  late ClientFeatureRepository repo;

  setUp(() {
    repo = ClientFeatureRepository();
  });

  List<FeatureState> _initialFeatures(
      {int version = 1,
      FeatureValueType type = FeatureValueType.BOOLEAN,
      dynamic value = false}) {
    return [
      FeatureState(
          id: '1', key: '1', type: type, version: version, value: value)
    ];
  }

  test('If a feature is absent on full feature load, it is listed as no longer existing', () {
    repo.updateFeatures(_initialFeatures());
    expect(repo.feature('1').exists, isTrue);
    repo.updateFeatures([FeatureState(
        id: '2', key: 'feature_string', type: FeatureValueType.STRING, version: 1, value: '2')]);
    expect(repo.feature('feature_string').exists, isTrue);
    expect(repo.feature('1').exists, isFalse);
  });

  test('Readiness should fire when features appear', () {
    final sub = repo.readinessStream;

    repo.updateFeatures(_initialFeatures());

    expect(sub, emits(Readiness.Ready));
  });

  test('Failure in the stream should indicate failure', () {
    final sub = repo.readinessStream;
    repo.notify(SSEResultState.failure);
    expect(sub, emits(Readiness.Failed));
  });

  test(
      'Sending new versions of features into the  repository will trigger new features hook',
      () async {
    repo.updateFeatures(_initialFeatures());
    // ignore: unawaited_futures
    expectLater(repo.newFeatureStateAvailableStream, emits(repo));
    repo.updateFeatures(_initialFeatures(version: 2));
  });

  test('non existent keys dont exist', () {
    repo.updateFeatures(_initialFeatures());
    expect(repo.feature('fred').exists, equals(false));
  });

  test('boolean values work as expected', () {
    repo.updateFeatures(_initialFeatures(value: true));
    expect(repo.feature('1').flag, equals(true));
    expect(repo.feature('1').exists, equals(true));
  });

  test('number values work as expected', () {
    repo.updateFeatures(
        _initialFeatures(value: 26.3, type: FeatureValueType.NUMBER));
    expect(repo.feature('1').number, equals(26.3));
    expect(repo.feature('1').string, isNull);
    expect(repo.feature('1').flag, isNull);
    expect(repo.feature('1').exists, equals(true));
  });

  test(
      'string values work as expected and they support international character sets',
      () {
    repo.updateFeatures(
        _initialFeatures(value: 'друг Тима', type: FeatureValueType.STRING));

    expect(repo.feature('1').string, equals('друг Тима'));
    expect(repo.feature('1').number, isNull);
    expect(repo.feature('1').flag, isNull);
    expect(repo.feature('1').exists, equals(true));
  });

  test('json values work as expected', () {
    repo.updateFeatures(
        _initialFeatures(value: '{"a":"b"}', type: FeatureValueType.JSON));
    expect(repo.feature('1').json, equals({'a': 'b'}));
    expect(repo.feature('1').number, isNull);
    expect(repo.feature('1').flag, isNull);
    expect(repo.feature('1').string, isNull);
    expect(repo.feature('1').exists, equals(true));
  });

  test(
      "Sending the same features into the repository won't trigger the new features hook ",
      () {
    repo.updateFeatures(_initialFeatures());
    // can't actually test this, it times out, which is actually correct
    expectLater(repo.newFeatureStateAvailableStream, neverEmits(repo),
        skip: true);
    repo.updateFeatures(_initialFeatures());
  });

  test(
      "Listening for a feature that doesn't exist and then filling in features triggers stream",
      () {
    final sub = repo.feature('1').featureUpdateStream;
    sub.listen(expectAsync1((h) => expect(h.flag, equals(false))));
    repo.updateFeatures(_initialFeatures());
  });

  test('Listen for string value works as expected', () {
    final sub = repo.feature('1').featureUpdateStream;
    sub.listen(expectAsync1((h) {
      expect(h.flag, isNull);
      expect(h.string, equals('wopchick'));
    }));
    repo.updateFeatures(
        _initialFeatures(type: FeatureValueType.STRING, value: 'wopchick'));
  });

  test('Listen for number value works as expected', () {
    final sub = repo.feature('1').featureUpdateStream;
    sub.listen(expectAsync1((h) {
      expect(h.flag, isNull);
      expect(h.string, isNull);
      expect(h.number, equals(11.4));
    }));
    repo.updateFeatures(
        _initialFeatures(type: FeatureValueType.NUMBER, value: 11.4));
  });

  test('Listen for json value works as expected', () {
    final sub = repo.feature('1').featureUpdateStream;
    final json = {'fish': 'hello'};
    sub.listen(expectAsync1((h) {
      expect(h.flag, isNull);
      expect(h.string, isNull);
      expect(h.number, isNull);
      expect(h.json, equals(json));
    }));
    repo.updateFeatures(
        _initialFeatures(type: FeatureValueType.JSON, value: jsonEncode(json)));
  });

  test('Features trigger only on change', () {
    final sub = repo.feature('1').featureUpdateStream;
    // should emit twice and shut down, even if we filled with features three times
    expectLater(
        sub, emitsInOrder([emits(anything), emits(anything), emitsDone]));
    repo.updateFeatures(_initialFeatures());
    repo.updateFeatures(_initialFeatures());
    repo.updateFeatures(_initialFeatures(version: 2, value: true));
    repo.shutdown();
  });

  test(
      'A feature will trigger a change on change of value with the same version to support server side strategies',
      () {
    final sub = repo.feature('1').featureUpdateStream;
    // should emit twice and shut down, even if we filled with features three times
    expectLater(
        sub, emitsInOrder([emits(anything), emits(anything), emitsDone]));
    repo.updateFeatures(_initialFeatures());
    repo.updateFeatures( _initialFeatures(version: 1, value: true));
    repo.shutdown();
  });

  test('Features and then feature trigger change', () {
    final sub = repo.feature('1').featureUpdateStream;
    // should emit twice and shut down, even if we filled with features three times
    expectLater(
        sub, emitsInOrder([emits(anything), emits(anything), emitsDone]));
    repo.updateFeatures(_initialFeatures());
    final data = FeatureState(
        id: '1',
        version: 2,
        key: '1',
        value: true,
        type: FeatureValueType.BOOLEAN);
    repo.updateFeature(data);
    expect(repo.feature('1').exists, equals(true));
    repo.shutdown();
  });

  test('New feature value with no state change doesnt trigger change', () {
    final sub = repo.feature('1').featureUpdateStream;
    // should emit twice and shut down, even if we filled with features three times
    expectLater(sub, emitsInOrder([emits(anything), emitsDone]));
    repo.updateFeatures(_initialFeatures());
    final data = FeatureState(
        id: '1',
        version: 2,
        key: '1',
        value: false,
        type: FeatureValueType.BOOLEAN);
    repo.updateFeature(data);
    repo.shutdown();
  });

  test('Null value indicates set is false', () {
    repo.updateFeatures(_initialFeatures(value: null));
    expect(repo.feature('1').set, equals(false));
  });

  test('Getting a copy and then changing value of feature does not change copy', () {
    repo.updateFeatures(_initialFeatures());
    final copy = repo.feature('1').copy();
    final data = FeatureState(
        id: '1',
        version: 2,
        key: '1',
        value: true,
        type: FeatureValueType.BOOLEAN);
    repo.updateFeature(data);
    expect(copy.flag, equals(false));
    expect(repo.feature('1').flag, equals(true));
  });

  test(
      'Sending bye when not in catch and release will trigger a non ready state',
      () {
    final sub = repo.readinessStream;
    expectLater(
        sub,
        emitsInOrder([
          emits(Readiness.NotReady),
          emits(Readiness.Ready),
          emits(Readiness.NotReady),
          emitsDone
        ]));
    repo.updateFeatures(_initialFeatures());
    repo.notify(SSEResultState.bye);
    repo.shutdown();
    scheduleMicrotask(() {}); // one for each state
    scheduleMicrotask(() {});
  });

  test(
      'We get initial events for features but once catch and release is enabled, it stops until we release.',
      () async {
    final sub = repo.newFeatureStateAvailableStream;
    expect(repo.readiness, equals(Readiness.NotReady));
    repo.updateFeatures(_initialFeatures());
    expect(repo.readiness, equals(Readiness.Ready));
    repo.catchAndReleaseMode = true;
    // ignore: unawaited_futures
    expectLater(repo.catchAndReleaseMode, true);
    expect(repo.feature('1').flag, equals(false));
    expectLater(sub, emits(repo)); // ignore: unawaited_futures
    repo.updateFeatures(_initialFeatures(version: 2, value: true));
    // now update just the feature
    final data = FeatureState(
        id: '1',
        version: 3,
        key: '1',
        value: true,
        type: FeatureValueType.BOOLEAN);

    repo.updateFeature(data);

    expect(repo.feature('1').flag, equals(false));
    expect(repo.feature('1').flag, equals(false));
    expect(repo.feature('1').type, equals(FeatureValueType.BOOLEAN));
    expect(repo.feature('1').version, equals(1));
    await repo.release();
    expect(repo.feature('1').flag, equals(true));
    expect(repo.feature('1').version, equals(3));
    // but the repo is still in catch mode
    final data1 = FeatureState(
        id: '1',
        version: 4,
        key: '1',
        value: false,
        type: FeatureValueType.BOOLEAN);

    repo.updateFeature(data1);
    expect(repo.feature('1').flag, equals(true));
    expect(repo.feature('1').version, equals(3));
    // and now we release and turn off the release mode
    await repo.release(disableCatchAndRelease: true);
    expect(repo.catchAndReleaseMode, equals(false));
    expect(repo.feature('1').flag, equals(false));
    expect(repo.feature('1').version, equals(4));
    repo.shutdown();
  });

  test('if we delete a feature it is no longer there', () {
    repo.updateFeatures(_initialFeatures());
    expect(repo.availableFeatures, contains('1'));
    expect(repo.feature('1').flag, equals(false));
    expect(repo.feature('1').value, equals(false));
    expect(repo.feature('1').exists, isTrue);
    final data = FeatureState(
        id: '1',
        version: 2,
        key: '1',
        value: true,
        type: FeatureValueType.BOOLEAN);
    repo.deleteFeature(data);
    expect(repo.feature('1').exists, isFalse);
  });


  // test('client context should encode correctly', () {
  //   // do twice to ensure we can set everything twice
  //   repo.clientContext
  //       .userKey('DJElif')
  //       .sessionKey('Hot Situations')
  //       .attr('source', 'youtube')
  //       .attr('city', 'istanbul')
  //       .attrs('musical styles', ['deep', 'psychedelic'])
  //       .platform(StrategyAttributePlatformName.ios)
  //       .device(StrategyAttributeDeviceName.desktop)
  //       .version('8.9.2')
  //       .country(StrategyAttributeCountryName.turkey)
  //       .build();
  //   repo.clientContext
  //       .userKey('DJElif')
  //       .sessionKey('Hot Situations')
  //       .attr('source', 'youtube')
  //       .attr('city', 'istanbul')
  //       .attrs('musical styles', ['deep', 'psychedelic'])
  //       .platform(StrategyAttributePlatformName.ios)
  //       .device(StrategyAttributeDeviceName.desktop)
  //       .version('8.9.2')
  //       .country(StrategyAttributeCountryName.turkey)
  //       .build();
  //   expect(repo.clientContext.generateHeader(),
  //       'city=istanbul,country=turkey,device=desktop,musical styles=deep%2Cpsychedelic,platform=ios,session=Hot+Situations,source=youtube,userkey=DJElif,version=8.9.2');
  // });
}
