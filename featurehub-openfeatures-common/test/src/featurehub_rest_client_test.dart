import 'dart:convert';

import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_openfeatures_common/featurehub.dart';
import 'package:mocktail/mocktail.dart';
import 'package:openapi_dart_common/openapi.dart';
import 'package:test/test.dart';

class _MockFeatureRepository extends Mock implements ClientFeatureRepository {
  @override
  final ClientContext clientContext = ClientContext();
}

void main() {
  late FeatureHubRestClient config;
  late _MockFeatureRepository repository;

  setUp(() {
    repository = _MockFeatureRepository();
    config = FeatureHubRestClient(
      'http://localhost',
      ['123'],
      repository,
      timeout: 360,
    );
  });

  test("an environment's pollInterval replaces the timeout", () async {
    final data = Stream.value(
      utf8.encode('[{"id": "1", "features": [], "pollInterval": 20}]'),
    );
    await config.decodeResponse(ApiResponse(200, {}, data));
    expect(config.timeoutInSeconds, 20);
  });

  test('A 236 will stop updating', () async {
    final data = Stream.value(
      utf8.encode('[{"id": "1", "features": [], "pollInterval": 20}]'),
    );
    final response = ApiResponse(236, {}, data);
    final expireTime = config.whenNextPollAllowed;

    expect(expireTime.isBefore(DateTime.now()), true);

    await config.decodeResponse(response);

    // the new whenNextPollAllowed should be 20 seconds after the last time we set it
    expect(
      config.whenNextPollAllowed.isBefore(
        expireTime.add(Duration(seconds: 22)),
      ),
      true,
    );
    expect(config.isConnectionDead, true);
    // the features are loaded, then the environment reported stale
    verifyInOrder([
      () => repository.notify(SSEResultState.features, any()),
      () => repository.markEnvironmentStale(),
    ]);
  });

  test('A 200 wont stop updating', () async {
    final data = Stream.value(utf8.encode('[{"id": "1", "features": []}]'));
    final response = ApiResponse(200, {
      'cache-control': ['blah, max-age=20, blah', 'blah'],
    }, data);
    await config.decodeResponse(response);
    expect(config.isConnectionDead, false);
    verifyNever(() => repository.markEnvironmentStale());
  });
}
