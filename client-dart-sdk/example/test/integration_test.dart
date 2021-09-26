import 'package:featurehub_client_sdk/featurehub.dart';
import 'package:openapi_dart_common/openapi.dart';
import 'package:featurehub_client_api/api.dart';

import "package:test/test.dart";

void main() {
  test('Set feature value and get it back', () async {
    var path = 'https://zjbisc.demo.featurehub.io';
    var apiKey =
        'default/806d0fe8-2842-4d17-9e1f-1c33eedc5f31/tnZHPUIKV9GPM4u0koKPk1yZ3aqZgKNI7b6CT76q';
    final _api = FeatureServiceApi(ApiClient(basePath: path));

    // set feature state
    await _api.setFeatureState(
        apiKey,
        'FEATURE_TITLE_TO_UPPERCASE',
        FeatureStateUpdate()
          ..lock = false
          ..value = true);

    var repository = ClientFeatureRepository();

    // Provide host url (Edge FeatureHub server) and server eval api key for an application environment
    var featurehubApi = FeatureHubSimpleApi(path, [apiKey], repository);

    // Request feature updates via Get request
    await featurehubApi.request();

    expect(repository.getString('CONTAINER_COLOUR'), equals('green'));
  });
}
