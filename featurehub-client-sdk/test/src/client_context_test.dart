import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_client_sdk/featurehub.dart';
import 'package:featurehub_client_sdk/src/internal/internal_repository.dart';
import 'package:featurehub_client_sdk/src/internal/repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import 'mocks.dart';

main() {
  late MockInternalFeatureRepository repo;
  late ClientContext ctx;

  setUp(() {
    repo = MockInternalFeatureRepository();
    ctx = ClientContext(repo);
  });

  test('feature returns feature', () {
    expect(ctx.feature('fred').key, equals('fred'));
  });

  test('feature bool returns value', () {
    when(() => repo.fe.flag).thenReturn(true);
    expect(ctx.flag('fred'), isTrue);
    verify(() => repo.fe.flag).called(1);
  });

  test('feature string returns value', () {
    when(() => repo.fe.string).thenReturn('alfie');
    expect(ctx.string('fred'), equals('alfie'));
    verify(() => repo.fe.string).called(1);
  });

  test('set returns value', () {
    when(() => repo.fe.set).thenReturn(true);
    expect(ctx.set('fred'), isTrue);
    verify(() => repo.fe.set).called(1);
  });

  test('enabled returns value', () {
    when(() => repo.fe.enabled).thenReturn(true);
    expect(ctx.enabled('fred'), isTrue);
    verify(() => repo.fe.enabled).called(1);
  });

  test('json returns value', () {
    const json = {'one': 1};
    when(() => repo.fe.json).thenReturn(json);
    expect(ctx.json('fred'), equals(json));
    verify(() => repo.fe.json).called(1);
  });

  test('number returns value', () {
    when(() => repo.fe.number).thenReturn(76.3);
    expect(ctx.number('fred'), equals(76.3));
    verify(() => repo.fe.number).called(1);
  });

  test('exists returns value', () {
    when(() => repo.fe.exists).thenReturn(true);
    expect(ctx.exists('fred'), isTrue);
    verify(() => repo.fe.exists).called(1);
  });

  test('readiness returns value', () {
     expect(ctx.readiness, equals(Readiness.NotReady));
     repo.r = Readiness.Ready;
     expect(ctx.readiness, equals(Readiness.Ready));
  });

  test('userKey method sets valid userKey attribute', () {
    ctx.userKey('fred');

    expect(ctx['userkey'], equals(['fred']));
  });

  test('device method sets valid device attribute', () {
    ctx.device(StrategyAttributeDeviceName.browser);
    expect(ctx['device'], equals([StrategyAttributeDeviceName.browser.name]));
  });

  test('country method sets valid country attribute', () {
    ctx.country(StrategyAttributeCountryName.romania);
    expect(ctx['country'], equals([StrategyAttributeCountryName.romania.name]));
  });

  test('platform method sets valid platform attribute', () {
    ctx.platform(StrategyAttributePlatformName.linux);
    expect(ctx['platform'], equals([StrategyAttributePlatformName.linux.name]));
  });

  test('session method sets valid session attribute', () {
    ctx.sessionKey("username");
    expect(ctx['session'], equals(['username']));
  });

  test('version method sets valid version attribute', () {
    ctx.version('1.6.3-RC');
    expect(ctx['version'], equals(['1.6.3-RC']));
  });

  test('custom method sets valid custom single attribute', () {
    ctx.attr('warehouseId', '16');
    expect(ctx['warehouseId'], equals(['16']));
  });

  test('custom method sets valid custom normal attribute', () {
    ctx['warehouseIds'] = ['16', '21', '17'];
    expect(ctx['warehouseIds'], equals(['16', '21', '17']));
  });
}
