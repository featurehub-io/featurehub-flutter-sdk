import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_client_sdk/featurehub.dart';
import 'package:featurehub_client_sdk/src/repository.dart';
import 'package:featurehub_client_sdk/src/server_eval_context.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import 'mocks.dart';

/// We are just testing the analytics stream coming from the repository

main() {
  group("analytics tests", () {
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
            id: '1',
            key: 'feature_x',
            type: type,
            version: version,
            value: value)
      ];
    }

    test('just loading the features for the 1st time should trigger async feature collection', () {
      repo.updateFeatures(_initialFeatures());
      repo.analyticsStream.listen(expectAsync1((e) {
        expect(e, isA<AnalyticsFeaturesCollection>());
      }));
    });

    test(
        'if we subscribe to the analytics events we get a copy of the list of current features',
        () async {
      repo.updateFeatures(_initialFeatures());
      repo.analyticsStream.listen(expectAsync1((e) {
        expect(e, isA<AnalyticsFeaturesCollection>());
        final col = e.toMap();
        // expect(col['keys'], equals(['feature_x']));
        expect(col['feature_x'], equals('off'));
        if  ((e as AnalyticsFeaturesCollection).additionalParams.isNotEmpty) {
          expect(col['half'], equals('1.0'));
        }
      }, max: 2));

      repo.recordAnalyticsEvent(
          AnalyticsFeaturesCollection(additionalParams: {'half': '1.0'}));
    });

    test(
        'single useFeature boolean with analytics evaluation sends value plus attributes',
        () {
      repo.analyticsStream.listen(expectAsync1((e) {
        expect(e, isA<AnalyticsFeature>());
        final col = e.toMap();
        expect(col['feature'], equals('F_KEY'));
        expect(col['id'], equals('1234'));
        expect(col['value'], equals('off'));
        expect(col.length, equals(3));
        expect(e.userKey, equals('freddy'));
      }));
      repo.used('F_KEY', '1234', false, FeatureValueType.BOOLEAN, {}, 'freddy');
    });

    group("context-tests", () {
      late MockEdgeService edge;
      late ServerEvalClientContext serverContext;

      setUp(() {
        // given: we fill the repo
        repo.updateFeatures(_initialFeatures());

        // and: we create a server eval context
        edge = MockEdgeService();
        when(() => edge.poll()).thenAnswer((_) async => true);
        serverContext = new ServerEvalClientContext(repo, edge);

        // and: we set the attributes including "analytics user key"
        serverContext
            .sessionKey('sessionKey')
            .attr('warehouseId', '134AB')
            .attrs('countries', ['nz', 'au']);
      });

      test(
          'I can deliberately record a new analytics event via the client context',
          () async {
        final afc = AnalyticsFeaturesCollectionContext(
            additionalParams: {'host': 'mine'}, userKey: 'no-key');

        var counter = 0;
        // then: the analytics stream should only contain a collection event. This would normally
        // trigger individual evals for each feature but we have to stomp on those
        repo.analyticsStream.listen(expectAsync1((e) {
          if (counter++ == 0) {
            expect(e, isA<AnalyticsFeaturesCollection>());
          } else {
            expect(e, isA<AnalyticsFeaturesCollectionContext>());
            final rec = e as AnalyticsFeaturesCollectionContext;
            expect(rec.featureValues.length, equals(1));
            expect(rec.featureValues[0].value, equals('off'));
            expect(rec.featureValues[0].id, equals('1'));
            expect(rec.additionalParams, equals({'host': 'mine'}));
            expect(rec.userKey, equals('sessionKey'));
            expect(
                rec.attributes,
                equals({
                  'session': ['sessionKey'],
                  'warehouseId': ['134AB'],
                  'countries': ['nz', 'au']
                }));
          }
        }, max:2));

        // when: we send the send the event off
        serverContext.recordAnalyticsEvent(afc);
      });

      test('If I evaluate a feature via the context it will get a use trigger',
          () async {
        var counter = 0;
        repo.analyticsStream.listen(expectAsync1((e) {
          if (counter++ == 0) {
            expect(e, isA<AnalyticsFeaturesCollection>());
          } else {
            expect(e, isA<AnalyticsFeature>());
            final rec = e as AnalyticsFeature;
            expect(
                rec.attributes,
                equals({
                  'session': ['sessionKey'],
                  'warehouseId': ['134AB'],
                  'countries': ['nz', 'au']
                }));
            expect(rec.feature.value, equals('off'));
            expect(rec.feature.key, equals('feature_x'));
          }
        }, max:2));

        expect(serverContext.feature('feature_x').flag, isFalse);
      });
    });
  });
}
