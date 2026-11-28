import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_openfeatures_common/featurehub_openfeatures_common.dart';
import 'package:test/test.dart';

/// Supplies [values], recording the feature states it is asked about.
class _MapInterceptor extends ValueInterceptor {
  final Map<String, Object?> values;
  final seen = <String, FeatureValueType?>{};
  var closed = 0;

  _MapInterceptor(this.values);

  @override
  ValueMatch matched(String key, FeatureState? featureState) {
    seen[key] = featureState?.type;
    return values.containsKey(key)
        ? ValueMatch(true, values[key])
        : ValueMatch.none;
  }

  @override
  void close() => closed++;
}

void main() {
  late ClientFeatureRepository repo;

  setUp(() {
    repo = ClientFeatureRepository();
    repo.notify(SSEResultState.features, [
      FeatureState(
        id: '1',
        key: 'flag',
        version: 1,
        type: FeatureValueType.BOOLEAN,
        value: false,
      ),
      FeatureState(
        id: '2',
        key: 'locked',
        version: 1,
        type: FeatureValueType.NUMBER,
        value: 1,
        l: true,
      ),
      FeatureState(
        id: '3',
        key: 'json',
        version: 1,
        type: FeatureValueType.JSON,
        value: '{"a":1}',
      ),
    ]);
  });

  tearDown(() => repo.shutdown());

  test('interceptors see the feature, and supply typed values', () {
    final i = _MapInterceptor({'flag': true, 'locked': 7});
    repo.addValueInterceptor(i);
    expect(repo.evaluate('flag').value, true);
    expect(repo.evaluate('flag').intercepted, true);
    expect(repo.feature('flag').booleanValue, true);
    expect(i.seen['flag'], FeatureValueType.BOOLEAN);
    expect(repo.evaluate('missing').intercepted, false);
    expect(i.seen.containsKey('missing'), true);
    expect(i.seen['missing'], isNull);
  });

  test('they override locked features unless told not to', () {
    repo.addValueInterceptor(_MapInterceptor({'locked': 7}));
    expect(repo.evaluate('locked').value, 7);
    expect(repo.feature('locked').numberValue, 7);

    final other = ClientFeatureRepository()
      ..notify(SSEResultState.features, [
        FeatureState(
          id: '2',
          key: 'locked',
          version: 1,
          type: FeatureValueType.NUMBER,
          value: 1,
          l: true,
        ),
      ])
      ..addValueInterceptor(
        _MapInterceptor({'locked': 7}),
        allowLockOverride: false,
      );
    expect(other.evaluate('locked').value, 1);
    other.shutdown();
  });

  test('the first that matches supplies the value', () {
    repo.addValueInterceptor(_MapInterceptor({'flag': true}));
    repo.addValueInterceptor(_MapInterceptor({'flag': false, 'json': '[]'}));
    expect(repo.evaluate('flag').value, true);
    expect(repo.evaluate('json').value, '[]');
  });

  test('they can be removed', () {
    final i = _MapInterceptor({'flag': true});
    repo.addValueInterceptor(i);
    repo.removeValueInterceptor(i);
    expect(repo.evaluate('flag').value, false);
    expect(i.closed, 0);
  });

  test('they are closed when the repository shuts down', () {
    final i = _MapInterceptor({});
    final other = ClientFeatureRepository()..addValueInterceptor(i);
    other.shutdown();
    expect(i.closed, 1);
  });

  test('feature holders convert intercepted strings', () {
    repo.registerFeatureValueInterceptor(
      true,
      (key) => switch (key) {
        'flag' => const ValueMatch(true, 'TRUE'),
        'locked' => const ValueMatch(true, ' 12 '),
        'json' => const ValueMatch(true, '{"b":2}'),
        _ => ValueMatch.none,
      },
    );
    expect(repo.feature('flag').booleanValue, true);
    expect(repo.feature('locked').numberValue, 12);
    expect(repo.feature('json').jsonValue, {'b': 2});
    expect(repo.feature('json').stringValue, '{"b":2}');
  });
}
