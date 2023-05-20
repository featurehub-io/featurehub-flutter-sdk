import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_client_sdk/featurehub.dart';
import 'package:featurehub_client_sdk/src/internal/repository.dart';
import 'package:test/test.dart';

/// We are just testing the analytics stream coming from the repository

main() {
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
          id: '1', key: 'feature_x', type: type, version: version, value: value)
    ];
  }

  test(
      'if we subscribe to the analytics events we get a copy of the list of current features',
      () {
    repo.updateFeatures(_initialFeatures());
    repo.analyticsStream.listen(expectAsync1((e) {
      expect(e, isA<AnalyticsFeatureCollection>());
      final col = e.toMap();
      expect(col['keys'], equals(['feature_x']));
      expect(col['feature_x'], equals({'value': 'off', 'id': '1'}));
      expect(col['half'], equals('1.0'));
    }));

    repo.logFeaturesAsCollection(other: {'half': '1.0'});
  });

  test('single useFeature boolean with analytics evaluation sends value plus attributes', () {
    repo.analyticsStream.listen(expectAsync1((e) {
      expect(e, isA<AnalyticsFeature>());
      final col = e.toMap();
      expect(col['feature'], equals('F_KEY'));
      expect(col['id'], equals('1234'));
      expect(col['value'], equals('off'));
      expect(col.length, equals(3));
    }));
    repo.used('F_KEY', '1234', false, FeatureValueType.BOOLEAN, {});

  });
}
