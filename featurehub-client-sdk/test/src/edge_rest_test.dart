

import 'dart:convert';

import 'package:featurehub_client_sdk/featurehub.dart';
import 'package:featurehub_client_sdk/src/rest_client.dart';
import 'package:mocktail/mocktail.dart';
import 'package:openapi_dart_common/openapi.dart';
import 'package:test/test.dart';

import 'mocks.dart';

void main() {
  late FeatureHubConfig config;
  late MockInternalFeatureRepository repo;
  late EdgeRest rest;

  setUp(() {
    repo = MockInternalFeatureRepository();
    config = MockFeatureHubConfig();
    when(() => config.baseUrl).thenReturn("http://localhost");
    rest = new EdgeRest(config, repo, timeout: 360);
  });

  test('We correctly decode cache-control headers', () {
    final response = new ApiResponse(236, {'cache-control': ['blah, max-age=20, blah', 'blah']}, null);

    rest.checkForCacheControl(response);
    expect(rest.timeoutInSeconds, 20);
  });

  test('A 236 will stop updating', () async {
    final data = Stream.value(utf8.encode('[{"id": "1"}]'));
    final response = new ApiResponse(236, {'cache-control': ['blah, max-age=20, blah', 'blah']}, data);
    final expireTime = rest.whenNextPollAllowed;

    expect(expireTime.isBefore(DateTime.now()), true);

    await rest.decodeResponse(response);

    // the new whenNextPollAllowed should be 20 seconds after the last time we set it
    expect(rest.whenNextPollAllowed.isBefore(expireTime.add(Duration(seconds: 22))), true);
    expect(rest.stopped, true);
  });

  test('A 200 wont stop updating', () async {
    final data = Stream.value(utf8.encode('[{"id": "1"}]'));
    final response = new ApiResponse(200, {'cache-control': ['blah, max-age=20, blah', 'blah']}, data);
    await rest.decodeResponse(response);
    expect(rest.stopped, false);
  });
}